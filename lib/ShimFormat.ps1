# Shared CMD compatibility bytes and EXE-backed native shim publication.
# NativeShim.cs owns process forwarding; all target selection stays with callers.
#
# WHY THIS FILE IS SEPARATE FROM lib\ShimPlan.ps1. Seven places in this repo write a shim and
# three read one back, and until now every one of them carried its own copy of the format. That
# is the drift shape this project keeps closing elsewhere, so the two functions became shared -
# but the obvious home, ShimPlan.ps1, could not reach the callers that needed them:
#
#   scripts\build-devtoolbox.ps1  dot-sources NOTHING. It is deliberately standalone because
#                                 bootstrap.ps1 invokes it as a child process.
#   modules\security.ps1          dot-sources nothing either; it is dot-sourced BY bootstrap.ps1,
#                                 whose scope has lib\common.ps1 but not lib\ShimPlan.ps1.
#
# Dragging 958 lines of planner into every bootstrap run to obtain a two-line string builder is
# the wrong trade, so the contract lives here and the planner consumes it like everyone else.
# Dot-sourced by lib\common.ps1 (which reaches bootstrap, the modules and the smoke test), by
# lib\ShimPlan.ps1 (which reaches consolidate-path.ps1), and directly by build-devtoolbox.ps1.
#
# Functions only. No side effects on dot-source, so any script can source it just to read or
# write one wrapper.

function New-ShimBody {
    <#
        THE one definition of the shim byte shape:  @echo off<CRLF>"<abs target>" %*<CRLF>
        ASCII, no BOM, written with -NoNewline so nothing appends a third line.

        A LITERAL `r`n, never [Environment]::NewLine and never a here-string. The bytes have to
        be a property of THIS CODE, not of the machine or of the checkout: the repo has
        core.autocrlf=true and no .gitattributes, so a here-string's line endings are whatever
        git handed this working copy. build-devtoolbox.ps1's New-CmdWrapper was exactly that
        here-string until 2026-09-11 - the rule was written down here while the largest writer in
        the repo violated it.

        The consequence is not cosmetic. Every reader anchors its regex on $, so a lone LF makes
        every shim unparseable and the smoke test reports 47 healthy shims as 0 stale ones - a
        silent, total loss of the only check that notices a broken wrapper.

        -Prologue exists for exactly one caller: modules\security.ps1 wraps Ghidra with a
        `set "JAVA_HOME=..."` line so the launcher gets a private JDK without a global change.
        It is a list of whole lines inserted after `@echo off`, never interpolated into the
        target line, so it cannot alter the shape the readers depend on.
    #>
    param(
        [Parameter(Mandatory)][string]$Target,
        [string[]]$Prologue = @()
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("@echo off`r`n")
    foreach ($line in @($Prologue)) {
        if ($null -eq $line -or $line -eq '') { continue }
        [void]$sb.Append($line)
        [void]$sb.Append("`r`n")
    }
    [void]$sb.Append("`"$Target`" %*`r`n")
    return $sb.ToString()
}

function Get-ShimTarget {
    <#
        The target a wrapper points at, or $null if no line matches.

        SCANS FOR THE FIRST MATCHING LINE - never "read the second line". The Ghidra wrapper is
        three lines with `set "JAVA_HOME=..."` in the middle, and a positional read would report
        the JAVA_HOME assignment as Ghidra's target.
    #>
    param([string[]]$Lines = @())
    foreach ($line in @($Lines)) {
        if ($null -eq $line) { continue }
        if ($line -match '^"([^"]+)" %\*$') { return $Matches[1] }
    }
    return $null
}

function Get-NativeShimConfiguration {
    # Only the shared literal target line plus SETLOCAL and quoted SET assignments
    # are translatable. Hand-written control flow and batch targets stay explicit CMD.
    param([Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Lines)
    $meaningful = @($Lines | Where-Object { $_ -ne '' })
    if ($meaningful.Count -lt 2 -or $meaningful[0] -ine '@echo off') { return $null }
    $target = Get-ShimTarget -Lines $Lines
    if (-not $target -or [IO.Path]::GetExtension($target) -ine '.exe') { return $null }
    if (-not [IO.Path]::IsPathRooted($target) -or $target -match '[%"\r\n]' -or
        $target -notmatch '^(?:[A-Za-z]:\\|\\\\)') { return $null }
    $environment = New-Object 'System.Collections.Generic.List[object]'
    $targets = 0
    foreach ($line in $Lines) {
        if ($line -eq '' -or $line -ieq '@echo off' -or $line -ieq 'setlocal') { continue }
        if ($line -cmatch '^"([^"]+)" %\*$') { $targets++; continue }
        if ($line -cmatch '^set "([^=\r\n%"]+)=([^\r\n"]*)"$') {
            if ($targets -ne 0) { return $null }
            $name = $Matches[1]
            $value = $Matches[2]
            $unmatched = [regex]::Replace($value, '%[A-Za-z_][A-Za-z0-9_()]*%', '')
            if ($unmatched.Contains('%') -or $value.Contains('!')) { return $null }
            $dynamic = @('CD', 'DATE', 'TIME', 'RANDOM', 'ERRORLEVEL', 'CMDEXTVERSION', 'CMDCMDLINE', 'HIGHESTNUMANODENUMBER', '__APPDIR__', '__CD__')
            foreach ($reference in [regex]::Matches($value, '%([A-Za-z_][A-Za-z0-9_()]*)%')) {
                if ($dynamic -contains $reference.Groups[1].Value) { return $null }
            }
            $environment.Add([ordered]@{ name = $name; value = $value })
        } else { return $null }
    }
    if ($targets -ne 1 -or $environment.Count -gt 32) { return $null }
    return [ordered]@{ schema_version = 1; target = $target; environment = @($environment.ToArray()) }
}

function Get-NativeShimCacheState {
    param([Parameter(Mandatory)][string]$Directory)
    $launcher = Join-Path $Directory '.native-shim-launcher.exe'
    $receipt = Join-Path $Directory '.native-shim-launcher.json'
    Assert-NativeShimPath -Path $launcher
    Assert-NativeShimPath -Path $receipt
    $launcherItem = Get-Item -LiteralPath $launcher -ErrorAction SilentlyContinue
    $receiptItem = Get-Item -LiteralPath $receipt -ErrorAction SilentlyContinue
    if ($null -eq $launcherItem -and $null -eq $receiptItem) { return $null }
    if ($null -eq $launcherItem -or $null -eq $receiptItem) { throw 'Refusing an incomplete/orphan native launcher cache.' }
    if ($launcherItem.PSIsContainer -or $receiptItem.PSIsContainer) { throw 'Native launcher cache artifacts must be ordinary files.' }
    $record = Get-Content -LiteralPath $receipt -Raw -Encoding UTF8 | ConvertFrom-Json
    $names = @($record.PSObject.Properties.Name)
    if ($names.Count -ne 3 -or $names -notcontains 'source_sha256' -or $names -notcontains 'launcher_sha256' -or
        $names -notcontains 'previous_launcher_sha256' -or $record.source_sha256 -isnot [string] -or
        $record.source_sha256 -notmatch '^[0-9a-fA-F]{64}$' -or $record.launcher_sha256 -isnot [string] -or
        $record.launcher_sha256 -notmatch '^[0-9a-fA-F]{64}$' -or $record.previous_launcher_sha256 -isnot [array] -or
        $record.previous_launcher_sha256.Count -gt 16) { throw 'Native launcher ownership receipt is malformed.' }
    foreach ($digest in $record.previous_launcher_sha256) {
        if ($digest -isnot [string] -or $digest -notmatch '^[0-9a-fA-F]{64}$') { throw 'Native launcher ownership history is malformed.' }
    }
    if ($record.launcher_sha256 -ne (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash) {
        throw 'Native launcher cache bytes differ from its ownership receipt.'
    }
    [pscustomobject]@{
        Launcher = $launcher
        Receipt = $receipt
        Record = $record
        KnownHashes = @([string]$record.launcher_sha256) + @($record.previous_launcher_sha256)
    }
}

function Get-NativeShimCompanionState {
    # Ownership needs a complete pair, valid metadata and a verified launcher
    # digest. Neither the basename nor a sidecar present alone establishes it.
    param([Parameter(Mandatory)][string]$Wrapper)
    Assert-NativeShimPath -Path $Wrapper
    $exe = [IO.Path]::ChangeExtension($Wrapper, '.exe')
    $metadata = [IO.Path]::ChangeExtension($Wrapper, '.shim.json')
    Assert-NativeShimPath -Path $exe
    Assert-NativeShimPath -Path $metadata
    $exeItem = Get-Item -LiteralPath $exe -ErrorAction SilentlyContinue
    $metadataItem = Get-Item -LiteralPath $metadata -ErrorAction SilentlyContinue
    if ($null -eq $exeItem -and $null -eq $metadataItem) { return $null }
    if ($null -eq $exeItem -or $null -eq $metadataItem) {
        throw 'Refusing an incomplete/orphan companion pair, executable or metadata not owned by the shim publisher.'
    }
    if ($exeItem.PSIsContainer -or $metadataItem.PSIsContainer) { throw 'Native companion artifacts must be ordinary files.' }
    $cache = Get-NativeShimCacheState -Directory (Split-Path -Parent $Wrapper)
    if ($null -eq $cache -or $cache.KnownHashes -notcontains (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash) {
        throw 'Refusing executable bytes not owned by the shim publisher.'
    }
    $document = Get-Content -LiteralPath $metadata -Raw -Encoding UTF8 | ConvertFrom-Json
    $names = @($document.PSObject.Properties.Name)
    if ($names.Count -ne 3 -or $names -notcontains 'schema_version' -or $names -notcontains 'target' -or
        $names -notcontains 'environment' -or ($document.schema_version -isnot [int] -and $document.schema_version -isnot [long]) -or
        $document.schema_version -ne 1 -or $document.target -isnot [string] -or $document.environment -isnot [array]) {
        throw 'Native companion metadata is malformed, refusing to infer ownership.'
    }
    $prologue = @()
    foreach ($entry in $document.environment) {
        $fields = @($entry.PSObject.Properties.Name)
        if ($fields.Count -ne 2 -or $fields -notcontains 'name' -or $fields -notcontains 'value' -or
            $entry.name -isnot [string] -or $entry.value -isnot [string]) { throw 'Native companion environment metadata is malformed.' }
        $prologue += ('set "' + $entry.name + '=' + $entry.value + '"')
    }
    $body = New-ShimBody -Target $document.target -Prologue $prologue
    if ($null -eq (Get-NativeShimConfiguration -Lines ($body -split "\r\n"))) { throw 'Native companion metadata has an unsupported contract.' }
    [pscustomobject]@{ Executable = $exe; Metadata = $metadata }
}

function Remove-OwnedNativeShim {
    param([Parameter(Mandatory)][string]$Wrapper)
    $owned = Get-NativeShimCompanionState -Wrapper $Wrapper
    if ($null -eq $owned) { return $false }
    # Only these two verified leaf files, never a directory or recursive removal.
    # Delete the executable first so a partial failure cannot shadow the CMD.
    Remove-Item -LiteralPath $owned.Executable -Force
    Remove-Item -LiteralPath $owned.Metadata -Force
    return $true
}

function Prepare-NativeShimWrite {
    # Called before each CMD writer. Refuse unknown/incomplete artifacts before
    # changing CMD bytes; remove owned obsolete companions before a batch switch.
    param([Parameter(Mandatory)][string]$Wrapper, [Parameter(Mandatory)][string]$Body)
    $owned = Get-NativeShimCompanionState -Wrapper $Wrapper
    $configuration = Get-NativeShimConfiguration -Lines ($Body -split "\r\n")
    if ($null -eq $configuration) {
        if ($null -ne $owned) { [void](Remove-OwnedNativeShim -Wrapper $Wrapper) }
    } else {
        [void](Get-NativeShimCacheState -Directory (Split-Path -Parent $Wrapper))
    }
}

function Get-NativeShimLauncher {
    param([Parameter(Mandatory)][string]$Directory)
    Assert-NativeShimPath -Path $Directory
    $source = Join-Path $PSScriptRoot 'NativeShim.cs'
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $launcher = Join-Path $Directory '.native-shim-launcher.exe'
    $receipt = Join-Path $Directory '.native-shim-launcher.json'
    $previous = @()
    $cache = Get-NativeShimCacheState -Directory $Directory
    if ($null -ne $cache) {
        $previous = @($cache.KnownHashes)
        if ($cache.Record.source_sha256 -eq $sourceHash) { return $launcher }
    }
    # Windows PowerShell 5.1 already requires this Windows .NET Framework.
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'Windows .NET Framework C# compiler is missing.' }
    $temporary = Join-Path $Directory ('.native-shim-' + [guid]::NewGuid().ToString('N') + '.exe')
    try {
        $output = & $compiler /nologo /target:exe /optimize+ /platform:anycpu /reference:System.Web.Extensions.dll /reference:System.Runtime.Serialization.dll ("/out:" + $temporary) $source
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporary -PathType Leaf)) {
            throw "Native shim compilation failed: $($output -join ' ')"
        }
        Move-Item -LiteralPath $temporary -Destination $launcher -Force
        $record = [ordered]@{
            source_sha256 = $sourceHash
            launcher_sha256 = (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash
            previous_launcher_sha256 = @($previous | Select-Object -Unique -First 16)
        }
        [IO.File]::WriteAllText($receipt, ($record | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    return $launcher
}

function Install-NativeShim {
    <#
        Publish native companions for understood EXE contracts, or remove a
        proven owned pair when the wrapper changes to an explicit batch contract.
        No target selection, package installation or PATH changes.
    #>
    param([Parameter(Mandatory)][string]$Wrapper)
    Assert-NativeShimPath -Path $Wrapper
    $lines = @(Get-Content -LiteralPath $Wrapper -Encoding UTF8)
    $configuration = Get-NativeShimConfiguration -Lines $lines
    if (-not $configuration) {
        [void](Remove-OwnedNativeShim -Wrapper $Wrapper)
        return $false
    }
    # Refuse incomplete pairs before a sidecar or launcher can be overwritten.
    [void](Get-NativeShimCompanionState -Wrapper $Wrapper)
    $directory = Split-Path -Parent $Wrapper
    $exe = [IO.Path]::ChangeExtension($Wrapper, '.exe')
    $metadata = [IO.Path]::ChangeExtension($Wrapper, '.shim.json')
    $target = [IO.Path]::GetFullPath([string]$configuration.target)
    Assert-NativeShimPath -Path $target
    $targetMetadata = [IO.Path]::ChangeExtension($target, '.shim.json')
    Assert-NativeShimPath -Path $targetMetadata
    if ($target -ieq [IO.Path]::GetFullPath($exe) -or (Test-Path -LiteralPath $targetMetadata)) {
        throw 'Native shim chains and self targets are refused.'
    }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Native shim target is missing: $target" }
    $launcher = Get-NativeShimLauncher -Directory $directory
    $temporary = $metadata + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($configuration | ConvertTo-Json -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $metadata -Force
        Copy-Item -LiteralPath $launcher -Destination $exe -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    return $true
}

function Test-NativeShim {
    # Return a concrete failure string, or null for a healthy/explicit batch-only shim.
    param([Parameter(Mandatory)][string]$Wrapper)
    Assert-NativeShimPath -Path $Wrapper
    $expected = Get-NativeShimConfiguration -Lines @(Get-Content -LiteralPath $Wrapper -Encoding UTF8)
    if (-not $expected) {
        $batchExe = [IO.Path]::ChangeExtension($Wrapper, '.exe')
        $batchMetadata = [IO.Path]::ChangeExtension($Wrapper, '.shim.json')
        Assert-NativeShimPath -Path $batchExe
        Assert-NativeShimPath -Path $batchMetadata
        if ((Test-Path -LiteralPath $batchExe) -or (Test-Path -LiteralPath $batchMetadata)) {
            return 'an unsupported batch contract is still shadowed by a companion artifact'
        }
        return $null
    }
    $exe = [IO.Path]::ChangeExtension($Wrapper, '.exe')
    $metadata = [IO.Path]::ChangeExtension($Wrapper, '.shim.json')
    $receipt = Join-Path (Split-Path -Parent $Wrapper) '.native-shim-launcher.json'
    Assert-NativeShimPath -Path $exe
    Assert-NativeShimPath -Path $metadata
    Assert-NativeShimPath -Path $receipt
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return 'native EXE companion is missing' }
    if (-not (Test-Path -LiteralPath $metadata -PathType Leaf)) { return 'native shim metadata is missing' }
    if (-not (Test-Path -LiteralPath $receipt -PathType Leaf)) { return 'native launcher receipt is missing' }
    try {
        $actual = Get-Content -LiteralPath $metadata -Raw -Encoding UTF8 | ConvertFrom-Json
        $names = @($actual.PSObject.Properties.Name)
        if ($names.Count -ne 3 -or $names -notcontains 'schema_version' -or $names -notcontains 'target' -or $names -notcontains 'environment' -or
            ($actual.schema_version -isnot [int] -and $actual.schema_version -isnot [long]) -or $actual.schema_version -ne 1 -or $actual.target -isnot [string] -or
            $actual.target -cne $expected.target -or $actual.environment -isnot [array] -or
            @($actual.environment).Count -ne @($expected.environment).Count) { return 'native shim metadata differs from its batch contract' }
        for ($i = 0; $i -lt @($expected.environment).Count; $i++) {
            $entry = $actual.environment[$i]
            if (@($entry.PSObject.Properties.Name).Count -ne 2 -or $entry.name -cne $expected.environment[$i].name -or
                $entry.value -cne $expected.environment[$i].value) { return 'native shim environment differs from its batch contract' }
        }
        Assert-NativeShimPath -Path $actual.target
        if (-not (Test-Path -LiteralPath $actual.target -PathType Leaf)) { return 'native shim target is missing' }
        if ([IO.Path]::GetFullPath($actual.target) -ieq [IO.Path]::GetFullPath($exe) -or
            (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($actual.target, '.shim.json')))) { return 'native shim targets itself or another shim' }
        $record = Get-Content -LiteralPath $receipt -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($record.source_sha256 -ne (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'NativeShim.cs') -Algorithm SHA256).Hash -or
            $record.launcher_sha256 -ne (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash) { return 'native shim executable or source receipt is stale' }
    } catch { return "native shim validation failed: $($_.Exception.Message)" }
    return $null
}

function Assert-NativeShimPath {
    # Reuse the source policy without adding an eager read or changing bootstrap
    # scope. Walk ancestors from the root, rejecting links before entering them.
    param([Parameter(Mandatory)][string]$Path)
    . (Join-Path $PSScriptRoot 'SourceFiles.ps1')
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-SUSourcePath -Path $full)) { throw 'Native shim path has a protected component.' }
    $cursor = [IO.Path]::GetPathRoot($full)
    foreach ($part in $full.Substring($cursor.Length).Split([char]'\')) {
        if (-not $part) { continue }
        $cursor = Join-Path $cursor $part
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { break }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Native shim path contains a link or junction.' }
    }
}
