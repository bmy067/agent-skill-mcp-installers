# Agent Skill 与 MCP 安装器

这是一组面向 Windows 的 PowerShell Skill，用于把下载的 Agent Skill 和 MCP 配置安装到统一目录，并按需同步给 Codex、Claude Code、Hermes 和 WorkBuddy。

[English README](README.md)

## 包含内容

```text
local-skill-installer
local-mcp-installer
```

### local-skill-installer

用于安装下载的 Skill 文件夹、`.zip` 或 `.skill` 包。

主要功能：

- 校验 `SKILL.md`；
- 安装到统一主目录 `%USERPROFILE%\.agents\skills`；
- 为 Codex、Claude Code、WorkBuddy 创建目录链接；
- 同名内容默认跳过；
- 同名不同内容默认拒绝覆盖；
- 使用 `-Force` 时先备份再替换；
- 支持 dry-run。

### local-mcp-installer

用于安装或更新 MCP Server 配置。

主要功能：

- 支持标准 MCP JSON；
- 支持 stdio 和 HTTP MCP；
- 更新 CC Switch 数据库；
- 写入 Codex `config.toml`；
- 写入 Claude `.claude.json`；
- 写入 Hermes `config.yaml`；
- 自动备份并在失败时恢复；
- 支持 dry-run、冲突保护和健康检查。

## 环境要求

- Windows
- PowerShell 7+
- Node.js 22+，用于 MCP 安装器的 SQLite 操作
- CC Switch 4.x，用于统一 MCP 注册
- Codex CLI
- Claude Code
- Hermes 需要 `ruamel.yaml`

## 安装 Skill

把两个目录复制到共享 Skill 目录：

```text
%USERPROFILE%\.agents\skills
```

然后按需链接到各 Agent 的 Skill 目录，或使用 `local-skill-installer` 管理链接。

## 使用 local-skill-installer

先执行 dry-run：

```powershell
pwsh -NoProfile -File .\local-skill-installer\scripts\install-skill.ps1 `
  -Source "$env:USERPROFILE\Downloads\example-skill.zip" `
  -Agents codex,claude `
  -DryRun
```

确认后去掉 `-DryRun` 执行安装。

支持的 Agent 参数：

```text
codex
claude
hermes
workbuddy
none
```

## 使用 local-mcp-installer

MCP 配置示例：

```json
{
  "mcpServers": {
    "server-name": {
      "command": "npx",
      "args": ["-y", "package@version"],
      "env": {
        "API_KEY": "value"
      }
    }
  }
}
```

先执行 dry-run：

```powershell
pwsh -NoProfile -File .\local-mcp-installer\scripts\install-mcp.ps1 `
  -Config "$env:USERPROFILE\Downloads\mcp.json" `
  -Agents codex,claude,hermes `
  -DryRun
```

确认后去掉 `-DryRun` 执行安装。

## 默认目标

`local-skill-installer`：

```text
Codex       默认创建链接
Claude Code 默认创建链接
Hermes      通过 external_dirs 读取
WorkBuddy   需要显式指定
```

`local-mcp-installer`：

```text
Codex       默认写入
Claude Code 默认写入
Hermes      需要显式指定
WorkBuddy   不支持，使用独立 Connector
```

## 备份位置

Skill：

```text
%USERPROFILE%\.agent-backups\skill-installer\<timestamp>
```

MCP：

```text
%USERPROFILE%\.agent-backups\mcp-installer\<timestamp>
```

## 注意事项

- 下载内容在安装前应视为不可信数据。
- 安装器不会执行下载 Skill 中的脚本。
- MCP 安装器不会自动安装 npm、Python 或 uv 运行时。
- MCP OAuth 登录需要手动完成。
- 不建议把 API Key 明文写入多份配置。
- WorkBuddy Connector 由 WorkBuddy 自己管理。
- Codex 暂不支持自动配置带自定义 Headers 的 HTTP MCP。


