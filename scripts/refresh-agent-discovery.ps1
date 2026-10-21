#Requires -Version 5.1
<#
.SYNOPSIS
Refresh the four managed toolbox discovery blocks using the existing writer.
.DESCRIPTION
Preserves content outside WIN_DEVTOOLS markers and uses Write-AgentBlock's normal
backups. No tool installation, PATH change or profile directory enumeration.
.EXAMPLE
.\scripts\refresh-agent-discovery.ps1 -DryRun
#>
[CmdletBinding()]
param([switch]$DryRun)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if ($DryRun) {
    foreach ($relative in @('CLAUDE.md', '.claude\CLAUDE.md', 'AGENTS.md', '.codex\AGENTS.md')) {
        Write-Host ('PLAN managed WIN_DEVTOOLS block: ' + (Join-Path $env:USERPROFILE $relative))
    }
    return
}
. (Join-Path $repoRoot 'lib\common.ps1')
Write-AgentDiscovery -RepoRoot $repoRoot
Write-Host 'Refreshed the four managed toolbox discovery blocks with normal backups.'