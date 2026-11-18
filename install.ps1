# Install the auto-context plugin and manage its server list — no config
# files to edit by hand. Windows counterpart of install.sh; the plugin file
# itself is identical on every platform.
#
#   .\install.ps1 add <endpoint> [providerID]   register a server (installs plugin too)
#   .\install.ps1 remove <endpoint>             forget a server
#   .\install.ps1 list                          show registered servers
#   .\install.ps1 install                       install/update the plugin file only
#
# One-liner from the README (positional args work with powershell.exe and pwsh):
#
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/cjdell/opencode-model-autodetect/main/install.ps1))) add http://box.local:8080/v1
#
# Or via irm | iex with no arguments, driven by environment variables:
#
#   $env:AUTO_CONTEXT_ENDPOINT = "http://box.local:8080/v1"
#   irm https://raw.githubusercontent.com/cjdell/opencode-model-autodetect/main/install.ps1 | iex
#
# Respects OPENCODE_CONFIG_DIR (default $HOME\.config\opencode). Set
# AUTO_CONTEXT_SRC to a local path or URL to install from somewhere other
# than the main branch. Needs PowerShell 5.1 or newer.

param(
  [Parameter(Position = 0)][string]$Command,
  [Parameter(Position = 1)][string]$Endpoint,
  [Parameter(Position = 2)][string]$ProviderID
)

# irm | iex style invocation leaves the param block unbound unless args are
# passed, so fall back to the environment variables, then to "install".
if (-not $Command) {
  if ($env:AUTO_CONTEXT_ENDPOINT) {
    $Command = "add"
    $Endpoint = $env:AUTO_CONTEXT_ENDPOINT
    if (-not $ProviderID -and $env:AUTO_CONTEXT_PROVIDER_ID) { $ProviderID = $env:AUTO_CONTEXT_PROVIDER_ID }
  }
  else { $Command = "install" }
}

$Repo = "cjdell/opencode-model-autodetect"
if ($env:AUTO_CONTEXT_SRC) { $Src = $env:AUTO_CONTEXT_SRC } else { $Src = "https://raw.githubusercontent.com/$Repo/main/index.ts" }
if ($env:OPENCODE_CONFIG_DIR) { $ConfigDir = $env:OPENCODE_CONFIG_DIR } else { $ConfigDir = Join-Path $HOME ".config\opencode" }
$PluginsDir = Join-Path $ConfigDir "plugins"
$PluginFile = Join-Path $PluginsDir "auto-context.ts"
$ServersFile = Join-Path $PluginsDir "auto-context.servers.json"

# PS 5.1's Set-Content -Encoding UTF8 writes a BOM, which JSON.parse chokes
# on; the plugin reads this file, so always write BOM-less UTF-8.
function Save-Utf8NoBom([string]$Path, [string]$Text) {
  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Servers {
  if (-not (Test-Path $ServersFile)) { return @() }
  $raw = Get-Content -Raw -Path $ServersFile
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
  try { $parsed = ConvertFrom-Json $raw }
  catch { throw "refusing to touch unparseable JSON: $ServersFile" }
  if ($null -eq $parsed) { return @() }
  if ($parsed -is [System.Array]) { return @($parsed) }
  return @($parsed)
}

function Save-Servers($Servers) {
  New-Item -ItemType Directory -Force -Path $PluginsDir | Out-Null
  $Servers = @($Servers)
  if ($Servers.Count -eq 0) { $json = "[]" }
  else { $json = ConvertTo-Json -InputObject $Servers -Depth 5 }
  Save-Utf8NoBom $ServersFile ($json + "`n")
}

# Derive a provider ID from the hostname: first label of a real hostname,
# "local" for bare IPs, sanitized host for api-style hosts (mirrors install.sh).
function Get-ProviderId([string]$Url) {
  try { $uri = New-Object System.Uri($Url) } catch { return "server" }
  $h = $uri.Host
  if (-not $h) { return "server" }
  if ($h -match '^\[?.*[0-9.]+$' -and $h -notmatch '[a-z]') { return "local" }
  if ($h -match ':') { return "local" }
  $labels = $h -split '\.'
  $generic = @("api", "www", "app", "server", "proxy", "gateway", "v1")
  if ($labels.Length -gt 1 -and $labels[0].Length -gt 1 -and $generic -notcontains $labels[0].ToLower()) {
    return (($labels[0] -replace '[^a-zA-Z0-9-]', '-') -replace '\s', '').ToLower()
  }
  return ($h -replace '[^a-zA-Z0-9-]', '-').ToLower()
}

function Install-Plugin {
  New-Item -ItemType Directory -Force -Path $PluginsDir | Out-Null
  if (Test-Path -LiteralPath $Src) { Copy-Item -LiteralPath $Src -Destination $PluginFile }
  else { Invoke-WebRequest -UseBasicParsing -Uri $Src -OutFile $PluginFile }
  Write-Host "plugin installed: $PluginFile"
}

function Invoke-Add {
  $Endpoint = ([string]$Endpoint).Trim()
  if ($Endpoint -notmatch '^https?://') { throw "endpoint must start with http:// or https://" }
  $Endpoint = $Endpoint -replace '/+$', ''
  $Id = $ProviderID
  if (-not $Id) { $Id = Get-ProviderId $Endpoint }
  # @() around the call: PowerShell flattens a single-element array returned
  # from a function into a scalar, which then breaks array operations below.
  $servers = @(Get-Servers)
  $existing = $servers | Where-Object { ([string]$_.endpoint) -replace '/+$', '' -eq $Endpoint } | Select-Object -First 1
  if ($existing) {
    if ($ProviderID -and $existing.providerID -ne $Id) {
      $existing.providerID = $Id
      Save-Servers $servers
    }
    Write-Host "already registered as `"$($existing.providerID)`" ($Endpoint)"
    return
  }
  $entry = [ordered]@{ endpoint = $Endpoint; providerID = $Id }
  if ($servers.Count -eq 0) { $entry.setDefault = $true }
  Save-Servers (@($servers + $entry))
  $note = "added `"$Id`" (alias $Id/current"
  if ($entry.Contains("setDefault")) { $note += ", catalog default" }
  Write-Host "$note)"
}

function Invoke-Remove {
  $Endpoint = ([string]$Endpoint).Trim() -replace '/+$', ''
  if (-not $Endpoint) { throw "usage: install.ps1 remove <endpoint>" }
  $servers = @(Get-Servers)
  $kept = @($servers | Where-Object { ([string]$_.endpoint) -replace '/+$', '' -ne $Endpoint })
  Save-Servers $kept
  $removed = $servers.Count - $kept.Count
  if ($removed -eq 0) { Write-Host "no server with endpoint $Endpoint" }
  else { Write-Host "removed $removed server(s)" }
}

function Invoke-List {
  $servers = @(Get-Servers)
  if ($servers.Count -eq 0) { Write-Host "(no servers in $ServersFile)"; return }
  $index = 0
  foreach ($server in $servers) {
    $hasDefault = $server.PSObject.Properties.Name -contains "setDefault"
    $isDefault = $server.setDefault -eq $true -or ((-not $hasDefault) -and $index -eq 0)
    $suffix = ""
    if ($isDefault) { $suffix = "`t(default)" }
    Write-Host "$($server.providerID)`t$($server.endpoint)$suffix"
    $index++
  }
}

switch ($Command.ToLower()) {
  "install" { Install-Plugin }
  "add" {
    if (-not $Endpoint) { throw "usage: install.ps1 add <endpoint> [providerID]" }
    Install-Plugin
    Invoke-Add
    Write-Host "restart OpenCode (or wait for the next poll) to pick it up"
  }
  "remove" { Invoke-Remove }
  "list" { Invoke-List }
  default { throw "usage: install.ps1 [add <endpoint> [providerID] | remove <endpoint> | list | install]" }
}
