# Agent Skill & MCP Installers

[中文说明](README.zh-CN.md)

Windows PowerShell skills for installing downloaded Agent Skills and MCP server configurations into a shared, multi-agent setup.

## Included Skills

### local-skill-installer

Installs a downloaded skill folder or archive into:

```text
%USERPROFILE%\.agents\skills
```

It validates `SKILL.md`, handles conflicts with backups, and creates links for Codex, Claude Code, and optionally WorkBuddy. Hermes can consume the shared directory through `skills.external_dirs`.

### local-mcp-installer

Registers an MCP server configuration in:

- CC Switch
- Codex
- Claude Code
- Hermes

It supports standard MCP JSON, stdio and HTTP transports, dry-run, conflict protection, backups, and health checks.

## Requirements

- Windows
- PowerShell 7+
- Node.js 22+ for MCP installation
- CC Switch 4.x for centralized MCP registration
- Codex CLI and/or Claude Code for Agent targets
- Hermes with `ruamel.yaml` for Hermes targets

## Install

Copy either skill directory into your shared skill library:

```text
%USERPROFILE%\.agents\skills
```

Then link it into the agent directories you use, or let `local-skill-installer` manage those links.

## Usage

Skill:

```powershell
pwsh -NoProfile -File .\local-skill-installer\scripts\install-skill.ps1 `
  -Source "$env:USERPROFILE\Downloads\example-skill.zip" `
  -Agents codex,claude `
  -DryRun
```

MCP:

```powershell
pwsh -NoProfile -File .\local-mcp-installer\scripts\install-mcp.ps1 `
  -Config "$env:USERPROFILE\Downloads\mcp.json" `
  -Agents codex,claude,hermes `
  -DryRun
```

Remove `-DryRun` to apply changes.

## Notes

- WorkBuddy Connectors are managed separately.
- MCP OAuth login and runtime installation remain manual.
- Review downloaded scripts and configurations before installation.

