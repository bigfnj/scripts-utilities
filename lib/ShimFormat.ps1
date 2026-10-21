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

function Get-NativeShimLauncher {
    param([Parameter(Mandatory)][string]$Directory)
    Assert-NativeShimPath -Path $Directory
    $source = Join-Path $PSScriptRoot 'NativeShim.cs'
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $launcher = Join-Path $Directory '.native-shim-launcher.exe'
    $receipt = Join-Path $Directory '.native-shim-launcher.json'
    Assert-NativeShimPath -Path $launcher
    Assert-NativeShimPath -Path $receipt
    $previous = @()
    if ((Test-Path -LiteralPath $launcher -PathType Leaf) -and -not (Test-Path -LiteralPath $receipt -PathType Leaf)) {
        throw 'Refusing to replace an unowned native launcher cache.'
    }
    if ((Test-Path -LiteralPath $launcher -PathType Leaf) -and (Test-Path -LiteralPath $receipt -PathType Leaf)) {
        $old = Get-Content -LiteralPath $receipt -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($old.launcher_sha256 -ne (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash) { throw 'Native launcher cache bytes differ from its ownership receipt.' }
        $previous = @([string]$old.launcher_sha256)
        if (@($old.PSObject.Properties.Name) -contains 'previous_launcher_sha256') { $previous += @($old.previous_launcher_sha256) }
        if ($old.source_sha256 -eq $sourceHash) { return $launcher }
    }
    # Windows PowerShell 5.1 already requires this Windows .NET Framework. No SDK,
    # package download, global compiler install, PATH or Python environment change.
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
        Publish a companion only for an understood EXE-backed .cmd. The .cmd stays
        byte-identical for explicit cmd/POSIX consumers. Bare PowerShell selects
        the adjacent .exe and never sends arguments through the cmd parser.
        This function does not install packages or alter target selection/PATH.
    #>
    param([Parameter(Mandatory)][string]$Wrapper)
    Assert-NativeShimPath -Path $Wrapper
    $lines = @(Get-Content -LiteralPath $Wrapper -Encoding UTF8)
    $configuration = Get-NativeShimConfiguration -Lines $lines
    if (-not $configuration) { return $false }
    $directory = Split-Path -Parent $Wrapper
    $exe = [IO.Path]::ChangeExtension($Wrapper, '.exe')
    $metadata = [IO.Path]::ChangeExtension($Wrapper, '.shim.json')
    Assert-NativeShimPath -Path $exe
    Assert-NativeShimPath -Path $metadata
    $target = [IO.Path]::GetFullPath([string]$configuration.target)
    Assert-NativeShimPath -Path $target
    if ($target -ieq [IO.Path]::GetFullPath($exe) -or
        (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($target, '.shim.json')))) { throw 'Native shim chains and self targets are refused.' }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Native shim target is missing: $target" }
    if (Test-Path -LiteralPath $exe) {
        $cacheReceipt = Join-Path $directory '.native-shim-launcher.json'
        Assert-NativeShimPath -Path $cacheReceipt
        if (-not (Test-Path -LiteralPath $metadata -PathType Leaf) -or -not (Test-Path -LiteralPath $cacheReceipt -PathType Leaf)) {
            throw "Refusing to overwrite an executable not owned by the shim publisher: $exe"
        }
        $owned = Get-Content -LiteralPath $cacheReceipt -Raw -Encoding UTF8 | ConvertFrom-Json
        $knownHashes = @([string]$owned.launcher_sha256)
        if (@($owned.PSObject.Properties.Name) -contains 'previous_launcher_sha256') { $knownHashes += @($owned.previous_launcher_sha256) }
        if ($knownHashes -notcontains (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash) {
            throw "Refusing to overwrite executable bytes not owned by the shim publisher: $exe"
        }
    }
    $launcher = Get-NativeShimLauncher -Directory $directory
    # Metadata is published first. A missing companion cannot be selected and an
    # already-published companion sees the new complete JSON in one rename.
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
        if (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($Wrapper, '.shim.json'))) { return 'an unsupported batch contract still has native companion metadata' }
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
