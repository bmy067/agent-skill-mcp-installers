[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Config,

    [string]$Name,

    [string[]]$Agents = @('codex', 'claude'),

    [switch]$Force,

    [switch]$DryRun,

    [switch]$SkipCCSwitch,

    [switch]$NoHealthCheck,

    [switch]$AllowMissingCommand,

    [string]$HomeDir,

    [string]$CCSwitchExe
)

$ErrorActionPreference = 'Stop'
if (-not $HomeDir) {
    if ($PSScriptRoot -match '^(.*?)[\\/]\.agents[\\/]skills[\\/]') {
        $HomeDir = $Matches[1]
    }
    elseif ($env:LOCAL_MCP_HOME) {
        $HomeDir = $env:LOCAL_MCP_HOME
    }
    else {
        $HomeDir = [Environment]::GetFolderPath('UserProfile')
    }
}
$HomeDir = [IO.Path]::GetFullPath($HomeDir)

$ScriptDir = $PSScriptRoot
$ClaudeHelper = Join-Path $ScriptDir 'update-claude-mcp.js'
$CCSwitchHelper = Join-Path $ScriptDir 'update-ccswitch-mcp.js'
$HermesHelper = Join-Path $ScriptDir 'update-hermes-mcp.py'

$CCSwitchDb = Join-Path $HomeDir '.cc-switch\cc-switch.db'
$ClaudeConfig = Join-Path $HomeDir '.claude.json'
$CodexHome = Join-Path $HomeDir '.codex'
$CodexConfig = Join-Path $CodexHome 'config.toml'
$HermesConfig = Join-Path $HomeDir 'AppData\Local\hermes\config.yaml'
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$BackupBase = Join-Path $HomeDir ".agent-backups\mcp-installer\$Timestamp"
$TempConfig = $null
$CCSwitchStopped = $false
$Backups = @{}

function Resolve-CCSwitchExe {
    if ($CCSwitchExe) {
        if (-not (Test-Path -LiteralPath $CCSwitchExe -PathType Leaf)) { throw "CC Switch executable not found: $CCSwitchExe" }
        return $CCSwitchExe
    }
    if ($env:CCSWITCH_EXE -and (Test-Path -LiteralPath $env:CCSWITCH_EXE -PathType Leaf)) {
        return $env:CCSWITCH_EXE
    }
    $running = Get-Process cc-switch -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($running -and $running.Path -and (Test-Path -LiteralPath $running.Path -PathType Leaf)) {
        return $running.Path
    }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\CC Switch\cc-switch.exe'),
        (Join-Path $env:ProgramFiles 'CC Switch\cc-switch.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'CC Switch\cc-switch.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    throw 'CC Switch executable not found. Use -CCSwitchExe or set CCSWITCH_EXE.'
}
function Write-KeyValue([string]$Key, [string]$Value) {
    Write-Output ("{0}={1}" -f $Key, $Value)
}

function Get-NormalizedAgents([string[]]$Values) {
    return @($Values | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
}

function Backup-File([string]$Path) {
    if ($Backups.ContainsKey($Path)) { return }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $destDir = Join-Path $BackupBase 'files'
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        $leaf = [IO.Path]::GetFileName($Path)
        $dest = Join-Path $destDir $leaf
        if (Test-Path -LiteralPath $dest) {
            $dest = Join-Path $destDir ((Get-Date -Format 'HHmmssfff') + '-' + $leaf)
        }
        Copy-Item -LiteralPath $Path -Destination $dest -Force
        $Backups[$Path] = $dest
    }
    else {
        $Backups[$Path] = '__MISSING__'
    }
}

function Restore-Backups {
    foreach ($path in $Backups.Keys) {
        $saved = $Backups[$path]
        if ($saved -eq '__MISSING__') {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force
            }
        }
        else {
            Copy-Item -LiteralPath $saved -Destination $path -Force
        }
    }
}

function Get-HermesPython {
    $envOverride = $env:LOCAL_MCP_HERMES_PYTHON
    if ($envOverride -and (Test-Path -LiteralPath $envOverride)) { return $envOverride }
    $candidates = @(Get-ChildItem -LiteralPath (Join-Path $HomeDir 'AppData\Local\hermes\installs') -Recurse -File -Filter 'python.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '[\\/]environments[\\/][^\\/]+[\\/]venv[\\/]Scripts[\\/]python\.exe$' } |
        Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) { return $null }
    return $candidates[0].FullName
}

function Get-ServerSelection {
    $raw = $null
    if (Test-Path -LiteralPath $Config -PathType Leaf) {
        $raw = Get-Content -LiteralPath $Config -Raw -Encoding utf8
        Write-KeyValue 'CONFIG_SOURCE' (Get-Item -LiteralPath $Config).FullName
    }
    else {
        $raw = $Config
        Write-KeyValue 'CONFIG_SOURCE' 'INLINE_JSON'
    }

    try { $obj = $raw | ConvertFrom-Json } catch { throw "Invalid MCP JSON: $($_.Exception.Message)" }
    $props = @($obj.PSObject.Properties.Name)

    if ($props -contains 'mcpServers') {
        $servers = @($obj.mcpServers.PSObject.Properties)
        if ($servers.Count -eq 0) { throw 'mcpServers is empty.' }
        if ($Name) {
            $selected = @($servers | Where-Object { $_.Name -ieq $Name })
            if ($selected.Count -ne 1) { throw "MCP server not found in config: $Name" }
            return [pscustomobject]@{ Name = $selected[0].Name; Server = $selected[0].Value }
        }
        if ($servers.Count -ne 1) {
            Write-Output 'MULTIPLE_MCP_SERVERS_FOUND='
            $servers | ForEach-Object { Write-Output ("  {0}" -f $_.Name) }
            throw 'Multiple MCP servers found. Re-run with -Name <server-name>.'
        }
        return [pscustomobject]@{ Name = $servers[0].Name; Server = $servers[0].Value }
    }

    if (($props -contains 'command') -or ($props -contains 'url')) {
        $selectedName = if ($Name) { $Name } elseif ($props -contains 'name') { [string]$obj.name } else { $null }
        if (-not $selectedName) { throw 'A single server config needs -Name or a name field.' }
        return [pscustomobject]@{ Name = $selectedName; Server = $obj }
    }

    throw 'Expected an mcpServers object or a single MCP server object with command/url.'
}

try {
    $normalizedAgents = @(Get-NormalizedAgents $Agents)
    $validAgents = @('codex', 'claude', 'hermes', 'none')
    $invalidAgents = @($normalizedAgents | Where-Object { $_ -notin $validAgents })
    if ($invalidAgents.Count -gt 0) {
        throw "Unsupported agent(s): $($invalidAgents -join ', '). WorkBuddy Connectors are managed separately. Valid values: $($validAgents -join ', ')"
    }
    if ($normalizedAgents -contains 'none') { $normalizedAgents = @('none') }

    $selection = Get-ServerSelection
    $serverName = [string]$selection.Name
    if ($serverName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw "Invalid MCP server name: $serverName"
    }

    $serverObject = $selection.Server
    if ($serverObject.PSObject.Properties.Name -contains 'name') {
        $serverObject.PSObject.Properties.Remove('name')
    }
    if ($serverObject.PSObject.Properties.Name -contains 'disabled') {
        $serverObject.disabled = $false
    }
    else {
        $serverObject | Add-Member -NotePropertyName disabled -NotePropertyValue $false
    }

    $command = [string]$serverObject.command
    $url = [string]$serverObject.url
    if (-not $command -and -not $url) {
        throw 'MCP config must provide either command or url.'
    }
    if ($url) {
        $uri = $null
        if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) {
            throw "Invalid MCP URL: $url"
        }
    }

    if ($command -and -not $AllowMissingCommand) {
        if ([IO.Path]::IsPathRooted($command)) {
            if (-not (Test-Path -LiteralPath $command -PathType Leaf)) { throw "MCP command not found: $command" }
        }
        elseif (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "MCP command not found on PATH: $command. Use -AllowMissingCommand only if it will be installed later."
        }
    }

    if ($url -and $serverObject.PSObject.Properties.Name -contains 'headers' -and $normalizedAgents -contains 'codex') {
        throw 'Codex header-based HTTP MCP registration is not automated yet. Use -Agents claude,hermes or remove Codex.'
    }

    $TempConfig = Join-Path ([IO.Path]::GetTempPath()) ("local-mcp-installer-" + [guid]::NewGuid().ToString('N') + '.json')
    $serverJson = $serverObject | ConvertTo-Json -Depth 30
    Set-Content -LiteralPath $TempConfig -Value $serverJson -Encoding utf8NoBOM

    $exists = [ordered]@{
        ccswitch = $false
        claude = $false
        codex = $false
        hermes = $false
    }

    if (-not $SkipCCSwitch) {
        if (-not (Test-Path -LiteralPath $CCSwitchDb)) { throw "CC Switch database not found: $CCSwitchDb" }
        $ccCheck = & node $CCSwitchHelper $CCSwitchDb $serverName $TempConfig ($normalizedAgents -join ',') 'false' 'check' 2>&1
        if ($LASTEXITCODE -ne 0) { throw "CC Switch check failed: $($ccCheck -join ' ')" }
        $exists.ccswitch = [bool](($ccCheck -join "`n") -match 'CC_SWITCH_EXISTS=true')
    }

    if ($normalizedAgents -contains 'claude' -and (Test-Path -LiteralPath $ClaudeConfig)) {
        $claudeJson = Get-Content -LiteralPath $ClaudeConfig -Raw -Encoding utf8 | ConvertFrom-Json
        if ($claudeJson.mcpServers -and ($claudeJson.mcpServers.PSObject.Properties.Name -contains $serverName)) {
            $exists.claude = $true
        }
    }

    if ($normalizedAgents -contains 'codex') {
        $oldCodexHome = $env:CODEX_HOME
        try {
            $env:CODEX_HOME = $CodexHome
            & codex mcp get $serverName *> $null
            $exists.codex = ($LASTEXITCODE -eq 0)
        }
        finally {
            $env:CODEX_HOME = $oldCodexHome
        }
    }

    $hermesPython = $null
    if ($normalizedAgents -contains 'hermes') {
        if (-not (Test-Path -LiteralPath $HermesConfig)) { throw "Hermes config not found: $HermesConfig" }
        $hermesPython = Get-HermesPython
        if (-not $hermesPython) { throw 'Hermes Python runtime with ruamel.yaml was not found.' }
        $hermesCheck = & $hermesPython $HermesHelper $HermesConfig $serverName $TempConfig 'check' 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Hermes check failed: $($hermesCheck -join ' ')" }
        $exists.hermes = [bool](($hermesCheck -join "`n") -match 'HERMES_MCP_EXISTS=true')
    }

    Write-KeyValue 'MCP_NAME' $serverName
    Write-KeyValue 'AGENTS' ($normalizedAgents -join ',')
    foreach ($key in $exists.Keys) {
        Write-KeyValue ("EXISTS_{0}" -f $key.ToUpperInvariant()) ([string]$exists[$key])
    }

    $conflicts = @($exists.Keys | Where-Object { $exists[$_] })
    if ($conflicts.Count -gt 0 -and -not $Force) {
        throw "MCP already exists in: $($conflicts -join ', '). Re-run with -Force after reviewing the replacement."
    }

    if ($DryRun) {
        Write-Output 'DRY_RUN=TRUE'
        Write-Output 'RESULT=NO_CHANGES_MADE'
        return
    }

    New-Item -ItemType Directory -Path $BackupBase -Force | Out-Null

    if (-not $SkipCCSwitch) {
        $CCSwitchExe = Resolve-CCSwitchExe
        $ccProcesses = @(Get-Process cc-switch -ErrorAction SilentlyContinue)
        if ($ccProcesses.Count -gt 0) {
            $ccProcesses | Stop-Process -Force
            Start-Sleep -Seconds 2
            $CCSwitchStopped = $true
        }
        Backup-File $CCSwitchDb
        Backup-File (Join-Path $HomeDir '.cc-switch\cc-switch.db-wal')
        Backup-File (Join-Path $HomeDir '.cc-switch\cc-switch.db-shm')
    }
    if ($normalizedAgents -contains 'claude') { Backup-File $ClaudeConfig }
    if ($normalizedAgents -contains 'codex') { Backup-File $CodexConfig }
    if ($normalizedAgents -contains 'hermes') { Backup-File $HermesConfig }

    try {
        if (-not $SkipCCSwitch) {
            $ccResult = & node $CCSwitchHelper $CCSwitchDb $serverName $TempConfig ($normalizedAgents -join ',') ([string]$Force).ToLowerInvariant() 2>&1
            if ($LASTEXITCODE -ne 0) { throw "CC Switch update failed: $($ccResult -join ' ')" }
            $ccResult | ForEach-Object { Write-Output $_ }
        }

        if ($normalizedAgents -contains 'claude') {
            $claudeResult = & node $ClaudeHelper $ClaudeConfig $serverName $TempConfig 'upsert' 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Claude config update failed: $($claudeResult -join ' ')" }
            $claudeResult | ForEach-Object { Write-Output $_ }
        }

        if ($normalizedAgents -contains 'codex') {
            $oldCodexHome = $env:CODEX_HOME
            try {
                $env:CODEX_HOME = $CodexHome
                if ($exists.codex -and $Force) {
                    & codex mcp remove $serverName *> $null
                    if ($LASTEXITCODE -ne 0) { throw "Failed to remove existing Codex MCP server: $serverName" }
                }
                $addArgs = @('mcp', 'add', $serverName)
                if ($url) {
                    $addArgs += @('--url', $url)
                    if ($serverObject.PSObject.Properties.Name -contains 'bearer_token_env_var') {
                        $addArgs += @('--bearer-token-env-var', [string]$serverObject.bearer_token_env_var)
                    }
                }
                else {
                    if ($serverObject.PSObject.Properties.Name -contains 'env' -and $serverObject.env) {
                        foreach ($envProp in $serverObject.env.PSObject.Properties) {
                            $addArgs += @('--env', ("{0}={1}" -f $envProp.Name, $envProp.Value))
                        }
                    }
                    $addArgs += '--'
                    $addArgs += $command
                    if ($serverObject.PSObject.Properties.Name -contains 'args' -and $serverObject.args) {
                        $addArgs += @($serverObject.args | ForEach-Object { [string]$_ })
                    }
                }
                & codex @addArgs 2>&1 | ForEach-Object { Write-Output $_ }
                if ($LASTEXITCODE -ne 0) { throw "Codex MCP registration failed: $serverName" }
            }
            finally {
                $env:CODEX_HOME = $oldCodexHome
            }
        }

        if ($normalizedAgents -contains 'hermes') {
            $hermesResult = & $hermesPython $HermesHelper $HermesConfig $serverName $TempConfig 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Hermes config update failed: $($hermesResult -join ' ')" }
            $hermesResult | ForEach-Object { Write-Output $_ }
        }

        Write-KeyValue 'BACKUP_ROOT' $BackupBase
        Write-Output 'RESULT=INSTALLED'
    }
    catch {
        Restore-Backups
        throw
    }
    finally {
        if ($CCSwitchStopped) {
            Start-Process -FilePath $CCSwitchExe -WorkingDirectory (Split-Path -Parent $CCSwitchExe)
            Start-Sleep -Seconds 8
            Write-Output 'CC_SWITCH=RESTARTED'
        }
        if (Test-Path -LiteralPath $BackupBase) {
            Write-KeyValue 'BACKUP_ROOT' $BackupBase
        }
    }

    if (-not $NoHealthCheck) {
        Write-Output '=== Health Check ==='
        if ($normalizedAgents -contains 'codex') {
            $oldCodexHome = $env:CODEX_HOME
            try {
                $env:CODEX_HOME = $CodexHome
                Write-Output '[Codex]'
                & codex mcp list 2>&1 | ForEach-Object { Write-Output $_ }
            }
            finally { $env:CODEX_HOME = $oldCodexHome }
        }
        if ($normalizedAgents -contains 'claude') {
            Write-Output '[Claude Code]'
            & claude mcp list 2>&1 | ForEach-Object { Write-Output $_ }
        }
        if ($normalizedAgents -contains 'hermes') {
            Write-Output '[Hermes]'
            Write-Output 'CONFIG_UPDATED=TRUE'
        }
    }

    Write-Output 'DONE'
}
finally {
    if ($TempConfig -and (Test-Path -LiteralPath $TempConfig)) {
        Remove-Item -LiteralPath $TempConfig -Force
    }
}

