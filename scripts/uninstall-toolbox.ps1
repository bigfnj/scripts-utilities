#Requires -Version 5.1
<#
Full-reset uninstaller for the Windows dev toolbox.

By default this removes the toolbox LAYER only - everything the toolbox owns and
can safely reverse - and leaves winget-installed tools (gh, fzf, ffmpeg,
LibreOffice, ...) under winget's own management:

  - deletes the DevToolbox directory (%LOCALAPPDATA%\DevToolbox or CODEX_TOOLBOX),
  - unregisters the user PATH entries and env vars the toolbox added,
  - strips the agent-discovery blocks from CLAUDE.md / AGENTS.md,
  - removes the generated manifest/tools.json and the Sysinternals EULA keys.

With -RemoveWingetTools it ALSO winget-uninstalls / npm-uninstalls the gap-fill
tools, but ONLY those the manifest records as installed by the toolbox
(installed_by_toolbox=true) - tools that pre-existed are left alone. Machine-scope
uninstalls need elevation; if this session is not elevated they are reported and
skipped.

  .\scripts\uninstall-toolbox.ps1 -DryRun          # show exactly what would change
  .\scripts\uninstall-toolbox.ps1                  # toolbox layer only (prompts to confirm)
  .\scripts\uninstall-toolbox.ps1 -RemoveWingetTools
  .\scripts\uninstall-toolbox.ps1 -Yes             # skip the typed confirmation
#>
[CmdletBinding()]
param(
    [switch]$RemoveWingetTools,
    [switch]$DryRun,
    [switch]$Yes
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$REPO_ROOT = Split-Path $PSScriptRoot
. (Join-Path $REPO_ROOT "lib\common.ps1")
. (Join-Path $REPO_ROOT "lib\catalog.ps1")
if ($DryRun) { $script:DryRun = $true }

$MANIFEST_PATH = Join-Path $REPO_ROOT "manifest\tools.json"
$toolboxRoot = if ($env:CODEX_TOOLBOX) { [System.IO.Path]::GetFullPath($env:CODEX_TOOLBOX) }
               else { Join-Path $env:LOCALAPPDATA "DevToolbox" }

function Test-IsElevated {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return ([System.Security.Principal.WindowsPrincipal]$id).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# -- Confirmation --------------------------------------------------------------
Write-Group "uninstall toolbox"
Write-Info "toolbox root:      $toolboxRoot"
Write-Info "remove winget tools: $([bool]$RemoveWingetTools)"
Write-Info "mode:              $(if ($DryRun) { 'DRY-RUN (no changes)' } else { 'LIVE' })"

if (-not $DryRun -and -not $Yes) {
    $answer = Read-Host "This permanently removes the toolbox. Type REMOVE to continue"
    if ($answer -ne "REMOVE") { Write-Warn "aborted - confirmation not given"; exit 1 }
}

# -- 1. Optionally uninstall the gap-fill tools we installed --------------------
if ($RemoveWingetTools) {
    Write-Group "remove installed gap-fill tools (provenance-aware)"
    if (Test-Path -LiteralPath $MANIFEST_PATH) {
        # Assign first, THEN wrap: PowerShell 5.1's ConvertFrom-Json emits an array
        # as a single pipeline object, so @(... | ConvertFrom-Json) would nest it.
        $loaded = Get-Content -LiteralPath $MANIFEST_PATH -Raw | ConvertFrom-Json
        $tools = @($loaded)
        foreach ($t in $tools) {
            # Provenance: only remove what the toolbox installed. Anything recorded
            # as pre-existing, or with install_method 'existing' (detected, not
            # installed by us - e.g. Ghidra, Npcap), is left untouched.
            $ours = -not ($t.PSObject.Properties.Name -contains 'installed_by_toolbox') -or $t.installed_by_toolbox
            if (-not $ours -or $t.install_method -eq 'existing') {
                Write-Skip "keep (not installed by toolbox): $($t.name)"
                continue
            }
            switch ($t.install_method) {
                'winget' {
                    if (-not $t.winget_id) { Write-Warn "no winget_id for $($t.name) - skipping"; continue }
                    if ($t.scope -eq 'machine' -and -not (Test-IsElevated)) {
                        Write-Warn "skip $($t.name): machine-scope uninstall needs elevation (re-run elevated)"
                        continue
                    }
                    if ($DryRun) { Write-Info "[DRY-RUN] would: winget uninstall --id $($t.winget_id)"; continue }
                    Write-Info "winget uninstall $($t.winget_id)"
                    winget uninstall --id $t.winget_id -e --silent --accept-source-agreements | Out-Null
                }
                'npm-global' {
                    if (-not (Test-CommandAvailable 'npm')) { Write-Warn "npm not found - skipping $($t.name)"; continue }
                    if ($DryRun) { Write-Info "[DRY-RUN] would: npm uninstall -g $($t.name)"; continue }
                    Write-Info "npm uninstall -g $($t.name)"
                    npm uninstall -g $t.name | Out-Null
                }
                'pip-toolbox' {
                    Write-Skip "$($t.name): lives in the venv, removed with the toolbox directory"
                }
                default { Write-Skip "no removal path for method '$($t.install_method)': $($t.name)" }
            }
        }
    } else {
        Write-Warn "manifest not found ($MANIFEST_PATH) - cannot determine which tools were ours; skipping tool removal"
    }
}

# -- 2. Reverse the side effects recorded in the catalog ------------------------
Write-Group "unregister PATH / env / registry side effects"
$catalog = Get-Catalog
$se = $catalog.side_effects

foreach ($rel in @($se.path_entries_relative)) {
    Remove-UserPathEntry (Join-Path $toolboxRoot $rel)
}
foreach ($abs in @($se.path_entries_absolute)) {
    Remove-UserPathEntry ([System.Environment]::ExpandEnvironmentVariables($abs))
}
foreach ($var in @($se.env_vars)) {
    $val = [System.Environment]::GetEnvironmentVariable($var, "User")
    if (-not $val) { continue }
    if ($DryRun) { Write-Info "[DRY-RUN] would clear User env var: $var"; continue }
    [System.Environment]::SetEnvironmentVariable($var, $null, "User")
    Write-Ok "cleared User env var: $var"
}
foreach ($key in @($se.registry_keys)) {
    if (-not (Test-Path -LiteralPath $key)) { continue }
    if ($DryRun) { Write-Info "[DRY-RUN] would remove registry key: $key"; continue }
    Remove-Item -LiteralPath $key -Recurse -Force
    Write-Ok "removed registry key: $key"
}

# -- 3. Strip agent-discovery blocks -------------------------------------------
Write-Group "strip agent-discovery blocks"
Remove-AgentBlocks

# -- 4. Remove the generated manifest ------------------------------------------
if (Test-Path -LiteralPath $MANIFEST_PATH) {
    if ($DryRun) { Write-Info "[DRY-RUN] would remove generated manifest: $MANIFEST_PATH" }
    else { Remove-Item -LiteralPath $MANIFEST_PATH -Force; Write-Ok "removed generated manifest" }
}

# -- 5. Delete the toolbox directory (guarded) ---------------------------------
Write-Group "remove toolbox directory"
if (Test-Path -LiteralPath $toolboxRoot) {
    # Safety: only delete a directory that (a) is not a drive root or a known
    # protected system/profile path, and (b) actually contains toolbox structure.
    # Requiring a toolbox marker means even a mis-set CODEX_TOOLBOX cannot point us
    # at, say, C:\Windows - there is no marker there, so we refuse and skip.
    $resolved = (Resolve-Path -LiteralPath $toolboxRoot).Path.TrimEnd('\')
    $protected = @(
        $env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:USERPROFILE,
        $env:LOCALAPPDATA, $env:APPDATA, $env:SystemDrive, $env:ProgramData
    ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    $tooShort = ($resolved -match '^[A-Za-z]:\\?$') -or ($resolved.Split('\').Count -lt 3)
    $isProtected = $tooShort -or ($protected -contains $resolved)
    $hasMarker = (Test-Path (Join-Path $resolved 'toolbox-manifest.json')) -or
                 (Test-Path (Join-Path $resolved 'native\bin')) -or
                 (Test-Path (Join-Path $resolved 'python\.venv'))
    if ($isProtected -or -not $hasMarker) {
        Write-Err "Refusing to delete '$resolved': protected path, or no toolbox marker (toolbox-manifest.json / native\bin / python\.venv). Skipped."
    } elseif ($DryRun) {
        Write-Info "[DRY-RUN] would delete toolbox directory: $resolved"
    } else {
        Remove-Item -LiteralPath $resolved -Recurse -Force
        Write-Ok "deleted toolbox directory: $resolved"
    }
} else {
    Write-Skip "toolbox directory not present: $toolboxRoot"
}

Write-Group "done"
if ($DryRun) { Write-Info "[DRY-RUN] complete - no changes were made" }
else { Write-Ok "toolbox uninstall complete" }
