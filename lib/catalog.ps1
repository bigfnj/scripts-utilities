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

# The only catalog schema this code knows how to read. Bump it here and in
# catalog.json together, in the same commit that changes the shape.
$script:CatalogSchemaVersion = 1

function Get-Catalog {
    # Reject a catalog this code cannot read, rather than silently installing a
    # subset of it. catalog.json carried a schema_version with zero readers, which
    # is worse than not having one: a future reshape (renamed 'channel' values, a
    # nested tools list) would deserialise fine, produce $null for every field the
    # installer asks about, and skip tools without a single error. pc-maintenance
    # enforces its own at PMManifest.ps1:25-26; this is the same check.
    $path = Get-CatalogPath
    if (-not (Test-Path -LiteralPath $path)) { throw "catalog not found: $path" }
    $catalog = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $catalog) { throw "catalog is empty or not valid JSON: $path" }
    if (-not ($catalog.PSObject.Properties.Name -contains 'schema_version')) {
        throw "catalog has no schema_version (expected $script:CatalogSchemaVersion): $path"
    }
    if ([int]$catalog.schema_version -ne $script:CatalogSchemaVersion) {
        throw ("catalog schema_version {0} is not supported by this checkout (expected {1}): {2}" -f
               $catalog.schema_version, $script:CatalogSchemaVersion, $path)
    }
    return $catalog
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
    # Optional per-tool installer pin, for a manifest that ships several installers and defaults to the
    # wrong one. Absent on every tool but pwsh, and an absent value leaves the winget args untouched.
    $installerType = if ($Item.PSObject.Properties['installer_type']) { [string]$Item.installer_type } else { "" }
    switch ($Item.channel) {
        'winget-user' {
            $ok = Install-WingetTool -Id $Item.id -Binary $Item.binary -Name $Item.name -InstallerType $installerType
        }
        'winget-machine' {
            $ok = Install-WingetTool -Id $Item.id -Binary $Item.binary -Name $Item.name -MachineScope -InstallerType $installerType
            if ($ok -and $Item.path_fallback -and -not (Test-CommandAvailable $Item.binary)) {
                $expanded = [System.Environment]::ExpandEnvironmentVariables($Item.path_fallback)
                Add-UserPathEntry $expanded | Out-Null
            }
        }
        'winget-default' {
            # No --scope flag: the manifest declares no scope and winget rejects
            # both user and machine with 0x8A150010. Installs wherever the
            # package's own installer puts it (per-user for Podman).
            $ok = Install-WingetTool -Id $Item.id -Binary $Item.binary -Name $Item.name -NoScope -InstallerType $installerType
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
    # Install every item in a group and RETURN THE NUMBER THAT FAILED.
    #
    # Install-CatalogItem has always returned $true/$false, and this function threw
    # every one of those away with `| Out-Null`. Callers then printed "<group> group
    # complete" unconditionally and bootstrap finished with "bootstrap complete", so
    # a run in which every single winget install failed was indistinguishable from a
    # clean one. The count is the caller's evidence; a caller that ignores it is back
    # where we started.
    param([Parameter(Mandatory)][string]$Group)
    $failed = 0
    foreach ($item in (Get-CatalogTools -Group $Group)) {
        if (-not (Install-CatalogItem -Item $item)) {
            $failed++
            Write-Warn "install failed: $($item.name) [$($item.channel) $($item.id)]"
        }
    }
    return $failed
}
