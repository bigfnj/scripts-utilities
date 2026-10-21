#Requires -Version 5.1
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'SUTestGuard.ps1')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib\ShimFormat.ps1')
$script:Pass = 0
$script:Fail = 0
function It {
    param([string]$Name, [scriptblock]$Body)
    try {
        if (& $Body) { $script:Pass++; Write-Host "  OK $Name" }
        else { $script:Fail++; Write-Host "  FAIL $Name" }
    } catch { $script:Fail++; Write-Host "  FAIL $Name : $($_.Exception.Message)" }
}
function Invoke-Probe {
    param([string]$Exe, [string]$Raw, [string]$InputText = 'stdin payload', [string]$Directory = $script:fixture)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Exe
    $start.Arguments = $Raw
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WorkingDirectory = $Directory
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = [Diagnostics.Process]::Start($start)
    try {
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        $output = $process.StandardOutput.ReadToEndAsync()
        $errorText = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Native shim subprocess timed out.' }
        [pscustomobject]@{ Output = $output.Result; Error = $errorText.Result; ExitCode = $process.ExitCode }
    } finally { $process.Dispose() }
}
function Read-Probe {
    param($Result)
    $Result.Output.Trim() | ConvertFrom-Json
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('native-shim-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$bin = Join-Path $fixture 'bin space'
New-Item -ItemType Directory -Path $bin -Force | Out-Null
$target = Join-Path $fixture 'probe target.exe'
$wrapper = Join-Path $bin 'su-probe.cmd'
$native = [IO.Path]::ChangeExtension($wrapper, '.exe')
$metadata = [IO.Path]::ChangeExtension($wrapper, '.shim.json')
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$built = & $compiler /nologo /target:exe /reference:System.Web.Extensions.dll ("/out:" + $target) (Join-Path $PSScriptRoot 'NativeShimProbe.cs')
if ($LASTEXITCODE -ne 0) { throw "Probe compilation failed: $($built -join ' ')" }
Set-Content -LiteralPath $wrapper -Value (New-ShimBody -Target $target) -Encoding ASCII -NoNewline
try {
    It 'publishes a native companion and independently verifies its source binary target and environment' {
        (Install-NativeShim -Wrapper $wrapper) -and ($null -eq (Test-NativeShim -Wrapper $wrapper))
    }
    It 'preserves the exact raw argument tail and real argv including empty quoted Unicode and trailing backslashes' {
        $raw = '--exit=37 ">" "<" "&" "|" "a\"b" "" "C:\trail\\" " space " "終わり"'
        $direct = Invoke-Probe -Exe $target -Raw $raw
        $wrapped = Invoke-Probe -Exe $native -Raw $raw
        $a = Read-Probe $direct
        $b = Read-Probe $wrapped
        $expected = @('--exit=37', '>', '<', '&', '|', 'a"b', '', 'C:\trail\', ' space ', '終わり')
        if (@(Compare-Object $expected $b.args -SyncWindow 0).Count -ne 0) { return $false }
        $direct.ExitCode -eq 37 -and $wrapped.ExitCode -eq 37 -and
            $a.raw.Substring($a.raw.IndexOf(' --exit=')) -ceq $b.raw.Substring($b.raw.IndexOf(' --exit='))
    }
    It 'inherits real redirected stdin stdout stderr working directory and exit codes' {
        $result = Invoke-Probe -Exe $native -Raw '--exit=-2147483647' -InputText "line one
line two"
        $capture = Read-Probe $result
        $result.ExitCode -eq -2147483647 -and $result.Error.Trim() -eq 'fixture stderr' -and
            $capture.stdin -ceq "line one
line two" -and $capture.cwd -ceq $fixture
    }
    It 'translates ordered quoted SET assignments locally including inherited variable expansion' {
        $saved = $env:SU_SHIM_FIXTURE
        try {
            $env:SU_SHIM_FIXTURE = 'outer'
            $prologue = @('setlocal', 'set "SU_SHIM_FIXTURE=inside"', 'set "SU_SHIM_NESTED=%SU_SHIM_FIXTURE%/tail"', 'set "PATH=C:\shim-fixture;%PATH%"')
            Set-Content -LiteralPath $wrapper -Value (New-ShimBody -Target $target -Prologue $prologue) -Encoding ASCII -NoNewline
            [void](Install-NativeShim -Wrapper $wrapper)
            $capture = Read-Probe (Invoke-Probe -Exe $native -Raw '')
            $capture.fixture -eq 'inside' -and $capture.nested -eq 'inside/tail' -and
                $capture.path.StartsWith('C:\shim-fixture;') -and $env:SU_SHIM_FIXTURE -eq 'outer' -and
                ($null -eq (Test-NativeShim -Wrapper $wrapper))
        } finally {
            [Environment]::SetEnvironmentVariable('SU_SHIM_FIXTURE', $saved, 'Process')
            Set-Content -LiteralPath $wrapper -Value (New-ShimBody -Target $target) -Encoding ASCII -NoNewline
            [void](Install-NativeShim -Wrapper $wrapper)
        }
    }
    It 'matches real CMD SET expansion for undefined variables and rejects unsupported CMD substitutions' {
        $saved = $env:SU_SHIM_UNDEFINED
        try {
            Remove-Item Env:\SU_SHIM_UNDEFINED -ErrorAction SilentlyContinue
            $prologue = @('setlocal', 'set "SU_SHIM_FIXTURE=before%SU_SHIM_UNDEFINED%after"', 'set "SU_SHIM_NESTED=%SU_SHIM_FIXTURE%/tail"')
            Set-Content -LiteralPath $wrapper -Value (New-ShimBody -Target $target -Prologue $prologue) -Encoding ASCII -NoNewline
            [void](Install-NativeShim -Wrapper $wrapper)
            $cmdCapture = Read-Probe (Invoke-Probe -Exe (Join-Path $env:WINDIR 'System32\cmd.exe') -Raw ('/d /s /c ""' + $wrapper + '""'))
            $nativeCapture = Read-Probe (Invoke-Probe -Exe $native -Raw '')
            if ($nativeCapture.fixture -cne 'beforeafter' -or $nativeCapture.fixture -cne $cmdCapture.fixture -or
                $nativeCapture.nested -cne $cmdCapture.nested) { return $false }
            foreach ($value in @('%PATH:~0,3%', '%PATH:old=new%', '%1', '%%', '%*', '%ERRORLEVEL%', '%CD%', '%RANDOM%', '!PATH!')) {
                $lines = (New-ShimBody -Target $target -Prologue @('set "X=' + $value + '"')) -split "\r\n"
                if ($null -ne (Get-NativeShimConfiguration -Lines $lines)) { return $false }
            }
            $true
        } finally {
            [Environment]::SetEnvironmentVariable('SU_SHIM_UNDEFINED', $saved, 'Process')
            Set-Content -LiteralPath $wrapper -Value (New-ShimBody -Target $target) -Encoding ASCII -NoNewline
            [void](Install-NativeShim -Wrapper $wrapper)
        }
    }
    It 'rejects protected wrapper and ancestor names before any target lookup without creating protected fixtures' {
        foreach ($path in @(
            (Join-Path $fixture 'privatekey-fixture.cmd'),
            (Join-Path $fixture 'synthetic.key\tool.cmd'),
            (Join-Path $fixture '.env.fixture\tool.cmd')
        )) {
            $refused = $false
            try { Assert-NativeShimPath -Path $path }
            catch { $refused = $_.Exception.Message -match 'protected component' }
            if (-not $refused) { return $false }
        }
        $null -eq (Get-NativeShimConfiguration -Lines @()) -and
            $null -ne (Get-NativeShimConfiguration -Lines @('', '@echo off', '', ('"' + $target + '" %*'), ''))
    }
    It 'PowerShell 5.1 and installed PowerShell 7 resolve bare names to EXE and preserve direct-call arguments' {
        $driver = Join-Path $fixture 'powershell-driver.ps1'
        $driverText = @'
$ErrorActionPreference = 'Stop'
if (Get-Variable PSNativeCommandArgumentPassing -ErrorAction SilentlyContinue) { $PSNativeCommandArgumentPassing = 'Standard' }
$env:PATH = $env:SU_SHIM_TEST_BIN + ';' + $env:PATH
$vector = @('--exit=23', 'pf->numpos', '<literal', 'a&b', 'left|right', 'a"b', '', 'C:\with space\', ' final ', '終わり')
$target = $env:SU_SHIM_TEST_TARGET
$direct = $null | & $target @vector
$directCode = $LASTEXITCODE
$resolved = (Get-Command su-probe).Source
$wrapped = $null | su-probe @vector
$wrappedCode = $LASTEXITCODE
[ordered]@{ direct = $direct; wrapped = $wrapped; direct_code = $directCode; wrapped_code = $wrappedCode; resolved = $resolved; version = $PSVersionTable.PSVersion.Major } | ConvertTo-Json -Compress
'@
        [IO.File]::WriteAllText($driver, $driverText, (New-Object Text.UTF8Encoding($true)))
        $env:SU_SHIM_TEST_BIN = $bin
        $env:SU_SHIM_TEST_TARGET = $target
        try {
            $shells = @((Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'))
            $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
            if ($pwsh) { $shells += $pwsh.Source }
            foreach ($shell in $shells) {
                $result = Invoke-Probe -Exe $shell -Raw ('-NoProfile -ExecutionPolicy Bypass -File "' + $driver + '"') -InputText ''
                if ($result.ExitCode -ne 0) { throw $result.Error }
                $capture = Read-Probe $result
                if ($capture.resolved -ine $native -or $capture.direct_code -ne 23 -or $capture.wrapped_code -ne 23) { return $false }
                $direct = $capture.direct | ConvertFrom-Json
                $wrapped = $capture.wrapped | ConvertFrom-Json
                if (@(Compare-Object $direct.args $wrapped.args -SyncWindow 0).Count -ne 0) { return $false }
                if ($wrapped.args[1] -cne 'pf->numpos' -or $wrapped.args[4] -cne 'left|right') { return $false }
                if ($capture.version -ge 7 -and ($wrapped.args[6] -cne '' -or $wrapped.args[5] -cne 'a"b')) { return $false }
            }
            $true
        } finally {
            Remove-Item Env:\SU_SHIM_TEST_BIN -ErrorAction SilentlyContinue
            Remove-Item Env:\SU_SHIM_TEST_TARGET -ErrorAction SilentlyContinue
        }
    }
    It 'forwards actual Ctrl-C and Ctrl-Break to the child while returning its exit status' {
        $consoleTarget = Join-Path $fixture 'console target.exe'
        $compilerOutput = & $compiler /nologo /target:exe ("/out:" + $consoleTarget) (Join-Path $PSScriptRoot 'NativeShimConsoleProbe.cs')
        if ($LASTEXITCODE -ne 0) { throw ($compilerOutput -join ' ') }
        $consoleWrapper = Join-Path $bin 'console-probe.cmd'
        Set-Content -LiteralPath $consoleWrapper -Value (New-ShimBody -Target $consoleTarget) -Encoding ASCII -NoNewline
        [void](Install-NativeShim -Wrapper $consoleWrapper)
        $consoleNative = [IO.Path]::ChangeExtension($consoleWrapper, '.exe')
        foreach ($kind in @(0, 1)) {
            $marker = Join-Path $fixture ("console-ready-" + $kind)
            $result = Invoke-Probe -Exe $consoleTarget -Raw ('"' + $consoleNative + '" "' + $marker + '" ' + $kind) -InputText ''
            if ($result.ExitCode -ne 0) {
                if (Test-Path -LiteralPath ($marker + '.error')) { Write-Host ([IO.File]::ReadAllText($marker + '.error')) }
                return $false
            }
        }
        $true
    }
    It 'builder and planner production writes both publish the native companion without changing the CMD bytes' {
        . (Join-Path $repoRoot 'lib\ShimPlan.ps1')
        $builderPath = Join-Path $repoRoot 'scripts\build-devtoolbox.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($builderPath, [ref]$tokens, [ref]$errors)
        $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-CmdWrapper' }, $true)
        if (-not $function -or $errors.Count) { return $false }
        $rootPath = Join-Path $fixture 'builder'
        $builderBin = Join-Path $rootPath 'native\bin'
        New-Item -ItemType Directory -Path $builderBin -Force | Out-Null
        $definition = [scriptblock]::Create($function.Extent.Text)
        $published = & {
            param($Definition, $Root, $Target)
            $DryRun = $false
            . $Definition
            New-CmdWrapper -Name 'builder-probe' -Target $Target
        } $definition $rootPath $target
        $builderWrapper = Join-Path $builderBin 'builder-probe.cmd'
        if (-not $published -or $null -ne (Test-NativeShim -Wrapper $builderWrapper)) { return $false }
        if ([IO.File]::ReadAllText($builderWrapper) -cne (New-ShimBody -Target $target)) { return $false }
        $plannedWrapper = Join-Path $bin 'planner-probe.cmd'
        $plan = @{ Write = @([pscustomobject]@{ Name = 'planner-probe'; Target = $target; Wrapper = $plannedWrapper; Refresh = $false }) }
        $written = Invoke-ShimWrite -Plan $plan -NativeBin $bin
        @($written.Written).Count -eq 1 -and @($written.Refused).Count -eq 0 -and
            ($null -eq (Test-NativeShim -Wrapper $plannedWrapper)) -and
            [IO.File]::ReadAllText($plannedWrapper) -ceq (New-ShimBody -Target $target)
    }
    It 'does not create native companions for batch targets or unrecognized batch control flow' {
        foreach ($lines in @(
            @('@echo off', '"C:\vendor\app.cmd" %*'),
            @('@echo off', 'echo initialization', ('"' + $target + '" %*')),
            @(('"' + $target + '" %*')),
            @('@echo off', ('"' + $target + '" %*'), 'set "AFTER=target"'),
            @('@echo off', 'set "X=1" & echo extra', ('"' + $target + '" %*')),
            @('@echo off', '"%DYNAMIC_EXE%" %*')
        )) {
            if ($null -ne (Get-NativeShimConfiguration -Lines $lines)) { return $false }
        }
        $true
    }
    It 'refuses publisher overwrite of an executable without native shim ownership metadata' {
        $other = Join-Path $bin 'unowned.cmd'
        Set-Content -LiteralPath $other -Value (New-ShimBody -Target $target) -Encoding ASCII -NoNewline
        Copy-Item -LiteralPath $target -Destination ([IO.Path]::ChangeExtension($other, '.exe'))
        $refused = $false
        try { Install-NativeShim -Wrapper $other | Out-Null } catch { $refused = $_.Exception.Message -match 'not owned' }
        if (-not $refused) { return $false }
        $forged = [IO.Path]::ChangeExtension($other, '.shim.json')
        [IO.File]::WriteAllText($forged, '{"schema_version":1,"target":"C:\\absent.exe","environment":[]}')
        try { Install-NativeShim -Wrapper $other; $false } catch { $_.Exception.Message -match 'bytes not owned' }
    }
    It 'rejects missing malformed non-EXE and self-target metadata without launching a target' {
        $original = [IO.File]::ReadAllText($metadata)
        try {
            foreach ($body in @(
                '{}',
                '{"schema_version":1,"schema_version":1,"target":"C:\\absent.exe","environment":[]}',
                '{"schema_version":1,"target":"C:\\absent.exe","environment":[{"name":"X","name":"Y","value":"value"}]}',
                '{"schema_version":true,"target":"C:\\absent.exe","environment":[]}',
                '{"schema_version":1,"target":"C:\\absent.cmd","environment":[]}',
                '{"schema_version":1,"target":"relative.exe","environment":[]}',
                (([ordered]@{ schema_version = 1; target = $native; environment = @() }) | ConvertTo-Json -Compress),
                (([ordered]@{ schema_version = 1; target = (Join-Path $fixture 'absent.exe'); environment = @() }) | ConvertTo-Json -Compress)
            )) {
                [IO.File]::WriteAllText($metadata, $body, (New-Object Text.UTF8Encoding($false)))
                $result = Invoke-Probe -Exe $native -Raw ''
                if ($result.ExitCode -ne 126 -or $result.Output -ne '' -or $result.Error -notmatch '^native shim:') { return $false }
                if ($body -match '"schema_version":1,"schema_version"|"name":"X","name":"Y"') {
                    if ($result.Error -notmatch 'Duplicate native shim metadata field') { return $false }
                }
            }
            Remove-Item -LiteralPath $metadata -Force
            $result = Invoke-Probe -Exe $native -Raw ''
            $result.ExitCode -eq 126 -and $result.Output -eq ''
        } finally { [IO.File]::WriteAllText($metadata, $original, (New-Object Text.UTF8Encoding($false))) }
    }
    It 'detects stale companion bytes and mismatched native target metadata independently' {
        $original = [IO.File]::ReadAllText($metadata)
        try {
            $changed = $original.Replace('probe target.exe', 'another target.exe')
            [IO.File]::WriteAllText($metadata, $changed, (New-Object Text.UTF8Encoding($false)))
            if ((Test-NativeShim -Wrapper $wrapper) -notmatch 'differs') { return $false }
            [IO.File]::WriteAllText($metadata, $original, (New-Object Text.UTF8Encoding($false)))
            [IO.File]::AppendAllText($native, 'changed')
            if ((Test-NativeShim -Wrapper $wrapper) -notmatch 'stale') { return $false }
            $refused = $false
            try { Install-NativeShim -Wrapper $wrapper | Out-Null }
            catch { $refused = $_.Exception.Message -match 'bytes not owned' }
            if (-not $refused) { return $false }
            Remove-Item -LiteralPath $native -Force
            [void](Install-NativeShim -Wrapper $wrapper)
            $null -eq (Test-NativeShim -Wrapper $wrapper)
        } finally { [IO.File]::WriteAllText($metadata, $original, (New-Object Text.UTF8Encoding($false))) }
    }
} finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
Assert-SUSuiteFloor -SuiteFile $PSCommandPath -Ran ($script:Pass + $script:Fail)
Show-SUGuardSummary
Write-Host "$script:Pass passed, $script:Fail failed"
if ($script:Fail -gt 0) { exit 1 }

exit 0
