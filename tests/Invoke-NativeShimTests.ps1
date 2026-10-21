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
    # ProcessStartInfo bypasses PS7's native-command compatibility adjustment
    # for powershell.exe. Keep this no-profile 5.1 fixture on inbox 5.1 modules,
    # so a nested legacy shell does not attempt to import PS7's Utility module.
    if ([IO.Path]::GetFileName($Exe) -ieq 'powershell.exe') {
        $start.EnvironmentVariables['PSModulePath'] = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\Modules'
    }
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
    It 'removes owned EXE companions when the target changes to batch and bare invocation uses the new target' {
        $transition = Join-Path $bin 'transition-probe.cmd'
        $transitionExe = [IO.Path]::ChangeExtension($transition, '.exe')
        $transitionMetadata = [IO.Path]::ChangeExtension($transition, '.shim.json')
        Set-Content -LiteralPath $transition -Value (New-ShimBody -Target $target) -Encoding ASCII -NoNewline
        [void](Install-NativeShim -Wrapper $transition)
        $batchTarget = Join-Path $fixture 'transition target.cmd'
        [IO.File]::WriteAllLines($batchTarget, @('@echo off', 'echo transition batch target'), [Text.Encoding]::ASCII)
        Set-Content -LiteralPath $transition -Value (New-ShimBody -Target $batchTarget) -Encoding ASCII -NoNewline
        if (Install-NativeShim -Wrapper $transition) { return $false }
        if ((Test-Path -LiteralPath $transitionExe) -or (Test-Path -LiteralPath $transitionMetadata)) { return $false }
        if ($null -ne (Test-NativeShim -Wrapper $transition)) { return $false }
        $driver = Join-Path $fixture 'transition-driver.ps1'
        $code = @'
$env:PATH = $env:SU_SHIM_TRANSITION_BIN + ';' + $env:PATH
$resolved = (Get-Command transition-probe).Source
$output = transition-probe
[ordered]@{ resolved = $resolved; output = $output; code = $LASTEXITCODE } | ConvertTo-Json -Compress
'@
        [IO.File]::WriteAllText($driver, $code, (New-Object Text.UTF8Encoding($true)))
        $saved = $env:SU_SHIM_TRANSITION_BIN
        try {
            $env:SU_SHIM_TRANSITION_BIN = $bin
            $result = Invoke-Probe -Exe (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -Raw ('-NoProfile -File "' + $driver + '"') -InputText ''
            $capture = Read-Probe $result
            $result.ExitCode -eq 0 -and $capture.resolved -ieq $transition -and
                $capture.output -ceq 'transition batch target' -and $capture.code -eq 0 -and
                -not (Install-NativeShim -Wrapper $transition)
        } finally { [Environment]::SetEnvironmentVariable('SU_SHIM_TRANSITION_BIN', $saved, 'Process') }
    }
    It 'removes owned EXE companions for unsupported prologues and executes their initialization' {
        $transition = Join-Path $bin 'prologue-probe.cmd'
        Set-Content -LiteralPath $transition -Value (New-ShimBody -Target $target) -Encoding ASCII -NoNewline
        [void](Install-NativeShim -Wrapper $transition)
        $changed = New-ShimBody -Target $target -Prologue @('echo initialization sentinel')
        Set-Content -LiteralPath $transition -Value $changed -Encoding ASCII -NoNewline
        if (Install-NativeShim -Wrapper $transition) { return $false }
        if ((Test-Path -LiteralPath ([IO.Path]::ChangeExtension($transition, '.exe'))) -or
            (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($transition, '.shim.json')))) { return $false }
        $result = Invoke-Probe -Exe (Join-Path $env:WINDIR 'System32\cmd.exe') -Raw ('/d /s /c ""' + $transition + '""') -InputText ''
        $result.ExitCode -eq 0 -and $result.Output.StartsWith('initialization sentinel') -and
            [IO.File]::ReadAllText($transition) -ceq $changed
    }
    It 'refuses orphan companion metadata without changing it or publishing an executable' {
        $orphan = Join-Path $bin 'orphan-probe.cmd'
        $orphanMetadata = [IO.Path]::ChangeExtension($orphan, '.shim.json')
        Set-Content -LiteralPath $orphan -Value (New-ShimBody -Target $target) -Encoding ASCII -NoNewline
        Copy-Item -LiteralPath $metadata -Destination $orphanMetadata
        $before = (Get-FileHash -LiteralPath $orphanMetadata -Algorithm SHA256).Hash
        $refused = $false
        try { Install-NativeShim -Wrapper $orphan | Out-Null } catch { $refused = $_.Exception.Message -match 'orphan|incomplete' }
        $refused -and $before -eq (Get-FileHash -LiteralPath $orphanMetadata -Algorithm SHA256).Hash -and
            -not (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($orphan, '.exe')))
    }
    It 'refuses either orphan cache artifact before compiling or changing its bytes' {
        foreach ($which in @('receipt', 'executable')) {
            $cacheDirectory = Join-Path $fixture ('orphan-cache-' + $which)
            New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
            $cacheExe = Join-Path $cacheDirectory '.native-shim-launcher.exe'
            $cacheReceipt = Join-Path $cacheDirectory '.native-shim-launcher.json'
            if ($which -eq 'receipt') {
                Copy-Item -LiteralPath (Join-Path $bin '.native-shim-launcher.json') -Destination $cacheReceipt
                $retained = $cacheReceipt
                $absent = $cacheExe
            } else {
                Copy-Item -LiteralPath $target -Destination $cacheExe
                $retained = $cacheExe
                $absent = $cacheReceipt
            }
            $before = (Get-FileHash -LiteralPath $retained -Algorithm SHA256).Hash
            $refused = $false
            try { Get-NativeShimLauncher -Directory $cacheDirectory | Out-Null } catch { $refused = $_.Exception.Message -match 'orphan|incomplete|unowned' }
            if (-not $refused -or $before -ne (Get-FileHash -LiteralPath $retained -Algorithm SHA256).Hash -or
                (Test-Path -LiteralPath $absent)) { return $false }
        }
        $true
    }
    It 'production writers refuse unknown transition artifacts before changing existing CMD bytes' {
        . (Join-Path $repoRoot 'lib\ShimPlan.ps1')
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts\build-devtoolbox.ps1'), [ref]$tokens, [ref]$errors)
        $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-CmdWrapper' }, $true)
        $definition = [scriptblock]::Create($function.Extent.Text)
        foreach ($writer in @('builder', 'planner')) {
            $writerRoot = Join-Path $fixture ('unknown-transition-' + $writer)
            $writerBin = Join-Path $writerRoot 'native\bin'
            New-Item -ItemType Directory -Path $writerBin -Force | Out-Null
            $writerWrapper = Join-Path $writerBin 'unknown.cmd'
            Set-Content -LiteralPath $writerWrapper -Value (New-ShimBody -Target $target) -Encoding ASCII -NoNewline
            Copy-Item -LiteralPath $target -Destination ([IO.Path]::ChangeExtension($writerWrapper, '.exe'))
            $before = (Get-FileHash -LiteralPath $writerWrapper -Algorithm SHA256).Hash
            $refused = $false
            try {
                if ($writer -eq 'builder') {
                    & {
                        param($Definition, $Root, $Target)
                        $DryRun = $false
                        . $Definition
                        New-CmdWrapper -Name 'unknown' -Target $Target
                    } $definition $writerRoot (Join-Path $fixture 'new-target.cmd') | Out-Null
                } else {
                    $plan = @{ Write = @([pscustomobject]@{ Name = 'unknown'; Target = (Join-Path $fixture 'new-target.cmd'); Wrapper = $writerWrapper; Refresh = $true }) }
                    Invoke-ShimWrite -Plan $plan -NativeBin $writerBin | Out-Null
                }
            } catch { $refused = $_.Exception.Message -match 'owned|orphan|incomplete' }
            if (-not $refused -or $before -ne (Get-FileHash -LiteralPath $writerWrapper -Algorithm SHA256).Hash) { return $false }
        }
        $true
    }
    It 'a locked owned companion prevents the production builder from changing its CMD contract' {
        $lockedRoot = Join-Path $fixture 'locked-transition'
        $lockedBin = Join-Path $lockedRoot 'native\bin'
        New-Item -ItemType Directory -Path $lockedBin -Force | Out-Null
        $lockedWrapper = Join-Path $lockedBin 'locked.cmd'
        Set-Content -LiteralPath $lockedWrapper -Value (New-ShimBody -Target $target) -Encoding ASCII -NoNewline
        [void](Install-NativeShim -Wrapper $lockedWrapper)
        $lockedExe = [IO.Path]::ChangeExtension($lockedWrapper, '.exe')
        $lockedMetadata = [IO.Path]::ChangeExtension($lockedWrapper, '.shim.json')
        $before = (Get-FileHash -LiteralPath $lockedWrapper -Algorithm SHA256).Hash
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts\build-devtoolbox.ps1'), [ref]$tokens, [ref]$errors)
        $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-CmdWrapper' }, $true)
        $definition = [scriptblock]::Create($function.Extent.Text)
        $handle = [IO.File]::Open($lockedExe, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $refused = $false
            try {
                & {
                    param($Definition, $Root, $Target)
                    $DryRun = $false
                    . $Definition
                    New-CmdWrapper -Name 'locked' -Target $Target
                } $definition $lockedRoot (Join-Path $fixture 'batch-after-lock.cmd') | Out-Null
            } catch { $refused = $true }
            $refused -and $before -eq (Get-FileHash -LiteralPath $lockedWrapper -Algorithm SHA256).Hash -and
                (Test-Path -LiteralPath $lockedExe) -and (Test-Path -LiteralPath $lockedMetadata)
        } finally { $handle.Dispose() }
    }
    It 'a locked upgrade receipt preserves the owned cache and both production CMD contracts' {
        . (Join-Path $repoRoot 'lib\ShimPlan.ps1')
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts\build-devtoolbox.ps1'), [ref]$tokens, [ref]$errors)
        $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-CmdWrapper' }, $true)
        $definition = [scriptblock]::Create($function.Extent.Text)
        foreach ($writer in @('launcher', 'builder', 'planner')) {
            $upgradeRoot = Join-Path $fixture ('locked-cache-' + $writer)
            $upgradeBin = Join-Path $upgradeRoot 'native\bin'
            $publisher = Join-Path $upgradeRoot 'publisher'
            New-Item -ItemType Directory -Path $upgradeBin, $publisher -Force | Out-Null
            foreach ($name in @('ShimFormat.ps1', 'SourceFiles.ps1', 'NativeShim.cs')) {
                Copy-Item -LiteralPath (Join-Path $repoRoot ('lib\' + $name)) -Destination (Join-Path $publisher $name)
            }
            $passed = & {
                param($Publisher, $Root, $Bin, $Writer, $Definition, $Target)
                . (Join-Path $Publisher 'ShimFormat.ps1')
                $upgradeWrapper = Join-Path $Bin 'upgrade.cmd'
                Set-Content -LiteralPath $upgradeWrapper -Value (New-ShimBody -Target $Target) -Encoding ASCII -NoNewline
                [void](Install-NativeShim -Wrapper $upgradeWrapper)
                $cache = Get-NativeShimCacheState -Directory $Bin
                $paths = @($upgradeWrapper, $cache.Launcher, $cache.Receipt,
                    [IO.Path]::ChangeExtension($upgradeWrapper, '.exe'), [IO.Path]::ChangeExtension($upgradeWrapper, '.shim.json'))
                $before = @{}
                foreach ($path in $paths) { $before[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
                # This is a real source upgrade in an isolated copied publisher.
                [IO.File]::AppendAllText((Join-Path $Publisher 'NativeShim.cs'), ([Environment]::NewLine + '// isolated upgrade'))
                $newTarget = Join-Path $Root 'new target.exe'
                Copy-Item -LiteralPath $Target -Destination $newTarget
                $handle = [IO.File]::Open($cache.Receipt, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                try {
                    $refused = $false
                    try {
                        if ($Writer -eq 'launcher') {
                            Get-NativeShimLauncher -Directory $Bin | Out-Null
                        } elseif ($Writer -eq 'builder') {
                            $DryRun = $false
                            . $Definition
                            New-CmdWrapper -Name 'upgrade' -Target $newTarget | Out-Null
                        } else {
                            $plan = @{ Write = @([pscustomobject]@{ Name = 'upgrade'; Target = $newTarget; Wrapper = $upgradeWrapper; Refresh = $true }) }
                            Invoke-ShimWrite -Plan $plan -NativeBin $Bin | Out-Null
                        }
                    } catch { $refused = $true }
                    if (-not $refused) { return $false }
                    foreach ($path in $paths) {
                        if ($before[$path] -ne (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash) { return $false }
                    }
                    [void](Get-NativeShimCacheState -Directory $Bin)
                } finally { $handle.Dispose() }
                # The same upgrade succeeds after the external reader releases it.
                [void](Install-NativeShim -Wrapper $upgradeWrapper)
                $null -eq (Test-NativeShim -Wrapper $upgradeWrapper)
            } $publisher $upgradeRoot $upgradeBin $writer $definition $target
            if (-not $passed) { return $false }
        }
        $true
    }
    It 'cache publication restores the exact owned pair on late locks and post-publication validation failure' {
        foreach ($failure in @('launcher', 'receipt', 'validation')) {
            $publicationBin = Join-Path $fixture ('cache-rollback-' + $failure)
            New-Item -ItemType Directory -Path $publicationBin -Force | Out-Null
            [void](Get-NativeShimLauncher -Directory $publicationBin)
            $cache = Get-NativeShimCacheState -Directory $publicationBin
            $beforeLauncher = (Get-FileHash -LiteralPath $cache.Launcher -Algorithm SHA256).Hash
            $beforeReceipt = (Get-FileHash -LiteralPath $cache.Receipt -Algorithm SHA256).Hash
            $stagedLauncher = Join-Path $publicationBin '.native-shim-test.exe'
            $stagedReceipt = Join-Path $publicationBin '.native-shim-test.json'
            Copy-Item -LiteralPath $cache.Launcher -Destination $stagedLauncher
            [IO.File]::AppendAllText($stagedLauncher, 'isolated transaction marker')
            $digest = (Get-FileHash -LiteralPath $stagedLauncher -Algorithm SHA256).Hash
            if ($failure -eq 'validation') { $digest = ('0' * 64) }
            $record = [ordered]@{
                source_sha256 = $cache.Record.source_sha256
                launcher_sha256 = $digest
                previous_launcher_sha256 = @($cache.KnownHashes)
            }
            [IO.File]::WriteAllText($stagedReceipt, ($record | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
            $handle = $null
            if ($failure -ne 'validation') {
                $lockedPath = if ($failure -eq 'launcher') { $cache.Launcher } else { $cache.Receipt }
                $handle = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            }
            try {
                $refused = $false
                try {
                    # A lock appearing after Get-NativeShimLauncher's preflight
                    # must also be safe at the actual two-file publication boundary.
                    Publish-NativeShimCache -Directory $publicationBin -StagedLauncher $stagedLauncher -StagedReceipt $stagedReceipt -ExpectedCache $cache
                } catch { $refused = $true }
                if (-not $refused -or
                    $beforeLauncher -ne (Get-FileHash -LiteralPath $cache.Launcher -Algorithm SHA256).Hash -or
                    $beforeReceipt -ne (Get-FileHash -LiteralPath $cache.Receipt -Algorithm SHA256).Hash) { return $false }
                [void](Get-NativeShimCacheState -Directory $publicationBin)
                if ((Test-Path -LiteralPath $stagedLauncher) -or (Test-Path -LiteralPath $stagedReceipt) -or
                    @(Get-ChildItem -LiteralPath $publicationBin -Filter '.native-shim-*.before.*').Count) { return $false }
            } finally { if ($null -ne $handle) { $handle.Dispose() } }
        }
        $true
    }
    It 'reuses an unchanged owned cache while its receipt is held by a read-only reader' {
        $reuseBin = Join-Path $fixture 'cache-read-only-reuse'
        New-Item -ItemType Directory -Path $reuseBin -Force | Out-Null
        $launcher = Get-NativeShimLauncher -Directory $reuseBin
        $cache = Get-NativeShimCacheState -Directory $reuseBin
        $before = (Get-FileHash -LiteralPath $cache.Receipt -Algorithm SHA256).Hash
        $handle = [IO.File]::Open($cache.Receipt, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            (Get-NativeShimLauncher -Directory $reuseBin) -ceq $launcher -and
                $before -eq (Get-FileHash -LiteralPath $cache.Receipt -Algorithm SHA256).Hash
        } finally { $handle.Dispose() }
    }
    It 'refuses a stale prepared generation without discarding a healthy cache ownership history' {
        $generationBin = Join-Path $fixture 'cache-stale-generation'
        New-Item -ItemType Directory -Path $generationBin -Force | Out-Null
        [void](Get-NativeShimLauncher -Directory $generationBin)
        $cache = Get-NativeShimCacheState -Directory $generationBin
        $stagedLauncher = Join-Path $generationBin '.native-shim-test.exe'
        $stagedReceipt = Join-Path $generationBin '.native-shim-test.json'
        Copy-Item -LiteralPath $cache.Launcher -Destination $stagedLauncher
        Copy-Item -LiteralPath $cache.Receipt -Destination $stagedReceipt
        # Model another valid publisher generation with an additional known digest.
        # These are owned synthetic receipt bytes inside the isolated cache only.
        $newRecord = [ordered]@{
            source_sha256 = $cache.Record.source_sha256
            launcher_sha256 = $cache.Record.launcher_sha256
            previous_launcher_sha256 = @($cache.Record.previous_launcher_sha256) + @('F' * 64)
        }
        [IO.File]::WriteAllText($cache.Receipt, ($newRecord | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        [void](Get-NativeShimCacheState -Directory $generationBin)
        $beforeLauncher = (Get-FileHash -LiteralPath $cache.Launcher -Algorithm SHA256).Hash
        $beforeReceipt = (Get-FileHash -LiteralPath $cache.Receipt -Algorithm SHA256).Hash
        $refused = $false
        try {
            Publish-NativeShimCache -Directory $generationBin -StagedLauncher $stagedLauncher -StagedReceipt $stagedReceipt -ExpectedCache $cache
        } catch { $refused = $_.Exception.Message -match 'changed while preparing' }
        $refused -and $beforeLauncher -eq (Get-FileHash -LiteralPath $cache.Launcher -Algorithm SHA256).Hash -and
            $beforeReceipt -eq (Get-FileHash -LiteralPath $cache.Receipt -Algorithm SHA256).Hash
    }
    It 'refuses staging aliases before cleanup can remove any live cache artifact' {
        $aliasBin = Join-Path $fixture 'cache-stage-aliases'
        New-Item -ItemType Directory -Path $aliasBin -Force | Out-Null
        [void](Get-NativeShimLauncher -Directory $aliasBin)
        $cache = Get-NativeShimCacheState -Directory $aliasBin
        $beforeLauncher = (Get-FileHash -LiteralPath $cache.Launcher -Algorithm SHA256).Hash
        $beforeReceipt = (Get-FileHash -LiteralPath $cache.Receipt -Algorithm SHA256).Hash
        $stage = Join-Path $aliasBin '.native-shim-test.exe'
        Copy-Item -LiteralPath $cache.Launcher -Destination $stage
        foreach ($pair in @(
            @($cache.Launcher, $stage), @($stage, $cache.Receipt), @($stage, $stage)
        )) {
            $refused = $false
            try {
                Publish-NativeShimCache -Directory $aliasBin -StagedLauncher $pair[0] -StagedReceipt $pair[1] -ExpectedCache $cache
            } catch { $refused = $_.Exception.Message -match 'alias|distinct' }
            if (-not $refused -or $beforeLauncher -ne (Get-FileHash -LiteralPath $cache.Launcher -Algorithm SHA256).Hash -or
                $beforeReceipt -ne (Get-FileHash -LiteralPath $cache.Receipt -Algorithm SHA256).Hash) { return $false }
        }
        [void](Get-NativeShimCacheState -Directory $aliasBin)
        $true
    }
    It 'reports blocked rollback under Continue and preserves recoverable prior bytes' {
        foreach ($existing in @($false, $true)) {
            $recoveryBin = Join-Path $fixture ('cache-blocked-recovery-' + $existing)
            New-Item -ItemType Directory -Path $recoveryBin -Force | Out-Null
            $cache = $null
            $oldHash = $null
            if ($existing) {
                [void](Get-NativeShimLauncher -Directory $recoveryBin)
                $cache = Get-NativeShimCacheState -Directory $recoveryBin
                $oldHash = (Get-FileHash -LiteralPath $cache.Launcher -Algorithm SHA256).Hash
            }
            $stagedLauncher = Join-Path $recoveryBin '.native-shim-test.exe'
            $stagedReceipt = Join-Path $recoveryBin '.native-shim-test.json'
            $seed = Get-NativeShimCacheState -Directory $bin
            Copy-Item -LiteralPath $seed.Launcher -Destination $stagedLauncher
            [IO.File]::AppendAllText($stagedLauncher, 'isolated rollback lock')
            $newRecord = [ordered]@{
                source_sha256 = $seed.Record.source_sha256
                launcher_sha256 = (Get-FileHash -LiteralPath $stagedLauncher -Algorithm SHA256).Hash
                previous_launcher_sha256 = @($seed.KnownHashes)
            }
            [IO.File]::WriteAllText($stagedReceipt, ($newRecord | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
            $outcome = & {
                param($Directory, $StageExe, $StageReceipt, $Expected)
                $ErrorActionPreference = 'Continue'
                $originalReader = (Get-Item -LiteralPath Function:\Get-NativeShimCacheState).ScriptBlock
                $context = @{ Calls = 0; Handle = $null }
                function Get-NativeShimCacheState {
                    param([string]$Directory)
                    $context.Calls++
                    if ($context.Calls -eq 2) {
                        $context.Handle = [IO.File]::Open((Join-Path $Directory '.native-shim-launcher.exe'),
                            [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                        throw 'isolated final verification failure'
                    }
                    & $originalReader -Directory $Directory
                }
                try {
                    $failure = ''
                    try {
                        Publish-NativeShimCache -Directory $Directory -StagedLauncher $StageExe -StagedReceipt $StageReceipt -ExpectedCache $Expected
                    } catch { $failure = $_.Exception.Message }
                    $failure -match 'isolated final verification failure' -and $failure -match 'Recovery was blocked' -and
                        $failure.Contains((Join-Path $Directory '.native-shim-launcher.exe')) -and $context.Calls -eq 2
                } finally { if ($null -ne $context.Handle) { $context.Handle.Dispose() } }
            } $recoveryBin $stagedLauncher $stagedReceipt $cache
            if (-not $outcome) { return $false }
            $recoveryExe = Join-Path $recoveryBin '.native-shim-launcher.exe'
            $backups = @(Get-ChildItem -LiteralPath $recoveryBin -Filter '.native-shim-*.before.exe')
            if ($existing) {
                if ($backups.Count -ne 1 -or $oldHash -ne (Get-FileHash -LiteralPath $backups[0].FullName -Algorithm SHA256).Hash) { return $false }
                [IO.File]::Replace($backups[0].FullName, $recoveryExe, [NullString]::Value)
                [void](Get-NativeShimCacheState -Directory $recoveryBin)
            } else {
                if ($backups.Count -ne 0 -or (Test-Path -LiteralPath (Join-Path $recoveryBin '.native-shim-launcher.json'))) { return $false }
                Remove-Item -LiteralPath $recoveryExe -Force -ErrorAction Stop
                if ($null -ne (Get-NativeShimCacheState -Directory $recoveryBin)) { return $false }
            }
        }
        $true
    }
    It 'a cleanup lock does not mask the original receipt publication failure' {
        $cleanupBin = Join-Path $fixture 'cache-cleanup-lock'
        New-Item -ItemType Directory -Path $cleanupBin -Force | Out-Null
        [void](Get-NativeShimLauncher -Directory $cleanupBin)
        $cache = Get-NativeShimCacheState -Directory $cleanupBin
        $stagedLauncher = Join-Path $cleanupBin '.native-shim-test.exe'
        $stagedReceipt = Join-Path $cleanupBin '.native-shim-test.json'
        Copy-Item -LiteralPath $cache.Launcher -Destination $stagedLauncher
        Copy-Item -LiteralPath $cache.Receipt -Destination $stagedReceipt
        $oldLock = [IO.File]::Open($cache.Receipt, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $stageLock = [IO.File]::Open($stagedReceipt, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $failure = ''
            try {
                Publish-NativeShimCache -Directory $cleanupBin -StagedLauncher $stagedLauncher -StagedReceipt $stagedReceipt -ExpectedCache $cache
            } catch { $failure = $_.Exception.Message }
            $failure -match 'Replace' -and (Test-Path -LiteralPath $stagedReceipt) -and
                $null -ne (Get-NativeShimCacheState -Directory $cleanupBin)
        } finally { $oldLock.Dispose(); $stageLock.Dispose() }
    }
    It 'repair dry-run preserves an owned stale pair and apply removes it without changing the batch wrapper or cache' {
        $repairRoot = Join-Path $fixture 'repair-fixture'
        $repairBin = Join-Path $repairRoot 'native\bin'
        New-Item -ItemType Directory -Path $repairBin -Force | Out-Null
        $repairWrapper = Join-Path $repairBin 'repair-probe.cmd'
        Set-Content -LiteralPath $repairWrapper -Value (New-ShimBody -Target $target) -Encoding ASCII -NoNewline
        [void](Install-NativeShim -Wrapper $repairWrapper)
        $repairExe = [IO.Path]::ChangeExtension($repairWrapper, '.exe')
        $repairMetadata = [IO.Path]::ChangeExtension($repairWrapper, '.shim.json')
        $originalMetadata = [IO.File]::ReadAllText($repairMetadata)
        $batchTarget = Join-Path $fixture 'repair target.cmd'
        [IO.File]::WriteAllLines($batchTarget, @('@echo off', 'echo repaired batch'), [Text.Encoding]::ASCII)
        Set-Content -LiteralPath $repairWrapper -Value (New-ShimBody -Target $batchTarget) -Encoding ASCII -NoNewline
        $cacheReceipt = Join-Path $repairBin '.native-shim-launcher.json'
        $before = @{}
        foreach ($path in @($repairWrapper, $repairExe, $repairMetadata, $cacheReceipt)) {
            $before[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        }
        $script = Join-Path $repoRoot 'scripts\repair-native-shims.ps1'
        $shell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script + '" -Root "' + $repairRoot + '"'
        $preview = Invoke-Probe -Exe $shell -Raw ($arguments + ' -DryRun') -InputText ''
        if ($preview.ExitCode -ne 0 -or $preview.Output -notmatch 'PLAN remove owned obsolete companion') { throw "Repair preview failed $($preview.ExitCode): $($preview.Output) $($preview.Error)" }
        foreach ($path in $before.Keys) {
            if ($before[$path] -ne (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash) { return $false }
        }
        $applied = Invoke-Probe -Exe $shell -Raw $arguments -InputText ''
        if ($applied.ExitCode -ne 0 -or (Test-Path -LiteralPath $repairExe) -or (Test-Path -LiteralPath $repairMetadata)) { throw "Repair apply failed $($applied.ExitCode): $($applied.Output) $($applied.Error)" }
        if ($before[$repairWrapper] -ne (Get-FileHash -LiteralPath $repairWrapper -Algorithm SHA256).Hash -or
            $before[$cacheReceipt] -ne (Get-FileHash -LiteralPath $cacheReceipt -Algorithm SHA256).Hash) { return $false }
        [IO.File]::WriteAllText($repairMetadata, $originalMetadata, (New-Object Text.UTF8Encoding($false)))
        $orphanBefore = (Get-FileHash -LiteralPath $repairMetadata -Algorithm SHA256).Hash
        $refused = Invoke-Probe -Exe $shell -Raw ($arguments + ' -DryRun') -InputText ''
        $refused.ExitCode -ne 0 -and $orphanBefore -eq (Get-FileHash -LiteralPath $repairMetadata -Algorithm SHA256).Hash -and
            -not (Test-Path -LiteralPath $repairExe)
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
            Remove-Item -LiteralPath $metadata -Force
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
