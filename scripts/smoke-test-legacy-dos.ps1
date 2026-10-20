#Requires -Version 5.1
<#
.SYNOPSIS
Functionally verify optional DOS tools without downloading or installing packages.
.EXAMPLE
.\scripts\smoke-test-legacy-dos.ps1 -Component Capstone
.EXAMPLE
.\scripts\smoke-test-legacy-dos.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('Capstone', 'Unicorn', 'Dosbox', 'Ghidra', 'Watcom', 'All')]
    [string]$Component = 'All',
    [string]$WindowMonitorDevice = '',
    [string]$Root = $(if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" })
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib\common.ps1')
$pass = 0
$fail = 0
$py = Join-Path $Root 'python\.venv\Scripts\python.exe'
$bin = Join-Path $Root 'native\bin'
$chosen = if ($Component -eq 'All') { @('Capstone', 'Unicorn', 'Dosbox', 'Watcom', 'Ghidra') } else { @($Component) }

foreach ($name in $chosen) {
    try {
        switch ($name) {
            'Capstone' {
                $code = 'import capstone; assert len(list(capstone.Cs(capstone.CS_ARCH_X86,capstone.CS_MODE_32).disasm(bytes([144,195]),0))) == 2; print(capstone.__version__)'
                $r = Invoke-Native -FilePath $py -Arguments @('-X', 'utf8', '-c', $code)
                if ($r.ExitCode -ne 0) { throw ($r.Output -join ' ') }
            }
            'Unicorn' {
                $code = 'import unicorn; from unicorn.x86_const import UC_X86_REG_EAX; u=unicorn.Uc(unicorn.UC_ARCH_X86,unicorn.UC_MODE_32); u.mem_map(4096,4096); u.mem_write(4096,bytes([184,7,0,0,0,131,192,1])); u.emu_start(4096,4104); assert u.reg_read(UC_X86_REG_EAX)==8; print(unicorn.__version__)'
                $r = Invoke-Native -FilePath $py -Arguments @('-X', 'utf8', '-c', $code)
                if ($r.ExitCode -ne 0) { throw ($r.Output -join ' ') }
            }
            'Dosbox' {
                $tool = Join-Path $bin 'dosbox-x.cmd'
                $target = Get-ShimTarget -Lines @(Get-Content -LiteralPath $tool)
                if (-not $target -or -not (Test-Path -LiteralPath $target -PathType Leaf)) { throw 'DOSBox-X shim has no existing executable target.' }
                $arguments = @('-X', 'utf8', (Join-Path $repoRoot 'tools\probe_dosbox.py'), '--executable', $target)
                if ($WindowMonitorDevice) { $arguments += @('--window-monitor-device', $WindowMonitorDevice) }
                $r = Invoke-Native -FilePath $py -Arguments $arguments
                if ($r.ExitCode -ne 0) { throw "DOSBox-X guest boot failed: $($r.Output -join ' ')" }
                $result = ($r.Output -join [Environment]::NewLine) | ConvertFrom-Json
                if (-not $result.nonce_verified -or $result.exit_code -ne 0) { throw 'DOSBox-X guest boot did not verify its fresh marker.' }
                Write-Info "DOS guest marker verified; evidence: $($result.work). Debugger and protected-mode capture remain unverified."
            }
            'Watcom' {
                $work = Join-Path $repoRoot ('logs\legacy-dos-smoke-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $work -Force | Out-Null
                $source = Join-Path $work 'hello.c'
                $exe = Join-Path $work 'hello.exe'
                $obj = Join-Path $work 'hello.obj'
                Set-Content -LiteralPath $source -Value '#include <stdio.h>
int main(void) { puts("TOOLBOX_DOS_SMOKE"); return 0; }' -Encoding ASCII
                $r = Invoke-Native -FilePath (Join-Path $bin 'wcl386.cmd') -Arguments @('-q', '-bt=dos', '-l=dos4g', ("-fe=" + $exe), ("-fo=" + $obj), $source)
                if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $exe)) { throw "DOS compile failed: $($r.Output -join ' ')" }
                $header = [IO.File]::ReadAllBytes($exe)
                if ($header.Length -lt 64 -or $header[0] -ne 77 -or $header[1] -ne 90) { throw 'Compiler output does not have a DOS MZ header.' }
                Write-Info "DOS build fixture retained at $exe; runtime parity is checked by the game harness."
            }
            'Ghidra' {
                $work = Join-Path $repoRoot ('logs\legacy-dos-ghidra-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $work -Force | Out-Null
                $fixture = Join-Path $work 'return-seven.bin'
                [IO.File]::WriteAllBytes($fixture, [byte[]]@(184, 7, 0, 0, 0, 195))
                $r = Invoke-Native -FilePath (Join-Path $bin 'analyzeHeadless.cmd') -Arguments @($work, 'smoke', '-import', $fixture, '-processor', 'x86:LE:32:default', '-analysisTimeoutPerFile', '30', '-scriptPath', (Join-Path $repoRoot 'tools'), '-postScript', 'LegacyDosSmoke.java')
                if ($r.ExitCode -ne 0 -or ($r.Output -join ' ') -notmatch 'TOOLBOX_GHIDRA_SMOKE_OK') { throw "Ghidra import/decompile failed: $($r.Output -join ' ')" }
            }
        }
        $pass++
        Write-Ok "$name functional smoke passed"
    } catch {
        $fail++
        Write-Err "$name smoke failed: $($_.Exception.Message)"
    }
}
Write-Host ("{0} passed, {1} failed" -f $pass, $fail)
if ($fail) { exit 1 }
exit 0

