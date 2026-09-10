#Requires -Version 5.1
<#
    Tests for lib\SysmonConfig.ps1 - the rendering and validation behind the deletion-forensics
    sensor.

    A VALIDATOR THAT HAS NEVER REJECTED ANYTHING IS NOT A VALIDATOR. These functions exist
    because for a year the shipped config named one specific profile in 24 rules, so on any
    other machine the include list matched nothing: the sensor recorded ZERO deletions while
    -Verify reported fully green and the smoke test passed. That is the worst failure this
    tooling can have, and nothing anywhere would have caught it - so the checks that catch it
    now had better be shown to fire.

    They live in lib\ rather than in the installer for the same reason ForensicsReport.Core.ps1
    exists: the installer self-elevates and changes machine state at load, so nothing can
    import it.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-InstallerTests.ps1
#>
[CmdletBinding()]
param()

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib\SysmonConfig.ps1')

$script:Pass = 0; $script:Fail = 0
function It {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    try {
        if (& $Body) { $script:Pass++; Write-Host "  ok   $Name" -ForegroundColor Green }
        else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
    } catch { $script:Fail++; Write-Host "  FAIL $Name - $($_.Exception.Message)" -ForegroundColor Red }
}

$template = Join-Path $repoRoot 'config\sysmon-filedelete.xml'

# A filesystem the suite describes, rather than this machine's. Without this seam every test
# below would silently depend on which directories happen to exist on the box running it.
$fakeFs = { param($p) $p -like 'C:\Users\Someone*' -or $p -eq 'C:\Users\Someone' }

function New-Config {
    param([string]$Profile = 'C:\Users\Someone')
    Get-RenderedSysmonConfig -TemplatePath $template -ProfilePath $Profile
}

Write-Host "`n== rendering ==" -ForegroundColor Cyan

It 'the shipped template still contains the placeholder' {
    # If someone re-hardcodes a profile, everything below passes while the sensor silently
    # becomes machine-specific again. That is the regression this file exists to prevent.
    (Get-Content $template -Raw) -match '\|USERPROFILE\|'
}
It 'the shipped template contains NO hardcoded user profile' {
    (Get-Content $template -Raw) -notmatch '(?i)C:\\Users\\[A-Za-z0-9._-]+\\'
}
It 'rendering substitutes every occurrence' {
    (New-Config) -notmatch '\|'
}
It 'rendering puts the given profile into the include rules' {
    $x = [xml](New-Config)
    $inc = @($x.SelectNodes("//FileDeleteDetected[@onmatch='include']/TargetFilename"))
    ($inc.Count -eq 3) -and (@($inc | Where-Object { $_.InnerText -like 'C:\Users\Someone*' }).Count -eq 3)
}
It 'a trailing separator on the profile does not produce a doubled one' {
    (New-Config -Profile 'C:\Users\Someone\') -notmatch 'Someone\\\\'
}
It 'the rendered config is still well-formed XML' {
    $null = [xml](New-Config); $true
}

Write-Host "`n== validation must actually reject things ==" -ForegroundColor Cyan

It 'a correctly rendered config for an existing profile passes' {
    # The positive control. Without it, a validator that rejects everything looks perfect.
    (Test-RenderedSysmonConfig -Text (New-Config) -ProfilePath 'C:\Users\Someone' -DirectoryExists $fakeFs).Count -eq 0
}
It 'an UNRENDERED template is REJECTED - the failure that started all this' {
    # Deploying the raw template is the shape of the original bug: rules naming a path that is
    # not this machine's, silently matching nothing.
    $raw = Get-Content $template -Raw
    $p = Test-RenderedSysmonConfig -Text $raw -ProfilePath 'C:\Users\Someone' -DirectoryExists $fakeFs
    @($p | Where-Object { $_ -match 'unsubstituted' }).Count -ge 1
}
It 'a config rendered for a profile that does not exist is REJECTED' {
    # The exact original bug: valid XML, fully substituted, every rule pointing at a machine
    # that is not this one.
    $p = Test-RenderedSysmonConfig -Text (New-Config -Profile 'C:\Users\Nobody') `
             -ProfilePath 'C:\Users\Nobody' -DirectoryExists $fakeFs
    @($p | Where-Object { $_ -match 'does not exist' }).Count -ge 1
}
It 'malformed XML is REJECTED' {
    $p = Test-RenderedSysmonConfig -Text '<Sysmon><unclosed></Sysmon>' -DirectoryExists $fakeFs
    @($p | Where-Object { $_ -match 'well-formed' }).Count -eq 1
}
It 'a config with NO include rules is REJECTED, not treated as quiet' {
    # A sensor with an empty include list records nothing, which reads downstream exactly like
    # a week in which nothing was deleted.
    $p = Test-RenderedSysmonConfig -Text '<Sysmon schemaversion="4.90"><EventFiltering /></Sysmon>' -DirectoryExists $fakeFs
    @($p | Where-Object { $_ -match 'record nothing' }).Count -eq 1
}
It 'every problem is reported, not just the first' {
    # Fixing one and rediscovering the next on the following run is how a short outage becomes
    # a long one.
    $p = Test-RenderedSysmonConfig -Text (Get-Content $template -Raw) `
             -ProfilePath 'C:\Users\Nobody' -DirectoryExists $fakeFs
    $p.Count -ge 2
}

Write-Host ("`n{0} passed, {1} failed`n" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })
