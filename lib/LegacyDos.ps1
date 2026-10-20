# Pure selection and result guards for the explicit optional DOS tool workflow.
function Test-SULegacyHostProjection {
    param([Parameter(Mandatory)][string]$Root,
        [scriptblock]$Probe = { param($Path) Test-HostPathProjection -Path $Path })
    # Measure the selected root even when the caller has a different CODEX_TOOLBOX.
    $Probe.Invoke((Join-Path $Root 'python\.venv\Scripts\python.exe'))
}

function Get-SUPinnedGhidraSelection {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidatePattern('^Ghidra_[0-9]+\.[0-9]+(?:\.[0-9]+)?_build$')][string]$ReleaseTag,
        [Parameter(Mandatory)][int]$JdkMajor,
        [scriptblock]$FileExists = { param($Path) Test-Path -LiteralPath $Path -PathType Leaf },
        [scriptblock]$ListNative = { param($Path) Get-ChildItem -LiteralPath $Path -Directory -ErrorAction Stop }
    )
    $native = Join-Path $Root 'native'
    $folder = $ReleaseTag -replace '^Ghidra_', 'ghidra_' -replace '_build$', '_PUBLIC'
    $install = Join-Path $native $folder
    foreach ($required in @('ghidraRun.bat', 'support\analyzeHeadless.bat', 'Ghidra\application.properties', 'Ghidra\Features\Decompiler\os\win_x86_64\decompile.exe')) {
        if (-not (& $FileExists (Join-Path $install $required))) {
            throw "Pinned Ghidra is incomplete: $required"
        }
    }
    $jdk = $ListNative.Invoke($native) |
        Where-Object {
            $_.Name -match ('^jdk-' + $JdkMajor + '(?:[._+-]|$)') -and
            (& $FileExists (Join-Path $_.FullName 'bin\java.exe')) -and
            (& $FileExists (Join-Path $_.FullName 'bin\javac.exe'))
        } | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $jdk) { throw "No complete portable JDK $JdkMajor exists in the selected toolbox." }
    [pscustomobject]@{ InstallPath = $install; JdkPath = $jdk.FullName }
}

function Get-SUWatcomShimPlan {
    param([Parameter(Mandatory)][string]$InstallRoot,
        [scriptblock]$FileExists = { param($Path) Test-Path -LiteralPath $Path -PathType Leaf })
    $plan = @()
    foreach ($name in @('wcl386', 'wcc386', 'wlink', 'wdis', 'wmake', 'wasm')) {
        $target = Join-Path $InstallRoot ("binnt64\" + $name + '.exe')
        if (-not (& $FileExists $target)) {
            throw "Watcom executable missing before wrapper registration: $target"
        }
        $plan += [pscustomobject]@{ Name = $name; Target = $target }
    }
    # No entries escape until every target has been validated.
    $plan
}

function Test-SURequiredPythonResult {
    param([int]$ExitCode, [string[]]$Output, [int]$MinimumTests)
    if ($MinimumTests -lt 1) { throw 'A positive required-test floor is mandatory.' }
    if ($ExitCode -ne 0) { return $false }
    $text = $Output -join [Environment]::NewLine
    $counts = [regex]::Matches($text, '(?m)^Ran ([0-9]+) tests? in [^\r\n]+\r?$')
    if ($counts.Count -ne 1 -or [int]$counts[0].Groups[1].Value -lt $MinimumTests) { return $false }
    # unittest emits plain OK only when there were no skips/expected failures.
    if ($text -notmatch '(?m)^OK\s*$' -or $text -match '(?im)\b(skipped|expected failures|unexpected successes)\b') { return $false }
    return $true
}
