# opencode-model-autodetect

An [OpenCode](https://opencode.ai) plugin that auto-detects models, context
windows, and modality capabilities from self-hosted OpenAI-compatible servers
(llama.cpp, and anything else that advertises `meta.n_ctx` in `/models`).

Point it at your server and forget it. No more `opencode.json` model entries
every time you rotate a quant, resize the context, or hot-swap a model:

- **One OpenCode model per `/models` entry**, using the server-advertised ID.
- **Context limit from `meta.n_ctx`** — resize with `-c` on llama.cpp and it
  shows up in OpenCode on the next poll, no config edits.
- **Input/output modalities** from `architecture.input_modalities` /
  `output_modalities` (vision models light up as vision models).
- **A stable alias ID** per server that always points at the currently-loaded
  model, so a favourite/reference like `llama/current` survives model swaps.
- **One server can claim the catalog default**, so OpenCode starts up on your
  local model without a `model` setting.
- **Live updates**: servers are re-polled (default every 60 s); adds, removes,
  and `n_ctx` changes propagate with a provider/model registry reload.

## Requirements

- OpenCode >= 2.3 (tested against 2.3.2; the plugin uses the `@opencode/plugin`
  provider/model transform API).
- A server exposing the OpenAI-compatible `GET /v1/models`. The `n_ctx`,
  `architecture` and `status` fields are llama.cpp extensions; without them the
  plugin still registers the models, just with catalog default limits and no
  loaded-model alias tracking.

## Install

The plugin is a single TypeScript file and runs identically on macOS, Linux and
Windows. Only the installer differs by platform — both keep the same
`auto-context.servers.json`, so you can move between them freely.

### macOS / Linux

One command — installs the plugin **and** registers your endpoint. No config
files to touch:

```sh
curl -fsSL https://raw.githubusercontent.com/cjdell/opencode-model-autodetect/main/install.sh \
  | bash -s -- add http://box.local:8080/v1
```

Manage endpoints later the same way (save the script once, or re-run the curl):

```sh
install.sh add <endpoint> [providerID]   # register a server
install.sh remove <endpoint>             # forget one
install.sh list                          # show what's registered
install.sh install                       # install/update the plugin file only
```

### Windows

PowerShell 5.1+ (ships with Windows). One line — installs the plugin **and**
registers your endpoint:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cjdell/opencode-model-autodetect/main/install.ps1))) add http://box.local:8080/v1
```

The same subcommands are available (`save install.ps1` once, or re-run the
`irm` line):

```powershell
.\install.ps1 add <endpoint> [providerID]   # register a server
.\install.ps1 remove <endpoint>             # forget one
.\install.ps1 list                          # show what's registered
.\install.ps1 install                       # install/update the plugin file only
```

Both installers default to `~/.config/opencode/plugins/` (`$HOME\.config\opencode\plugins`
on Windows) and respect `OPENCODE_CONFIG_DIR`. `add` installs/updates
`auto-context.ts` there and keeps endpoints in `auto-context.servers.json`
next to it — the plugin watches that file, so new servers arrive on the next
poll without restarting OpenCode.

Restart OpenCode; the server's models show up in the picker. The provider ID
is derived from the hostname (`http://llama.int.example.org:8080/v1` →
`llama`); pass a second argument to override it.

### Manual install

Copy [`index.ts`](index.ts) into `~/.config/opencode/plugins/` (any name —
files there load automatically, no `opencode.json` entry needed) and
configure it with one of the sources below.

### As a `plugins` entry with options

```jsonc
// opencode.json
{
  "plugin": [
    ["/path/to/opencode-model-autodetect/index.ts", {
      "servers": [
        { "endpoint": "http://box.local:8080/v1", "providerID": "llama" }
      ],
      "pollSeconds": 30
    }]
  ]
}
```

## Configuration

Servers are read from the first source that provides them:

1. A `servers` array in the plugin options (`plugins` entry in opencode.json).
2. `AUTO_CONTEXT_SERVERS` — a JSON array in the shape below.
3. `AUTO_CONTEXT_ENDPOINT` — a single endpoint URL; the provider ID is derived
   from the hostname (override with `AUTO_CONTEXT_PROVIDER_ID`). Handy in
   containers: `-e AUTO_CONTEXT_ENDPOINT=http://host.docker.internal:8080/v1`.
4. An `auto-context.servers.json` file next to the plugin file (what
   `install.sh` / `install.ps1` maintain).
5. Otherwise the plugin idles and retries the environment/file sources on
   every poll.

`auto-context.servers.json` (see [`servers.example.json`](servers.example.json)):

```json
[
  {
    "endpoint": "http://box.local:8080/v1",
    "providerID": "llama",
    "name": "My box",
    "stableID": "current",
    "setDefault": true
  },
  { "endpoint": "http://other.local:8000/v1", "providerID": "vllm" }
]
```

Per-server fields (all optional unless noted):

| Field        | Meaning                                                                                                       | Default            |
| ------------ | ------------------------------------------------------------------------------------------------------------- | ------------------ |
| `endpoint`   | **Required.** Server root, including `/v1`.                                                                     | —                  |
| `providerID` | **Required.** Catalog provider ID — the prefix in model references (`llama/qwen3-32b`).                        | —                  |
| `name`       | Display name in pickers.                                                                                        | `providerID`       |
| `stableID`   | Alias ID kept pointing at the server's currently-loaded model; `""` disables the alias.                        | `"current"`        |
| `setDefault` | Make this server's alias the catalog default. Only the first server with this set wins.                        | first server only  |

Top-level options: `pollSeconds` — re-probe interval for every server
(minimum 5, default 60).

## How it works

- Polls `${endpoint}/models` per server. Each entry becomes an OpenCode model
  under a synthetic openai-compatible provider with `baseURL` set.
- `meta.n_ctx` becomes the model's context limit. The output limit is clamped
  to a quarter of the detected context (minimum 1024) so a small self-hosted
  window still leaves room for the prompt.
- Entries with `status.value === "loaded"` are the "loaded" model; the
  server's `stableID` alias is registered to point at it and sends requests as
  its ID. This keeps references like `llama/current` stable across llama.cpp
  alias changes (`--model` swaps, `-a` renames).
- The transforms only rebuild the registry when something actually changed, so
  an idle server costs one HTTP GET per poll.

## Troubleshooting

- **No models appear**: the endpoint must answer `GET ${endpoint}/models` with
  `{"data": [...]}`; check with `curl`. Unreachable servers are silently
  retried each poll — start llama.cpp first, models arrive on their own.
- **`@opencode/plugin` not found**: the import is provided by the OpenCode
  plugin runtime (>= 2.3). If you typecheck this file standalone, add
  `@opencode/plugin` as a devDependency.
- **Models show but requests fail**: llama.cpp must actually have the model
  loaded (`/status` or `/props`); detected-but-not-loaded models are listed
  with their advertised IDs and may 404 until loaded.

## License

MIT
