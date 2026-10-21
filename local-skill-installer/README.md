# local-skill-installer

A Windows PowerShell skill for installing downloaded Agent Skills once into a shared library and linking them to compatible agents.

## Features

- Installs skill folders, `.zip`, and `.skill` archives.
- Validates `SKILL.md` frontmatter.
- Supports multiline YAML descriptions.
- Stores the canonical copy under `%USERPROFILE%\.agents\skills`.
- Creates links for Codex, Claude Code, and optionally WorkBuddy.
- Uses Hermes `skills.external_dirs` without copying.
- Detects conflicts and backs up replaced versions.
- Supports dry-run mode.

## Requirements

- Windows
- PowerShell 7+
- Codex and/or Claude Code for automatic links
- WorkBuddy only when explicitly requested
- Hermes must include `%USERPROFILE%\.agents\skills` in `skills.external_dirs`

## Usage

```powershell
pwsh -NoProfile -File .\scripts\install-skill.ps1 `
  -Source "$env:USERPROFILE\Downloads\example-skill.zip" `
  -Agents codex,claude `
  -DryRun
```

Remove `-DryRun` to install.

## Agent Values

```text
codex
claude
hermes
workbuddy
none
```

## Backups

```text
%USERPROFILE%\.agent-backups\skill-installer\<timestamp>
```
