# local-mcp-installer

A Windows PowerShell skill for registering MCP server configurations in CC Switch and selected Agent configs.

## Features

- Accepts standard MCP JSON.
- Supports stdio and HTTP MCP servers.
- Updates the CC Switch SQLite registry.
- Writes Codex TOML, Claude JSON, and Hermes YAML configurations.
- Backs up and restores configuration on failure.
- Runs optional health checks.
- Supports dry-run and conflict protection.

## Requirements

- Windows
- PowerShell 7+
- Node.js 22+ (`node:sqlite`)
- CC Switch 4.x for central registration
- Codex CLI for Codex targets
- Claude Code for Claude targets
- Hermes with `ruamel.yaml` for Hermes targets

## Usage

```powershell
pwsh -NoProfile -File .\scripts\install-mcp.ps1 `
  -Config "$env:USERPROFILE\Downloads\mcp.json" `
  -Agents codex,claude,hermes `
  -DryRun
```

Remove `-DryRun` to install.

## Agent Values

```text
codex
claude
hermes
none
```

WorkBuddy Connectors are not supported by this installer.

## Backups

```text
%USERPROFILE%\.agent-backups\mcp-installer\<timestamp>
```
