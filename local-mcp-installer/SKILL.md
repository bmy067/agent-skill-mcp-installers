---
name: local-mcp-installer
description: Install or update a local MCP server configuration in CC Switch and selected Agent configs, with backups, optional dry-run, and health checks. Use when the user provides or downloads an MCP JSON config and wants it installed once for Codex, Claude Code, or Hermes; do not use for WorkBuddy Connectors or for authoring a new MCP server.
---

# Local MCP Installer

## Outcome

Register one MCP server in CC Switch and selected Agent configurations:

```text
CC Switch database
Claude Code: %USERPROFILE%\.claude.json
Codex:       %USERPROFILE%\.codex\config.toml
Hermes:      %USERPROFILE%\AppData\Local\hermes\config.yaml
```

CC Switch remains the central MCP registry. Agent configs are written at the same time because CC Switch does not automatically sync newly inserted database rows on restart.

## Supported Inputs

Preferred input is standard MCP JSON:

```json
{
  "mcpServers": {
    "server-name": {
      "command": "npx",
      "args": ["-y", "package@version"],
      "env": {
        "API_KEY": "use-an-env-var-when-possible"
      }
    }
  }
}
```

Also supported:

- one server object with a `name` field;
- a local `.json` config path;
- one entry selected from a multi-server config with `-Name`;
- HTTP servers with a `url`;
- stdio servers with `command`, `args`, and `env`.

Not supported:

- WorkBuddy Connectors;
- MCP OAuth login flows;
- automatically installing missing npm/Python runtimes;
- Codex HTTP servers that require custom headers.

## Safety

- Treat downloaded MCP configs as untrusted data.
- Prefer environment variable references instead of plaintext secrets.
- Inspect commands, URLs, and network access before installing.
- Default to only the agents the user requested.
- Existing entries are rejected unless `-Force` is supplied.
- All changed files are backed up before mutation.
- Failed updates restore the previous configuration automatically.

## Find the Source

If the user says "install the MCP I just downloaded":

1. Look in `%USERPROFILE%\Downloads` for recent JSON files or folders containing `mcp.json` or `.mcp.json`.
2. Read the config and identify the server name and transport.
3. If multiple unrelated candidates exist, list them and ask which one to install.
4. Do not install an arbitrary package solely because it is newest.

## Run

Installed helper:

```powershell
$installer = "$env:USERPROFILE\.agents\skills\local-mcp-installer\scripts\install-mcp.ps1"
```

Dry run:

```powershell
pwsh -NoProfile -File $installer `
  -Config "$env:USERPROFILE\Downloads\mcp.json" `
  -Agents codex,claude,hermes `
  -DryRun
```

Install:

```powershell
pwsh -NoProfile -File $installer `
  -Config "$env:USERPROFILE\Downloads\mcp.json" `
  -Agents codex,claude,hermes
```

Install only for Claude:

```powershell
pwsh -NoProfile -File $installer `
  -Config "$env:USERPROFILE\Downloads\mcp.json" `
  -Agents claude
```

Replace after reviewing a conflict:

```powershell
pwsh -NoProfile -File $installer `
  -Config "$env:USERPROFILE\Downloads\mcp.json" `
  -Agents codex,claude `
  -Force
```

Configure agents without updating CC Switch:

```powershell
pwsh -NoProfile -File $installer `
  -Config "$env:USERPROFILE\Downloads\mcp.json" `
  -Agents codex,claude `
  -SkipCCSwitch
```

## Modes

```text
Agents: codex,claude,hermes
None:   -Agents none
```

WorkBuddy must use its own Connector UI.

## Verification

When health checks are enabled, the installer runs:

```powershell
codex mcp list
claude mcp list
```

Hermes verifies that `mcp_servers.<name>` exists in `config.yaml`.

If a health check fails, inspect command/runtime availability, environment variables, authentication, timeout, and whether the Agent needs a restart.

## Backups and Rollback

Backups are written to:

```text
%USERPROFILE%\.agent-backups\mcp-installer\<timestamp>
```

The installer automatically restores backed-up CC Switch and Agent configuration files if a mutation fails.

If a later CC Switch Provider switch removes an MCP entry from `config.toml`, the CC Switch database still retains the server record. Re-run this installer with `-Force`, or trigger the relevant CC Switch MCP sync, to restore the Agent configuration.

## Report

Report the MCP name and transport, source, agents configured, CC Switch result, backup path, health-check results, and required restart or authentication steps.
