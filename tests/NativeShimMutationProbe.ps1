#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Hold', 'Write', 'WritePaused', 'RepairPaused')][string]$Mode,
    [Parameter(Mandatory)][string]$Library,
    [Parameter(Mandatory)][string]$Directory,
    [Parameter(Mandatory)][string]$Ready,
    [Parameter(Mandatory)][string]$Release,
    [Parameter(Mandatory)][string]$Completed,
    [string]$Wrapper,
    [string]$BodyFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $Library 'ShimFormat.ps1')
function Wait-ProbeRelease {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $Release)) {
        if ($watch.ElapsedMilliseconds -ge 12000) { throw 'Mutation probe release timed out.' }
        Start-Sleep -Milliseconds 20
    }
}
$completion = 'completed'
if ($Mode -eq 'Hold') {
    Invoke-NativeShimMutation -Directory $Directory -Action {
        [IO.File]::WriteAllText($Ready, 'held')
        Wait-ProbeRelease
    }
} elseif ($Mode -eq 'RepairPaused') {
    $classify = (Get-Item -LiteralPath Function:\Get-NativeShimConfiguration).ScriptBlock
    $context = @{ Paused = $false }
    function Get-NativeShimConfiguration {
        param([string[]]$Lines)
        $configuration = & $classify -Lines $Lines
        if ($null -eq $configuration -and -not $context.Paused) {
            $context.Paused = $true
            [IO.File]::WriteAllText($Ready, 'classified-batch-under-outer-lock')
            Wait-ProbeRelease
        }
        return $configuration
    }
    $completion = Repair-NativeShimContract -Wrapper $Wrapper
} else {
    if ($Mode -eq 'WritePaused') {
        $prepare = (Get-Item -LiteralPath Function:\Prepare-NativeShimWrite).ScriptBlock
        function Prepare-NativeShimWrite {
            param([string]$Wrapper, [string]$Body)
            & $prepare -Wrapper $Wrapper -Body $Body
            [IO.File]::WriteAllText($Ready, 'prepared-under-outer-lock')
            Wait-ProbeRelease
        }
    } else {
        [IO.File]::WriteAllText($Ready, 'before-write-attempt')
    }
    $install = (Get-Item -LiteralPath Function:\Install-NativeShim).ScriptBlock
    function Install-NativeShim {
        param([string]$Wrapper)
        $installed = & $install -Wrapper $Wrapper
        # Validate this publisher before Write-NativeShim releases its outer
        # lock. A later legitimate publisher may replace its source generation.
        $failure = Test-NativeShim -Wrapper $Wrapper
        if ($null -ne $failure) { throw ('Mutation probe produced an incoherent shim: ' + $failure) }
        return $installed
    }
    Write-NativeShim -Wrapper $Wrapper -Body ([IO.File]::ReadAllText($BodyFile))
}
[IO.File]::WriteAllText($Completed, $completion)