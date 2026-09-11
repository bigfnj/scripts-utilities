#Requires -Version 5.1
<#
    Tests for lib\SysmonConfig.ps1 - the rendering and validation behind the deletion-forensics
    sensor - and for lib\catalog.ps1 / lib\common.ps1, the installer plumbing that decides
    whether a bootstrap run is allowed to call itself a success.

    Both halves are here for the same reason: A REPORT THAT CANNOT SAY "NO" IS NOT A REPORT.
    Install-CatalogGroup piped every per-item $true/$false to Out-Null, so a run in which
    EVERY winget install failed still printed "cli-tools group complete" and then "bootstrap
    complete". Get-Catalog read a schema_version and never compared it to anything. Both are
    the same failure shape as the sensor below, one layer up.

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

# The deletion tripwire, the suite floor and the arm-time control. FIRST, before every other
# dot-source: the Remove-Item shadow must be defined before any library can bind to the real
# cmdlet. $PSScriptRoot rather than $repoRoot so this needs nothing computed first.
. (Join-Path $PSScriptRoot 'SUTestGuard.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib\SysmonConfig.ps1')
# common.ps1 and catalog.ps1 define functions only - no side effects on dot-source - so they
# are importable here. $script:MANIFEST, which common.ps1 points at the REAL manifest, is
# redirected to a scratch file below before anything can write to it.
. (Join-Path $repoRoot 'lib\common.ps1')
. (Join-Path $repoRoot 'lib\catalog.ps1')
. (Join-Path $repoRoot 'modules\cli-tools.ps1')

$script:DryRun = $false
$scratch = Join-Path ([IO.Path]::GetTempPath()) ("installer-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$script:MANIFEST = Join-Path $scratch 'tools.json'

# REFUSING TO RUN rather than reporting a failed test: if the redirect above did not take, the
# tests below must not run at all - three of them delete $script:MANIFEST, and lib\common.ps1
# points it at the REAL manifest\tools.json until this line moves it.
#
# Asserts the runtime CONDITION (the path is under TEMP), not the source ORDER. Swap the
# dot-source below this line and an order check would still match the statement sitting there
# while the value it produced was a real path. The tally shape keeps both greppers honest.
if (-not $script:MANIFEST.StartsWith($script:SUTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "  REFUSING TO RUN: `$script:MANIFEST is '$script:MANIFEST', outside $($script:SUTempRoot)." -ForegroundColor Red
    Write-Host "  lib\common.ps1 must be dot-sourced BEFORE the redirect in this file." -ForegroundColor Red
    Write-Host "0 passed, 1 failed"
    exit 1
}

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

Write-Host "`n== a group install must not report success after failing ==" -ForegroundColor Cyan

# Stubs live inside & { } so they cannot leak into the sections above or below. PowerShell
# resolves function names up the CALL scope chain, so Install-CatalogGroup - defined in this
# file's scope by the dot-source - still finds the Install-CatalogItem defined in here.
& {
    $items = @(
        [pscustomobject]@{ name = 'alpha'; channel = 'winget-user'; id = 'Test.Alpha' },
        [pscustomobject]@{ name = 'beta';  channel = 'winget-user'; id = 'Test.Beta'  },
        [pscustomobject]@{ name = 'gamma'; channel = 'winget-user'; id = 'Test.Gamma' }
    )
    # A group the suite describes rather than whatever catalog.json happens to hold today.
    function Get-CatalogTools    { param([string]$Group) return $items }
    function Install-CatalogItem { param($Item) return (-not ($script:failing -contains $Item.name)) }
    function Write-Warn          { param([string]$Msg) }   # keep the per-item noise out of the tally

    It 'a group in which everything installs reports 0 failures' {
        # The positive control. Without it, a function that returns the item count always
        # looks like it is detecting failures.
        $script:failing = @()
        (Install-CatalogGroup -Group 'test') -eq 0
    }
    It 'a group in which EVERY install fails does NOT report success' {
        # The original bug, exactly: all three fail, the caller prints "group complete".
        $script:failing = @('alpha', 'beta', 'gamma')
        (Install-CatalogGroup -Group 'test') -eq 3
    }
    It 'a group counts only the installs that actually failed' {
        $script:failing = @('beta')
        (Install-CatalogGroup -Group 'test') -eq 1
    }
    It 'the failure count is a plain number, not a pipeline of leftovers' {
        # Install-CatalogItem is called for its return value; if anything else in the group
        # loop leaks to the pipeline the caller gets an array and `-eq 0` starts lying.
        $script:failing = @('alpha')
        $r = Install-CatalogGroup -Group 'test'
        (@($r).Count -eq 1) -and ($r -is [int])
    }
}

Write-Host "`n== schema_version is validated, not merely stored ==" -ForegroundColor Cyan

$realCatalogPath = Get-CatalogPath
$script:CatalogOverride = $null
function Get-CatalogPath {
    if ($script:CatalogOverride) { return $script:CatalogOverride }
    return $realCatalogPath
}
function New-TempCatalog {
    param([string]$Json)
    $p = Join-Path $scratch ("catalog-" + [guid]::NewGuid().ToString('N') + ".json")
    Set-Content -LiteralPath $p -Value $Json -Encoding UTF8
    return $p
}

It 'the shipped catalog.json is accepted' {
    # Positive control: a validator that rejects everything is as useless as one that
    # rejects nothing, and this one gates every install in the repo.
    $script:CatalogOverride = $null
    @((Get-Catalog).tools).Count -gt 0
}
It 'the shipped catalog.json declares the schema version this code implements' {
    $script:CatalogOverride = $null
    [int](Get-Catalog).schema_version -eq $script:CatalogSchemaVersion
}
It 'a catalog with an UNKNOWN schema_version is REJECTED' {
    # A future reshape deserialises perfectly well: every field this installer asks for comes
    # back $null and tools are silently skipped, with no error anywhere. That is why the
    # version has to be compared and not just carried.
    $script:CatalogOverride = New-TempCatalog '{ "schema_version": 99, "tools": [], "machine_scope_ids": ["x"] }'
    $rejected = $false
    try { Get-Catalog | Out-Null } catch { $rejected = $_.Exception.Message -match 'schema_version' }
    $script:CatalogOverride = $null
    $rejected
}
It 'a catalog with NO schema_version at all is REJECTED' {
    $script:CatalogOverride = New-TempCatalog '{ "tools": [], "machine_scope_ids": ["x"] }'
    $rejected = $false
    try { Get-Catalog | Out-Null } catch { $rejected = $_.Exception.Message -match 'schema_version' }
    $script:CatalogOverride = $null
    $rejected
}

Write-Host "`n== consent-facing descriptions must match what is installed ==" -ForegroundColor Cyan

It 'cli-tools_desc names every tool in the cli-tools catalog group' {
    # This string is printed by 'bootstrap.ps1 -List' and by get.ps1, i.e. BEFORE the user
    # agrees to anything. It listed 13 tools while the group held 15, hiding pwsh - a
    # MACHINE-scope install that prompts for elevation - and curl-libressl.
    $desc = cli-tools_desc
    $script:CatalogOverride = $null
    $missing = @()
    foreach ($t in (Get-CatalogTools -Group 'cli-tools')) {
        # A tool may be named in the description by catalog name or by binary (git-delta is
        # listed as "delta", which is what the user actually types).
        $names = @($t.name, $t.binary) | Where-Object { $_ }
        if (-not (@($names | Where-Object { $desc -match ('(^|[\s,])' + [regex]::Escape($_) + '([\s,]|$)') }).Count)) {
            $missing += $t.name
        }
    }
    if ($missing.Count) { Write-Host ("       not named in cli-tools_desc: " + ($missing -join ', ')) -ForegroundColor DarkYellow }
    $missing.Count -eq 0
}

Write-Host "`n== manifest provenance is measured, not assumed ==" -ForegroundColor Cyan

$securityPs1 = Join-Path $repoRoot 'modules\security.ps1'
$securityAst = [System.Management.Automation.Language.Parser]::ParseFile($securityPs1, [ref]$null, [ref]$null)
$addCalls = @($securityAst.FindAll({
    param($n)
    ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Add-WinManifest')
}, $true))

It 'every Add-WinManifest call in modules\security.ps1 states its provenance' {
    # Add-WinManifest's -InstalledByToolbox DEFAULTS TO $true, so omitting it records a tool
    # the toolbox merely DETECTED as one the toolbox installed. uninstall-toolbox.ps1
    # -RemoveWingetTools then acts on that claim: install_method 'existing' protects
    # Ghidra/poolmon/npcap, but WinDbg is recorded as 'winget' and would really be
    # uninstalled. Install-CatalogItem gets this right by probing first; these did not.
    $silent = @($addCalls | Where-Object {
        -not ($_.CommandElements | Where-Object {
            ($_ -is [System.Management.Automation.Language.CommandParameterAst]) -and
            ($_.ParameterName -eq 'InstalledByToolbox')
        })
    })
    if ($silent.Count) {
        foreach ($c in $silent) { Write-Host ("       line {0}: {1}" -f $c.Extent.StartLineNumber, $c.GetCommandName()) -ForegroundColor DarkYellow }
    }
    ($addCalls.Count -ge 5) -and ($silent.Count -eq 0)
}

It 'no manifest note ships an escaped literal backtick' {
    # `` inside a double-quoted PowerShell string emits ONE LITERAL BACKTICK, so the cdb
    # entry used to put  -c '`.logopen out.txt; ...'  into the manifest: a command that dies
    # on paste with "The term '`.logopen' is not recognized". lib\common.ps1 carries the same
    # sentence in a here-string and gets it right.
    $notes = @()
    foreach ($c in $addCalls) {
        for ($i = 0; $i -lt $c.CommandElements.Count - 1; $i++) {
            $e = $c.CommandElements[$i]
            if (($e -is [System.Management.Automation.Language.CommandParameterAst]) -and ($e.ParameterName -eq 'Notes')) {
                $notes += $c.CommandElements[$i + 1].Extent.Text
            }
        }
    }
    $broken = @($notes | Where-Object { $_ -match '``' })
    ($notes.Count -ge 5) -and ($broken.Count -eq 0)
}

It 'Add-WinManifest records provenance verbatim and does NOT execute the detect string' {
    # Two things at once, because they were one line apart. The version-scraping block ran
    # Invoke-Expression on every tool's detect string on every bootstrap - a process launch
    # per tool - to fill an installed_version field that nothing has ever read.
    $marker = Join-Path $scratch 'detect-ran.txt'
    Remove-Item -LiteralPath $marker, $script:MANIFEST -Force -ErrorAction SilentlyContinue
    $detect = "Set-Content -LiteralPath '$marker' -Value ran -Encoding ASCII"
    Add-WinManifest -Name 'probe' -Binary 'probe' -Group 'test' -Method 'existing' `
        -Detect $detect -InstalledByToolbox:$false
    $entry = Get-Content -LiteralPath $script:MANIFEST -Raw -Encoding UTF8 | ConvertFrom-Json
    (-not (Test-Path -LiteralPath $marker)) -and
        ($entry.installed_by_toolbox -eq $false) -and
        ($entry.detect -eq $detect)
}

It 'a re-run cannot disown a tool the toolbox installed' {
    # Every caller establishes provenance by probing BEFORE installing, so on the
    # second bootstrap run the tool is already there and the probe honestly reports
    # "pre-existing" about something the toolbox itself installed. If that were
    # written through, uninstall-toolbox.ps1 -RemoveWingetTools would stop removing
    # it - the toolbox would leak every tool it had ever installed, one re-run later.
    Remove-Item -LiteralPath $script:MANIFEST -Force -ErrorAction SilentlyContinue
    Add-WinManifest -Name 'ours' -Binary 'ours' -Group 'test' -Method 'winget' -Detect '' -InstalledByToolbox:$true
    Add-WinManifest -Name 'ours' -Binary 'ours' -Group 'test' -Method 'winget' -Detect '' -InstalledByToolbox:$false
    $e = @(Get-Content -LiteralPath $script:MANIFEST -Raw -Encoding UTF8 | ConvertFrom-Json)
    ($e.Count -eq 1) -and ($e[0].installed_by_toolbox -eq $true)
}
It 'a detected tool is still recorded as detected on a re-run' {
    # The other direction has to keep working, or "sticky" just means "always true".
    Remove-Item -LiteralPath $script:MANIFEST -Force -ErrorAction SilentlyContinue
    Add-WinManifest -Name 'theirs' -Binary 'theirs' -Group 'test' -Method 'existing' -Detect '' -InstalledByToolbox:$false
    Add-WinManifest -Name 'theirs' -Binary 'theirs' -Group 'test' -Method 'existing' -Detect '' -InstalledByToolbox:$false
    $e = @(Get-Content -LiteralPath $script:MANIFEST -Raw -Encoding UTF8 | ConvertFrom-Json)
    ($e.Count -eq 1) -and ($e[0].installed_by_toolbox -eq $false)
}

Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n== a failure has to reach the LAST line, not just the group's line ==" -ForegroundColor Cyan
# Install-CatalogGroup was made to return a count, and the three modules were made to print
# "INCOMPLETE" - and the count then died there. Write-Err is Write-Host, so it produces no
# error record; bootstrap.ps1 discarded the (absent) return value and printed "bootstrap
# complete" unconditionally, having no exit statement on any path at all. A run in which every
# single winget install failed still ended "OK bootstrap complete".
#
# Source-level assertions on purpose: the behavioural version would have to make real installs
# fail, and these pin exactly the two links that were missing.

It 'every <group>_install returns its failure count' {
    $bad = @()
    foreach ($m in @('cli-tools', 'extras', 'security')) {
        $f = Join-Path $repoRoot ('modules\' + $m + '.ps1')
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq ($m + '_install') }, $true) | Select-Object -First 1
        if (-not $fn) { $bad += "$m has no ${m}_install"; continue }
        $ret = $fn.Body.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.ReturnStatementAst] }, $true)
        if (-not $ret -or $ret.Count -eq 0) { $bad += "$m never returns" }
    }
    if ($bad.Count) { Write-Host ("       " + ($bad -join '; ')) -ForegroundColor DarkGray }
    $bad.Count -eq 0
}
It 'bootstrap.ps1 exits explicitly, on BOTH the success and failure paths' {
    # It previously fell off the end with no exit at all, so it inherited the exit code of
    # whatever native command it last happened to run - which is precisely why
    # fresh-toolbox-setup-runner.ps1 had to stop trusting it.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repoRoot 'bootstrap.ps1'), [ref]$null, [ref]$null)
    $exits = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'exit' }, $true)
    # PowerShell parses `exit N` as a statement, not a command, so match the source instead.
    $src = Get-Content (Join-Path $repoRoot 'bootstrap.ps1') -Raw
    ($src -match '(?m)^\s*exit 0\s*$') -and ($src -match '(?m)^\s*exit 1\s*$')
}
It 'and it accumulates what the groups return' {
    $src = Get-Content (Join-Path $repoRoot 'bootstrap.ps1') -Raw
    ($src -match 'GROUP_FAILURES') -and ($src -match 'GROUP_FAILURES\s*\+=')
}

if (-not (Assert-SUSuiteFloor -SuiteFile $PSCommandPath -Ran ($script:Pass + $script:Fail))) { $script:Fail++ }
Show-SUGuardSummary
Write-Host ("`n{0} passed, {1} failed`n" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })
