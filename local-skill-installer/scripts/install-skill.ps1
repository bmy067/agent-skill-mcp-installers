[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Source,

    [string[]]$Agents = @('codex', 'claude'),

    [string]$Name,

    [switch]$Force,

    [switch]$DryRun,

    [string]$HomeDir
)

$ErrorActionPreference = 'Stop'
if (-not $HomeDir) {
    if ($PSScriptRoot -match '^(.*?)[\\/]\.agents[\\/]skills[\\/]') {
        $HomeDir = $Matches[1]
    }
    elseif ($env:LOCAL_SKILL_HOME) {
        $HomeDir = $env:LOCAL_SKILL_HOME
    }
    else {
        $HomeDir = [Environment]::GetFolderPath('UserProfile')
    }
}
$HomeDir = [IO.Path]::GetFullPath($HomeDir)
$Master = Join-Path $HomeDir '.agents\skills'
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$BackupBase = Join-Path $HomeDir ".agent-backups\skill-installer\$Timestamp"
$TempRoot = $null
$Staging = $null

function Write-KeyValue([string]$Key, [string]$Value) {
    Write-Output ("{0}={1}" -f $Key, $Value)
}

function Get-NormalizedName([string]$Value) {
    $normalized = $Value.Trim().ToLowerInvariant()
    $normalized = $normalized -replace '[^a-z0-9]+', '-'
    $normalized = $normalized.Trim('-')
    return $normalized
}

function Get-SkillMetadata([string]$SkillFile) {
    $lines = Get-Content -LiteralPath $SkillFile -Encoding utf8
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') {
        throw "SKILL.md is missing YAML frontmatter: $SkillFile"
    }

    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') {
            $end = $i
            break
        }
    }
    if ($end -lt 0) {
        throw "SKILL.md frontmatter is not closed: $SkillFile"
    }

    $frontmatter = @($lines[1..($end - 1)])
    $name = $null
    $description = $null
    for ($i = 0; $i -lt $frontmatter.Count; $i++) {
        $line = $frontmatter[$i]
        if (-not $name -and $line -match '^name:\s*(.*?)\s*$') {
            $name = $Matches[1].Trim().Trim('"').Trim("'")
        }
        elseif (-not $description -and $line -match '^description:\s*(.*?)\s*$') {
            $value = $Matches[1].Trim()
            if ($value -match '^[>|][+-]?$' -or -not $value) {
                $parts = @()
                for ($j = $i + 1; $j -lt $frontmatter.Count; $j++) {
                    $next = $frontmatter[$j]
                    if ($next -match '^\S') { break }
                    $parts += $next.Trim()
                }
                if ($value.StartsWith('|')) {
                    $description = $parts -join "`n"
                }
                else {
                    $description = ($parts -join ' ').Trim()
                }
            }
            else {
                $description = $value.Trim('"').Trim("'")
            }
        }
    }

    if (-not $name) { throw "SKILL.md frontmatter is missing name: $SkillFile" }
    if (-not $description) { throw "SKILL.md frontmatter is missing description: $SkillFile" }

    return [pscustomobject]@{
        Name = $name
        Description = $description
    }
}

function Get-TreeManifest([string]$Root) {
    $result = @{}
    $excludedDirs = @('.git', '__pycache__', 'node_modules', '.venv', 'venv')
    Get-ChildItem -LiteralPath $Root -Recurse -Force -File | Where-Object {
        $relative = $_.FullName.Substring($Root.Length).TrimStart('\')
        $segments = $relative -split '[\\/]'
        -not ($segments | Where-Object { $excludedDirs -contains $_ })
    } | ForEach-Object {
        $relative = $_.FullName.Substring($Root.Length).TrimStart('\')
        $result[$relative] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
    return $result
}

function Test-TreeEqual([string]$Left, [string]$Right) {
    $leftItems = Get-TreeManifest $Left
    $rightItems = Get-TreeManifest $Right
    if ($leftItems.Count -ne $rightItems.Count) { return $false }
    foreach ($key in $leftItems.Keys) {
        if (-not $rightItems.ContainsKey($key)) { return $false }
        if ($leftItems[$key] -ne $rightItems[$key]) { return $false }
    }
    return $true
}

function Test-SameLinkTarget([string]$Path, [string]$Target) {
    $item = Get-Item -LiteralPath $Path -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $currentTarget = @($item.Target)[0]
    if (-not $currentTarget) { return $false }
    return ([IO.Path]::GetFullPath($currentTarget) -eq [IO.Path]::GetFullPath($Target))
}

function Copy-SkillTree([string]$From, [string]$To) {
    $excludedDirs = @('.git', '__pycache__', 'node_modules', '.venv', 'venv')
    New-Item -ItemType Directory -Path $To -Force | Out-Null
    Get-ChildItem -LiteralPath $From -Force | ForEach-Object {
        if ($_.PSIsContainer) {
            if ($excludedDirs -contains $_.Name) { return }
            Copy-SkillTree -From $_.FullName -To (Join-Path $To $_.Name)
        }
        else {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $To $_.Name) -Force
        }
    }
}

function Move-ToBackup([string]$Path, [string]$Category, [string]$LeafName) {
    $destination = Join-Path (Join-Path $BackupBase $Category) $LeafName
    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Move-Item -LiteralPath $Path -Destination $destination
    return $destination
}

function Ensure-AgentLink([string]$Path, [string]$Target, [string]$AgentName) {
    if (Test-Path -LiteralPath $Path) {
        if (Test-SameLinkTarget $Path $Target) {
            Write-KeyValue "LINK_$AgentName" "KEPT $Path -> $Target"
            return
        }
        if (-not $Force) {
            throw "Agent entry already exists and is not the expected link: $Path. Re-run with -Force after reviewing it."
        }
        $backup = Move-ToBackup $Path 'agent-links' ("$AgentName-" + (Split-Path -Leaf $Path))
        Write-KeyValue "LINK_BACKUP_$AgentName" $backup
    }
    New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop | Out-Null
    Write-KeyValue "LINK_$AgentName" "CREATED $Path -> $Target"
}

function Find-SkillRoots([string]$Root) {
    $rootSkill = Join-Path $Root 'SKILL.md'
    if (Test-Path -LiteralPath $rootSkill -PathType Leaf) {
        return @((Get-Item -LiteralPath $Root -Force))
    }
    $candidates = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter 'SKILL.md' -File -Force |
        Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules|__pycache__)[\\/]' } |
        ForEach-Object { Get-Item -LiteralPath $_.DirectoryName -Force })
    return $candidates
}

function Resolve-Source([string]$InputPath) {
    if (-not (Test-Path -LiteralPath $InputPath)) {
        throw "Source not found: $InputPath"
    }
    $full = (Get-Item -LiteralPath $InputPath -Force).FullName
    if (Test-Path -LiteralPath $full -PathType Container) {
        return [pscustomobject]@{ Root = $full; Temporary = $false }
    }

    if ((Split-Path -Leaf $full) -eq 'SKILL.md') {
        return [pscustomobject]@{ Root = (Split-Path -Parent $full); Temporary = $false }
    }

    $extension = [IO.Path]::GetExtension($full).ToLowerInvariant()
    if ($extension -in @('.zip', '.skill')) {
        $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("local-skill-installer-" + [guid]::NewGuid().ToString('N'))
        $extract = Join-Path $script:TempRoot 'extract'
        New-Item -ItemType Directory -Path $extract -Force | Out-Null
        $zipCopy = Join-Path $script:TempRoot 'source.zip'
        Copy-Item -LiteralPath $full -Destination $zipCopy -Force
        Expand-Archive -LiteralPath $zipCopy -DestinationPath $extract -Force
        return [pscustomobject]@{ Root = $extract; Temporary = $true }
    }

    throw "Unsupported source. Provide a skill directory, SKILL.md, .zip, or .skill archive: $full"
}

try {
    Write-KeyValue 'SOURCE' $Source
    $resolved = Resolve-Source $Source
    $candidateRoots = @(Find-SkillRoots $resolved.Root)

    if ($candidateRoots.Count -eq 0) {
        throw 'No SKILL.md found in the source.'
    }

    if ($candidateRoots.Count -gt 1 -and $Name) {
        $requested = Get-NormalizedName $Name
        $matched = @($candidateRoots | Where-Object {
            $meta = Get-SkillMetadata (Join-Path $_.FullName 'SKILL.md')
            (Get-NormalizedName $meta.Name) -eq $requested -or (Get-NormalizedName $_.Name) -eq $requested
        })
        if ($matched.Count -eq 1) { $candidateRoots = $matched }
    }

    if ($candidateRoots.Count -gt 1) {
        Write-Output 'MULTIPLE_SKILLS_FOUND='
        $candidateRoots | ForEach-Object {
            $meta = Get-SkillMetadata (Join-Path $_.FullName 'SKILL.md')
            Write-Output ("  {0} | {1}" -f $meta.Name, $_.FullName)
        }
        throw 'Multiple skills found. Re-run with -Name <skill-name> to select one.'
    }

    $skillRoot = $candidateRoots[0].FullName
    $skillFile = Join-Path $skillRoot 'SKILL.md'
    $metadata = Get-SkillMetadata $skillFile
    $installName = if ($Name) { Get-NormalizedName $Name } else { Get-NormalizedName $metadata.Name }
    if (-not $installName -or $installName.Length -gt 63) {
        throw "Invalid or too-long skill name: $installName"
    }

    $normalizedAgents = @($Agents | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
    $validAgents = @('codex', 'claude', 'hermes', 'workbuddy', 'none')
    $invalidAgents = @($normalizedAgents | Where-Object { $_ -notin $validAgents })
    if ($invalidAgents.Count -gt 0) {
        throw "Unknown agent(s): $($invalidAgents -join ', '). Valid values: $($validAgents -join ', ')"
    }
    if ($normalizedAgents -contains 'none') {
        $normalizedAgents = @('none')
    }

    $masterTarget = Join-Path $Master $installName
    Write-KeyValue 'SKILL_NAME' $metadata.Name
    Write-KeyValue 'INSTALL_NAME' $installName
    Write-KeyValue 'SOURCE_SKILL_ROOT' $skillRoot
    Write-KeyValue 'TARGET' $masterTarget
    Write-KeyValue 'AGENTS' ($normalizedAgents -join ',')

    $action = 'INSTALL'
    if (Test-Path -LiteralPath $masterTarget) {
        if ([IO.Path]::GetFullPath($skillRoot) -eq [IO.Path]::GetFullPath($masterTarget)) {
            $action = 'ALREADY_IN_MASTER'
        }
        elseif (Test-TreeEqual $skillRoot $masterTarget) {
            $action = 'KEEP_EXISTING_IDENTICAL'
        }
        elseif ($Force) {
            $action = 'REPLACE'
        }
        else {
            throw "Skill already exists with different content: $masterTarget. Re-run with -Force after reviewing it."
        }
    }
    Write-KeyValue 'ACTION' $action

    $agentRoots = @{
        codex = Join-Path $HomeDir '.codex\skills'
        claude = Join-Path $HomeDir '.claude\skills'
        workbuddy = Join-Path $HomeDir '.workbuddy\skills'
    }

    foreach ($agent in $normalizedAgents) {
        if ($agent -eq 'none' -or $agent -eq 'hermes') { continue }
        $agentRoot = $agentRoots[$agent]
        if (-not $agentRoot -or -not (Test-Path -LiteralPath $agentRoot -PathType Container)) {
            throw "Agent skills directory not found for ${agent}: $agentRoot"
        }
        Write-KeyValue "PLAN_LINK_$agent" (Join-Path $agentRoot $installName)
    }

    if ($normalizedAgents -contains 'hermes') {
        $hermesConfig = Join-Path $HomeDir 'AppData\Local\hermes\config.yaml'
        if (-not (Test-Path -LiteralPath $hermesConfig)) {
            throw "Hermes config not found: $hermesConfig"
        }
        $hermesText = Get-Content -LiteralPath $hermesConfig -Raw -Encoding utf8
        $sharedSkills = Join-Path $HomeDir '.agents\skills'
        if ($hermesText -notmatch [regex]::Escape($sharedSkills)) {
            throw "Hermes skills.external_dirs does not include $sharedSkills."
        }
        Write-KeyValue 'HERMES_EXTERNAL_DIRS' 'OK'
    }

    if ($DryRun) {
        Write-Output 'DRY_RUN=TRUE'
        Write-Output 'RESULT=NO_CHANGES_MADE'
        return
    }

    New-Item -ItemType Directory -Path $Master -Force | Out-Null

    if ($action -eq 'REPLACE') {
        $backup = Move-ToBackup $masterTarget 'skills' $installName
        Write-KeyValue 'SKILL_BACKUP' $backup
    }

    if ($action -in @('INSTALL', 'REPLACE')) {
        $Staging = Join-Path $Master (".install-{0}-{1}" -f $installName, [guid]::NewGuid().ToString('N'))
        Copy-SkillTree -From $skillRoot -To $Staging
        if (-not (Test-Path -LiteralPath (Join-Path $Staging 'SKILL.md'))) {
            throw 'Staged copy is missing SKILL.md.'
        }
        Move-Item -LiteralPath $Staging -Destination $masterTarget
        $Staging = $null
        Write-KeyValue 'RESULT' 'INSTALLED'
    }
    else {
        Write-KeyValue 'RESULT' $action
    }

    foreach ($agent in $normalizedAgents) {
        if ($agent -eq 'none' -or $agent -eq 'hermes') { continue }
        $agentRoot = $agentRoots[$agent]
        Ensure-AgentLink -Path (Join-Path $agentRoot $installName) -Target $masterTarget -AgentName $agent
    }

    if ($normalizedAgents -contains 'hermes') {
        Write-KeyValue 'HERMES_NOTE' 'Hermes reads the canonical directory through skills.external_dirs.'
    }

    Write-KeyValue 'CC_SWITCH_IMPORT' 'OPTIONAL: use CC Switch -> Skills -> Import if UI registration is required.'
    Write-KeyValue 'BACKUP_ROOT' $BackupBase
    Write-Output 'DONE'
}
finally {
    if ($Staging -and (Test-Path -LiteralPath $Staging)) {
        $resolvedStaging = [IO.Path]::GetFullPath($Staging)
        if ($resolvedStaging.StartsWith([IO.Path]::GetFullPath($Master), [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedStaging -Recurse -Force
        }
    }
    if ($TempRoot -and (Test-Path -LiteralPath $TempRoot)) {
        $resolvedTemp = [IO.Path]::GetFullPath($TempRoot)
        $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
        }
    }
}





