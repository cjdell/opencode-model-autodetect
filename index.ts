import { Model, Plugin, Provider } from "@opencode/plugin"
import { readFileSync } from "node:fs"

// Auto-detect models and context windows for self-hosted OpenAI-compatible servers.
//
// Adds one provider per configured server plus one OpenCode model per entry that
// server's `/models` endpoint reports, using the server-advertised ID,
// `meta.n_ctx` as the context limit, and `architecture.{input,output}_modalities`
// as capabilities. Adding or removing models on a server, or changing n_ctx, is
// picked up on the next poll with no opencode.json edits — no model or provider
// entry is needed in the config at all.
//
// Each server can also maintain one stable alias ID that always points at its
// currently-loaded model, so sessions and references keep working when the
// llama.cpp alias changes. Only one server may claim the catalog default.
//
// The output limit is clamped to a quarter of the detected context so a small
// self-hosted context window still leaves room for the prompt.
//
// Servers are read from the first source that provides them:
//
//   1. A `servers` array in the plugin options, when loaded through a `plugins`
//      entry in opencode.json (see README).
//   2. `AUTO_CONTEXT_SERVERS`: a JSON array with the same shape as below.
//   3. `AUTO_CONTEXT_ENDPOINT`: a single endpoint URL; the provider ID is
//      derived from the hostname (override with `AUTO_CONTEXT_PROVIDER_ID`).
//   4. An `auto-context.servers.json` file next to this plugin file, so a
//      drop-in install in ~/.config/opencode/plugins/ needs no opencode.json
//      entry and keeps personal endpoints out of the plugin code. `install.sh`
//      in this repo maintains that file for you.
//   5. Otherwise the plugin idles and retries the environment/file sources on
//      every poll.
//
// Per-server fields (all optional unless noted):
//   endpoint:    server root, including /v1 (required)
//   providerID:  catalog provider ID, the model reference prefix (required)
//   name:        display name, default providerID
//   stableID:    alias ID kept pointing at the loaded model, default "current";
//                set "" to disable
//   setDefault:  make this server's alias the catalog default (default: first
//                server only)
//
// `pollSeconds` sets the re-probe interval for every server (default 60).

type ServerConfig = {
  endpoint: string
  providerID: string
  name: string
  stableID: string
  setDefault: boolean
}

type ServerEntry = {
  id: string
  nCtx?: number
  input?: string[]
  output?: string[]
  loaded: boolean
}

type ModelsResponse = {
  data?: Array<{
    id?: string
    meta?: { n_ctx?: number }
    architecture?: { input_modalities?: string[]; output_modalities?: string[] }
    status?: { value?: string }
  }>
}

const normalize = (server: any, index: number): ServerConfig => ({
  endpoint: String(server?.endpoint ?? "").replace(/\/+$/, ""),
  providerID: String(server?.providerID ?? ""),
  name: typeof server?.name === "string" ? server.name : String(server?.providerID ?? ""),
  stableID: typeof server?.stableID === "string" ? server.stableID : "current",
  setDefault: server?.setDefault === undefined ? index === 0 : server.setDefault === true,
})

const parseServers = (text: string): any[] | undefined => {
  try {
    const parsed = JSON.parse(text)
    return Array.isArray(parsed) ? parsed : undefined
  } catch {
    return undefined
  }
}

// Provider ID from the hostname: first label of a real hostname, "local" for
// bare IPs, sanitized host for api-style hosts (mirrors install.sh).
const hostProvider = (endpoint: string) => {
  let host: string
  try {
    host = new URL(endpoint).hostname
  } catch {
    return "server"
  }
  if (/^[0-9.]+$/.test(host) || host.includes(":")) return "local"
  const clean = (value: string) => value.replace(/[^a-z0-9-]/g, "-").toLowerCase()
  const labels = host.split(".")
  const generic = ["api", "www", "app", "server", "proxy", "gateway", "v1"]
  if (labels.length > 1 && labels[0].length > 1 && !generic.includes(labels[0])) return clean(labels[0])
  return clean(host)
}

const envEndpointServers = (): any[] | undefined => {
  const endpoint = (process.env.AUTO_CONTEXT_ENDPOINT ?? "").trim()
  if (endpoint.length === 0) return undefined
  return [
    {
      endpoint,
      providerID: process.env.AUTO_CONTEXT_PROVIDER_ID ?? hostProvider(endpoint),
      setDefault: true,
    },
  ]
}

const fileServers = (): any[] | undefined => {
  try {
    return parseServers(readFileSync(new URL("auto-context.servers.json", import.meta.url), "utf8"))
  } catch {
    return undefined
  }
}

export default Plugin.define({
  id: "auto-context",
  async setup(ctx) {
    const optionsServers = Array.isArray(ctx.options.servers)
      ? ctx.options.servers.map(normalize)
      : undefined

    const readServers = (): ServerConfig[] => {
      const configured =
        optionsServers ??
        (parseServers(process.env.AUTO_CONTEXT_SERVERS ?? "") ??
          envEndpointServers() ??
          fileServers() ??
          []).map(normalize)
      return configured.filter((server) => server.endpoint.length > 0 && server.providerID.length > 0)
    }

    let servers = readServers()
    const pollMs = Math.max(5, Number(ctx.options.pollSeconds ?? 60)) * 1000

    // providerID -> detected inventory. Mutated in place; read synchronously
    // by the transforms below.
    const detected = new Map<string, ServerEntry[]>()

    const toInfo = (server: ServerConfig, id: string, entry: ServerEntry) => {
      const info = Model.Info.default(
        Provider.ID.make(server.providerID),
        Model.ID.make(id),
      ) as any
      // The alias keeps its catalog ID but sends requests as the loaded model.
      info.modelID = entry.id
      if (id !== server.stableID) info.name = entry.id
      info.capabilities = {
        ...info.capabilities,
        tools: true,
        input: entry.input ?? ["text"],
        output: entry.output ?? ["text"],
      }
      if (entry.nCtx !== undefined) {
        info.limit.context = entry.nCtx
        info.limit.output = Math.max(1024, Math.min(info.limit.output ?? 0, Math.floor(entry.nCtx / 4)))
      }
      return info
    }

    const modelsFor = (server: ServerConfig, entries: readonly ServerEntry[]) => {
      const models: any[] = entries.map((entry) => toInfo(server, entry.id, entry))
      const primary = entries.find((entry) => entry.loaded) ?? entries[0]
      if (server.stableID && primary && !entries.some((entry) => entry.id === server.stableID)) {
        models.push(toInfo(server, server.stableID, primary))
      }
      return models
    }

    const probe = async (): Promise<boolean> => {
      let changed = false
      for (const server of servers) {
        try {
          const response = await fetch(`${server.endpoint}/models`, {
            signal: AbortSignal.timeout(5000),
          })
          if (!response.ok) continue
          const body = (await response.json()) as ModelsResponse
          const entries: ServerEntry[] = (body.data ?? [])
            .filter((entry) => typeof entry?.id === "string" && entry.id.length > 0)
            .map((entry) => ({
              id: entry.id as string,
              ...(typeof entry.meta?.n_ctx === "number" && entry.meta.n_ctx > 0
                ? { nCtx: Math.floor(entry.meta.n_ctx) }
                : {}),
              ...(Array.isArray(entry.architecture?.input_modalities)
                ? { input: entry.architecture?.input_modalities }
                : {}),
              ...(Array.isArray(entry.architecture?.output_modalities)
                ? { output: entry.architecture?.output_modalities }
                : {}),
              loaded: entry.status?.value === "loaded",
            }))
          if (entries.length === 0) continue
          const previous = detected.get(server.providerID)
          const same =
            previous !== undefined &&
            previous.length === entries.length &&
            previous.every(
              (old, i) =>
                old.id === entries[i].id &&
                old.nCtx === entries[i].nCtx &&
                old.loaded === entries[i].loaded,
            )
          if (!same) {
            detected.set(server.providerID, entries)
            changed = true
          }
        } catch {
          // Server unreachable right now; keep the last known inventory and retry next poll.
        }
      }
      return changed
    }

    await ctx.provider.transform((editor) => {
      for (const server of servers) {
        const entries = detected.get(server.providerID)
        if (!entries) continue
        editor.add({
          info: {
            ...Provider.Info.empty(Provider.ID.make(server.providerID)),
            name: server.name,
            activation: "enabled",
            package: "@opencode/ai/providers/openai-compatible",
            settings: { baseURL: server.endpoint, provider: server.providerID, apiKey: "" },
          } as any,
          models: modelsFor(server, entries) as any,
        })
      }
    })

    await ctx.model.transform((editor) => {
      const target = servers.find((server) => server.setDefault)
      if (!target) return
      const models = editor.list(target.providerID)
      if (models.length === 0) return
      const model = models.find((entry) => entry.id === target.stableID) ?? models[0]
      const current = editor.default.get()
      if (current?.providerID === target.providerID && current.modelID === model.id) return
      editor.default.set(target.providerID, model.id)
    })

    // Force one registry rebuild so the transforms run at least once (they
    // register the detected inventory and set the default).
    await ctx.model.list()

    const apply = async () => {
      if (servers.length === 0) servers = readServers()
      if (servers.length === 0) return false
      if (await probe()) {
        await ctx.provider.reload()
        await ctx.model.reload()
        return true
      }
      return false
    }

    // The first probe can fail while the plugin runtime is still activating,
    // so retry quickly (bounded) until a server reports models.
    let retries = 0
    let fast: ReturnType<typeof setInterval> | undefined
    const applyOrRetry = () => {
      void apply().finally(() => {
        if (detected.size < servers.length && ++retries < 10 && fast) return
        if (fast !== undefined) {
          clearInterval(fast)
          fast = undefined
        }
      })
    }
    fast = setInterval(applyOrRetry, 2000)
    applyOrRetry()

    const timer = setInterval(() => void apply(), pollMs)
    return () => {
      clearInterval(timer)
      if (fast !== undefined) clearInterval(fast)
    }
  },
})
