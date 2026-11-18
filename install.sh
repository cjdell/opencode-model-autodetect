#!/usr/bin/env bash
# Install the auto-context plugin and manage its server list — no config
# files to edit by hand.
#
#   install.sh add <endpoint> [providerID]   register a server (installs plugin too)
#   install.sh remove <endpoint>             forget a server
#   install.sh list                          show registered servers
#   install.sh install                       install/update the plugin file only
#
# Respects OPENCODE_CONFIG_DIR (default ~/.config/opencode). Set
# AUTO_CONTEXT_SRC to a local path or URL to install from somewhere other
# than the main branch.
set -euo pipefail

REPO="cjdell/opencode-model-autodetect"
SRC="${AUTO_CONTEXT_SRC:-https://raw.githubusercontent.com/$REPO/main/index.ts}"
CONFIG_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"
PLUGINS_DIR="$CONFIG_DIR/plugins"
PLUGIN_FILE="$PLUGINS_DIR/auto-context.ts"
SERVERS_FILE="$PLUGINS_DIR/auto-context.servers.json"

TMPJS="$(mktemp)"
trap 'rm -f "$TMPJS"' EXIT

cat >"$TMPJS" <<'JS'
const fs = require("fs");
const file = process.env.SERVERS_FILE;
const mode = process.env.MODE;
const endpoint = (process.env.ENDPOINT || "").replace(/\/+$/, "");
const provider = process.env.PROVIDER || "";

let servers = [];
if (fs.existsSync(file)) {
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    console.error(`refusing to touch unparseable JSON: ${file}`);
    process.exit(1);
  }
  if (Array.isArray(parsed)) servers = parsed;
}

// Derive a provider ID from the hostname: first label of a real hostname,
// "local" for bare IPs, sanitized host for api-style hosts.
const hostProvider = (url) => {
  let host;
  try {
    host = new URL(url).hostname;
  } catch {
    return "server";
  }
  if (/^[0-9.]+$/.test(host) || host.includes(":")) return "local";
  const clean = (value) => value.replace(/[^a-z0-9-]/g, "-").toLowerCase();
  const labels = host.split(".");
  const first = labels[0];
  const generic = ["api", "www", "app", "server", "proxy", "gateway", "v1"];
  if (labels.length > 1 && first.length > 1 && !generic.includes(first)) return clean(first);
  return clean(host);
};

const strip = (server) => String(server.endpoint || "").replace(/\/+$/, "");

if (mode === "add") {
  if (!/^https?:\/\//.test(endpoint)) {
    console.error("endpoint must start with http:// or https://");
    process.exit(1);
  }
  const providerID = provider || hostProvider(endpoint);
  const existing = servers.find((server) => strip(server) === endpoint);
  if (existing) {
    if (provider && existing.providerID !== providerID) existing.providerID = providerID;
    console.log(`already registered as "${existing.providerID}" (${endpoint})`);
  } else {
    const entry = { endpoint, providerID };
    if (servers.length === 0) entry.setDefault = true;
    servers.push(entry);
    fs.mkdirSync(file.slice(0, file.lastIndexOf("/")), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(servers, null, 2) + "\n");
    console.log(
      `added "${providerID}" (alias ${providerID}/current${entry.setDefault ? ", catalog default" : ""})`,
    );
  }
} else if (mode === "remove") {
  const before = servers.length;
  servers = servers.filter((server) => strip(server) !== endpoint);
  fs.writeFileSync(file, JSON.stringify(servers, null, 2) + "\n");
  console.log(before === servers.length ? `no server with endpoint ${endpoint}` : `removed ${before - servers.length} server(s)`);
} else if (mode === "list") {
  if (servers.length === 0) {
    console.log(`(no servers in ${file})`);
  } else {
    servers.forEach((server, index) => {
      const isDefault = server.setDefault === true || (server.setDefault === undefined && index === 0);
      console.log(`${server.providerID || "?"}\t${server.endpoint}${isDefault ? "\t(default)" : ""}`);
    });
  }
}
JS

run_js() {
  if command -v bun >/dev/null 2>&1; then bun "$TMPJS"
  elif command -v node >/dev/null 2>&1; then node "$TMPJS"
  else echo "need bun or node to update $SERVERS_FILE" >&2; exit 1
  fi
}

install_plugin() {
  mkdir -p "$PLUGINS_DIR"
  if [ -e "$SRC" ]; then cp "$SRC" "$PLUGIN_FILE"
  else curl -fsSL "$SRC" -o "$PLUGIN_FILE"
  fi
  echo "plugin installed: $PLUGIN_FILE"
}

MODE="${1:-install}"
case "$MODE" in
  install)
    install_plugin
    ;;
  add)
    ENDPOINT="${2:?usage: install.sh add <endpoint> [providerID]}"
    install_plugin
    MODE=add ENDPOINT="$ENDPOINT" PROVIDER="${3:-}" SERVERS_FILE="$SERVERS_FILE" run_js
    echo "restart OpenCode (or wait for the next poll) to pick it up"
    ;;
  remove)
    ENDPOINT="${2:?usage: install.sh remove <endpoint>}"
    MODE=remove ENDPOINT="$ENDPOINT" SERVERS_FILE="$SERVERS_FILE" run_js
    ;;
  list)
    MODE=list SERVERS_FILE="$SERVERS_FILE" run_js
    ;;
  *)
    echo "usage: install.sh [add <endpoint> [providerID] | remove <endpoint> | list | install]" >&2
    exit 2
    ;;
esac
