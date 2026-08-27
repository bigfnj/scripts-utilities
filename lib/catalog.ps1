# Catalog loader + install dispatcher.
#
# Get-Catalog / Get-CatalogTools are dependency-free (pure JSON reads) so any
# standalone script can source this file just to read the catalog. The
# install/state functions assume lib/common.ps1 has already been dot-sourced
# (they call Install-WingetTool, Install-PipToolbox, Install-NpmGlobal,
# Add-WinManifest, Add-UserPathEntry, Test-CommandAvailable, Get-ToolboxPython).

function Get-CatalogPath {
    # catalog.json lives at the repository root (this file is in <repo>\lib).
    Join-Path (Split-Path $PSScriptRoot) "catalog.json"
}

function Get-Catalog {
    $path = Get-CatalogPath
    if (-not (Test-Path -LiteralPath $path)) { throw "catalog not found: $path" }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-CatalogTools {
    param([string]$Group)
    $tools = @((Get-Catalog).tools)
    if ($Group) { $tools = @($tools | Where-Object { $_.group -eq $Group }) }
    return $tools
}

function Get-CatalogItem {
    param([Parameter(Mandatory)][string]$Name)
    return (Get-CatalogTools | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
}

function Get-CatalogItemState {
    # Read-only status probe. Returns [pscustomobject]@{ installed = [bool] }.
    param($Item)
    if ($Item.channel -eq 'pip-toolbox') {
        $py = Get-ToolboxPython
        if (-not $py) { return [pscustomobject]@{ installed = $false } }
        $imp = if ($Item.import) { $Item.import } else { ($Item.id -split '\[')[0] -replace '-', '_' }
        & $py -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('$imp') else 1)"
        return [pscustomobject]@{ installed = ($LASTEXITCODE -eq 0) }
    }
    $present = $Item.binary -and (Test-CommandAvailable $Item.binary)
    return [pscustomobject]@{ installed = [bool]$present }
}

function Install-CatalogItem {
    # Install one catalog item, dispatching by channel to the shared helpers, and
    # record it in the manifest with provenance unless it opts out. Returns $true
    # on success.
    param($Item)

    # Provenance: was it already present BEFORE we touched it? (Skip the probe in
    # dry-run - nothing is installed, so provenance is not recorded anyway.)
    $preexisting = if ($script:DryRun) { $false } else { (Get-CatalogItemState -Item $Item).installed }

    $ok = $false
    switch ($Item.channel) {
        'winget-user' {
            $ok = Install-WingetTool -Id $Item.id -Binary $Item.binary -Name $Item.name
        }
        'winget-machine' {
            $ok = Install-WingetTool -Id $Item.id -Binary $Item.binary -Name $Item.name -MachineScope
            if ($ok -and $Item.path_fallback -and -not (Test-CommandAvailable $Item.binary)) {
                $expanded = [System.Environment]::ExpandEnvironmentVariables($Item.path_fallback)
                Add-UserPathEntry $expanded | Out-Null
            }
        }
        'winget-default' {
            # No --scope flag: the manifest declares no scope and winget rejects
            # both user and machine with 0x8A150010. Installs wherever the
            # package's own installer puts it (per-user for Podman).
            $ok = Install-WingetTool -Id $Item.id -Binary $Item.binary -Name $Item.name -NoScope
            if ($ok -and $Item.path_fallback -and -not (Test-CommandAvailable $Item.binary)) {
                $expanded = [System.Environment]::ExpandEnvironmentVariables($Item.path_fallback)
                Add-UserPathEntry $expanded | Out-Null
            }
        }
        'pip-toolbox' {
            $imp = if ($Item.import) { $Item.import } else { "" }
            $ok = Install-PipToolbox -Package $Item.id -ImportName $imp
        }
        'npm-global' {
            $ok = Install-NpmGlobal -Package $Item.id -Binary $Item.binary
        }
        default {
            Write-Warn "unknown channel '$($Item.channel)' for $($Item.name) - skipping"
            return $false
        }
    }
    if (-not $ok) { return $false }

    # A venv install may have added new console scripts; wrap them into native\bin
    # (keeps the venv Scripts dir - and its python.exe - off PATH) and refresh the
    # session PATH so the wrapper is resolvable for the manifest detect below.
    if ($Item.channel -eq 'pip-toolbox' -and -not $script:DryRun) {
        New-VenvCliWrappers
        Sync-EnvPath
    }

    # Record in the manifest unless the item opts out (import-only libs with no
    # CLI, e.g. pytoshop) or exposes no binary. Machine-scope binaries are only
    # recorded once actually resolvable, so the smoke test's Phase-1 binary check
    # does not fail on a package that needs a fresh shell to appear on PATH.
    $optOut = ($Item.PSObject.Properties.Name -contains 'register_manifest') -and ($Item.register_manifest -eq $false)
    $registerable = $Item.binary -and -not $optOut
    $machineNotYetVisible = ($Item.channel -eq 'winget-machine') -and -not (Test-CommandAvailable $Item.binary)
    if ($registerable -and -not $machineNotYetVisible) {
        $method = if ($Item.channel -like 'winget-*') { 'winget' } else { $Item.channel }
        $scope = switch ($Item.channel) {
            'winget-user'    { 'user' }
            'winget-machine' { 'machine' }
            'winget-default' { 'default' }
            'pip-toolbox'    { 'toolbox' }
            'npm-global'     { 'user' }
        }
        $wingetId = if ($Item.channel -like 'winget-*') { $Item.id } else { "" }
        $detect = if ($Item.detect) { $Item.detect } else { "" }
        Add-WinManifest -Name $Item.name -Binary $Item.binary -Group $Item.group -Method $method `
            -Detect $detect -Scope $scope -WingetId $wingetId -Notes $Item.notes `
            -InstalledByToolbox:(-not $preexisting)
    }
    return $true
}

function Install-CatalogGroup {
    param([Parameter(Mandatory)][string]$Group)
    foreach ($item in (Get-CatalogTools -Group $Group)) {
        Install-CatalogItem -Item $item | Out-Null
    }
}
