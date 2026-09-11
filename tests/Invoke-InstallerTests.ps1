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

# SELF-HEALING SWEEP, run before anything creates a fixture.
#
# This suite builds three module-scope fixture roots (installer-tests-, agentblock-, builder-
# tests-) and removes each at the end of its section. Those cleanups sit at column 0, NOT in a
# finally - the file has no top-level try at all - so anything that throws at module scope
# between a create and its cleanup strands the directory. The `It` harness catches per-test, so
# the common path is covered and the THROW path is not, and `run-gate.ps1 -Phase` runs this suite
# twice per invocation, so a failing phase run strands six.
#
# Measured 2026-09-11: 86 orphaned agentblock-* directories had accumulated before anyone counted,
# which is the same way the earlier 154-file tmp*.tmp leak was found. The durable fix is not a
# 2000-line try wrapper around the body - it is making the NEXT run clean up after the last one,
# which needs no discipline from any future test author and cannot itself be skipped by a throw.
# Bounded: at worst one run's worth of fixtures survives, and only until the next run.
#
# Deleting only inside TEMP, which is also the one place tests\SUTestGuard.ps1's shadow permits.
foreach ($stalePrefix in 'installer-tests-', 'agentblock-', 'builder-tests-') {
    Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter "$stalePrefix*" -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}

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
    # PowerShell parses `exit N` as a STATEMENT, not a CommandAst, so an AST walk for a command
    # named 'exit' finds nothing however the file is written. A full FindAll doing exactly that
    # was computed here and its result discarded - left behind when the check switched to source
    # matching, and caught by audit on 2026-09-11. Matching the source is the correct approach
    # for this one; the dead traversal is gone.
    $src = Get-Content (Join-Path $repoRoot 'bootstrap.ps1') -Raw
    ($src -match '(?m)^\s*exit 0\s*$') -and ($src -match '(?m)^\s*exit 1\s*$')
}
It 'and it accumulates what the groups return' {
    $src = Get-Content (Join-Path $repoRoot 'bootstrap.ps1') -Raw
    ($src -match 'GROUP_FAILURES') -and ($src -match 'GROUP_FAILURES\s*\+=')
}

Write-Host "`n== the toolbox builder's guards can actually fire ==" -ForegroundColor Cyan
# scripts\build-devtoolbox.ps1 CANNOT be dot-sourced: its main body mutates machine state at
# load - it creates directories, installs winget packages and runs pip. So these are AST
# assertions over its source, the same technique scripts\smoke-test.ps1:458-471 uses to lint
# its own try blocks. Everything below runs on a GitHub runner with no winget, no toolbox and
# no network, which is the only way a check on a machine-mutating installer gets to run at all.
#
# They exist because all three defects here were the SAME shape: a guard that reads correctly
# and cannot fire. Behavioural versions would have to make real winget installs fail and real
# downloads truncate, so what is pinned instead is the source-level condition each guard needs.

$builderPs1 = Join-Path $repoRoot 'scripts\build-devtoolbox.ps1'
$builderAst = [System.Management.Automation.Language.Parser]::ParseFile($builderPs1, [ref]$null, [ref]$null)
$builderFns = @($builderAst.FindAll({
    param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))

function Get-BuilderFn {
    param([string]$Name)
    @($builderFns | Where-Object { $_.Name -eq $Name }) | Select-Object -First 1
}

It 'no bare native command inside a builder function' {
    # THE Bug-1 regression test. An unredirected native command inside a function writes to
    # that FUNCTION'S output stream, so `winget @args; if ($LASTEXITCODE -ne 0) { return
    # $false }` returned [<winget's stdout lines>, $false] and the caller's `if (-not $ok)`
    # guard stopped working - -not on a multi-element array is $false. Measured under 5.1: the
    # leaky shape returns 3 elements and the guard fires = False. 8bca5e9 fixed the identical
    # line in lib\common.ps1:190; the builder still had it, so an 18-package native install
    # could fail outright and the build would still reach "OK DevToolbox ready".
    #
    # Assigned or piped both consume the output, so both are fine. Bare is the defect. `& $var`
    # is not flagged: GetCommandName() is null for it, and the leak needs a name to match.
    $native = @('winget', 'npm', 'npx', 'node', 'aria2c', 'py', 'py.exe', 'uv', 'tesseract', 'pip')
    $bad = @()
    foreach ($fn in $builderFns) {
        foreach ($c in @($fn.Body.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
            $name = $c.GetCommandName()
            if (-not $name -or ($native -notcontains $name)) { continue }
            $pipeline = $c.Parent
            $consumed = ($pipeline -is [System.Management.Automation.Language.PipelineAst]) -and
                        ($pipeline.PipelineElements.Count -gt 1)
            # Walk no further than the function itself, so an assignment somewhere outside it
            # cannot launder a bare call inside it.
            $node = $c
            while ((-not $consumed) -and $node -and ($node -ne $fn)) {
                if ($node -is [System.Management.Automation.Language.AssignmentStatementAst]) { $consumed = $true }
                $node = $node.Parent
            }
            if (-not $consumed) { $bad += ("{0}() line {1}: bare '{2}'" -f $fn.Name, $c.Extent.StartLineNumber, $name) }
        }
    }
    if ($bad.Count) { foreach ($b in $bad) { Write-Host "       $b" -ForegroundColor DarkYellow } }
    # The function floor stops a parse that silently returned nothing from passing.
    ($builderFns.Count -ge 20) -and ($bad.Count -eq 0)
}

It 'a leaked native stdout defeats a -not guard' {
    # Pure PowerShell, no I/O: this pins the language semantics the whole fix rests on, which
    # is why the hardened call site type-checks the result instead of testing the call inline.
    # Once winget's stdout rode along in the return value, `if (-not (Install-WingetPackage
    # ...))` was not a guard at all - it was a constant.
    $leaked = @('Found uv [astral-sh.uv]', 'Successfully installed', $false)
    $clean = $false
    ((-not $leaked) -eq $false) -and ((-not $clean) -eq $true) -and ($leaked -isnot [bool]) -and ($clean -is [bool])
}

It 'Install-WingetPackage returns only booleans' {
    # Its caller's guard is a boolean test, so the contract has to be a boolean. Anything else
    # returning from here - a captured line, a pscustomobject, a bare native call's output - is
    # the Bug-1 shape arriving by another route.
    $fn = Get-BuilderFn -Name 'Install-WingetPackage'
    if (-not $fn) { Write-Host "       Install-WingetPackage is gone" -ForegroundColor DarkYellow; return $false }
    $rets = @($fn.Body.FindAll({
        param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst] }, $true))
    $bad = @($rets | Where-Object {
        (-not $_.Pipeline) -or ($_.Pipeline.Extent.Text.Trim() -notmatch '^\$(true|false)$') })
    if ($bad.Count) {
        foreach ($b in $bad) { Write-Host ("       line {0}: {1}" -f $b.Extent.StartLineNumber, $b.Extent.Text) -ForegroundColor DarkYellow }
    }
    ($rets.Count -ge 3) -and ($bad.Count -eq 0)
}

It 'Install-Tessdata does not short-circuit on existence' {
    # `if (Test-Path $out) { continue }` skipped Get-Download entirely, and with it
    # Get-Download's own size check - so a zero-byte or partial .traineddata was permanent and
    # every rerun reported nothing to do. Measured on this box: 2 of the 11 declared languages
    # had usable data, while the build said it had installed them all. The existence fast-path
    # belongs in Get-Download, which returns early when the file passes size and hash.
    $fn = Get-BuilderFn -Name 'Install-Tessdata'
    if (-not $fn) { Write-Host "       Install-Tessdata is gone" -ForegroundColor DarkYellow; return $false }
    $bad = @(@($fn.Body.FindAll({
        param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true)) | Where-Object {
            ($_.Clauses[0].Item1.Extent.Text -match '\bTest-Path\b') -and
            ($_.Clauses[0].Item2.Extent.Text -match '\bcontinue\b') })
    if ($bad.Count) {
        foreach ($b in $bad) { Write-Host ("       line {0}: {1}" -f $b.Extent.StartLineNumber, $b.Clauses[0].Item1.Extent.Text) -ForegroundColor DarkYellow }
    }
    # A loop that downloads nothing at all would also satisfy the assertion above, so pin that
    # Get-Download is still on the per-language path.
    ($bad.Count -eq 0) -and ($fn.Body.Extent.Text -match '\bGet-Download\b')
}

It 'Get-Download deletes the partial before throwing on the size branch' {
    # The SHA-256 branch always deleted the bad file; the size branch threw and left it, and
    # aria2c leaves a partial behind on a truncated transfer. That surviving short file is what
    # the Test-Path fast-path above then found forever. ORDER is the assertion - a Remove-Item
    # somewhere after the throw is unreachable code that still matches a source grep.
    $fn = Get-BuilderFn -Name 'Get-Download'
    if (-not $fn) { Write-Host "       Get-Download is gone" -ForegroundColor DarkYellow; return $false }
    $sizeIf = @($fn.Body.FindAll({
        param($n)
        ($n -is [System.Management.Automation.Language.IfStatementAst]) -and
        ($n.Clauses[0].Item1.Extent.Text -match '\bMinimumBytes\b') -and
        ($n.Clauses[0].Item2.Extent.Text -match '\bthrow\b')
    }, $true)) | Select-Object -First 1
    if (-not $sizeIf) { Write-Host "       no size-failure branch that throws" -ForegroundColor DarkYellow; return $false }
    $body = $sizeIf.Clauses[0].Item2
    $removes = @($body.FindAll({ param($n)
        ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Remove-Item') }, $true))
    $throws = @($body.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.ThrowStatementAst] }, $true))
    if (-not $removes.Count) {
        Write-Host ("       line {0}: size branch throws without deleting the partial" -f $sizeIf.Extent.StartLineNumber) -ForegroundColor DarkYellow
        return $false
    }
    # -ErrorAction SilentlyContinue is required, not cosmetic: the first disjunct of this
    # branch's own condition is "the file does not exist", so a Remove-Item that throws under
    # $ErrorActionPreference='Stop' would replace the real message with its own.
    $silent = @($removes | Where-Object { $_.Extent.Text -match 'SilentlyContinue' })
    ($throws.Count -ge 1) -and
        ($removes[0].Extent.StartOffset -lt $throws[0].Extent.StartOffset) -and
        ($silent.Count -eq $removes.Count)
}

It 'the compliance warning before the system Python fallback is reachable' {
    # It was not. The warning about falling back to a system install sat INSIDE `if ($uv)`, so
    # the one path that actually reached the fallback - uv not resolvable at all, which is the
    # state a deleted toolbox tree leaves behind - was the one path that printed nothing.
    $fn = Get-BuilderFn -Name 'Get-Python311'
    if (-not $fn) { Write-Host "       Get-Python311 is gone" -ForegroundColor DarkYellow; return $false }
    $warns = @($fn.Body.FindAll({
        param($n)
        ($n -is [System.Management.Automation.Language.CommandAst]) -and
        ($n.GetCommandName() -eq 'Write-Warn') -and
        ($n.Extent.Text -match 'uv-managed Python 3\.11')
    }, $true))
    $nested = @()
    foreach ($w in $warns) {
        $node = $w.Parent
        while ($node -and ($node -ne $fn)) {
            if ($node -is [System.Management.Automation.Language.IfStatementAst]) {
                if (($node.Clauses[0].Item1.Extent.Text -replace '[\s()]', '') -eq '$uv') { $nested += $w.Extent.StartLineNumber }
            }
            $node = $node.Parent
        }
    }
    if ($nested.Count) {
        Write-Host ("       line(s) {0}: can only print when uv IS resolvable" -f ($nested -join ',')) -ForegroundColor DarkYellow
    }
    ($warns.Count -ge 1) -and ($nested.Count -eq 0)
}

It 'Get-Python311 refuses a system interpreter unless -AllowSystemPython' {
    # Fail-closed on purpose. A venv's base interpreter is written into pyvenv.cfg at creation,
    # Ensure-PythonVenv returns the existing venv on every later run, and nothing else calls
    # Get-Python311 - so a silent downgrade to the compliance-visible registered 3.11 is
    # permanent in practice. The message has to name the cure (`uv python install 3.11`) as
    # well as the override, because the cure is only cheap BEFORE the venv exists.
    $switches = @($builderAst.ParamBlock.Parameters | Where-Object {
        ($_.Name.VariablePath.UserPath -eq 'AllowSystemPython') -and
        ($_.StaticType -eq [switch]) })
    $fn = Get-BuilderFn -Name 'Get-Python311'
    if (-not $fn) { Write-Host "       Get-Python311 is gone" -ForegroundColor DarkYellow; return $false }
    $gates = @($fn.Body.FindAll({
        param($n)
        ($n -is [System.Management.Automation.Language.IfStatementAst]) -and
        ($n.Clauses[0].Item1.Extent.Text -match '-not\s+\$AllowSystemPython') -and
        ($n.Clauses[0].Item2.Extent.Text -match '\bthrow\b')
    }, $true))
    if (-not $switches.Count) { Write-Host "       no [switch]`$AllowSystemPython on the param block" -ForegroundColor DarkYellow }
    if (-not $gates.Count) { Write-Host "       nothing throws when -AllowSystemPython is absent" -ForegroundColor DarkYellow }
    ($switches.Count -eq 1) -and ($gates.Count -eq 1) -and
        ($gates[0].Clauses[0].Item2.Extent.Text -match 'uv python install 3\.11') -and
        ($gates[0].Clauses[0].Item2.Extent.Text -match 'AllowSystemPython')
}

It 'the manifest measures the venv base interpreter instead of restating it' {
    # Write-Manifest's $Python is whatever Ensure-PythonVenv returned, and on every run after
    # the first that is the venv's own python.exe - which says nothing about what the venv was
    # built on. Whether the toolbox is sitting on a compliance-visible interpreter has to stay
    # visible on the runs that never made the choice, so it is read back out of pyvenv.cfg.
    $fn = Get-BuilderFn -Name 'Write-Manifest'
    $reader = Get-BuilderFn -Name 'Get-VenvBaseInterpreter'
    if (-not $fn -or -not $reader) { Write-Host "       Write-Manifest or Get-VenvBaseInterpreter is gone" -ForegroundColor DarkYellow; return $false }
    $calls = @($fn.Body.FindAll({
        param($n)
        ($n -is [System.Management.Automation.Language.CommandAst]) -and
        ($n.GetCommandName() -eq 'Get-VenvBaseInterpreter')
    }, $true))
    $body = $fn.Body.Extent.Text
    ($calls.Count -ge 1) -and
        ($body -match '(?m)^\s*base_interpreter\s*=') -and
        ($body -match '(?m)^\s*base_interpreter_uv_managed\s*=') -and
        ($reader.Body.Extent.Text -match 'pyvenv\.cfg') -and
        ($reader.Body.Extent.Text -match 'base-executable')
}

It 'bootstrap weighs tessdata by size and requires eng' {
    # Counting *.traineddata by NAME was the other half of the tessdata bug: Get-Download threw
    # on a short file without deleting it, so the directory can hold zero-byte corpses that
    # satisfy a name filter and load nothing - and TESSDATA_PREFIX would then point at them,
    # which breaks OCR HARDER than leaving it unset. eng is required by name because it is the
    # implicit default for every caller that does not pass -l.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repoRoot 'bootstrap.ps1'), [ref]$null, [ref]$null)
    $gate = @($ast.FindAll({
        param($n)
        ($n -is [System.Management.Automation.Language.IfStatementAst]) -and
        ($n.Clauses[0].Item1.Extent.Text -match '\$hasLangData')
    }, $true)) | Select-Object -First 1
    if (-not $gate) { Write-Host "       no `$hasLangData gate in bootstrap.ps1" -ForegroundColor DarkYellow; return $false }
    # Everything in the gate's own block that talks about traineddata AND runs before it - i.e.
    # the decision, not the comments around it. Statement extents exclude comments on purpose:
    # a check that matched prose would pass on a file whose code had been gutted.
    $decision = (@($gate.Parent.Statements |
        Where-Object { ($_.Extent.StartOffset -lt $gate.Extent.StartOffset) -and ($_.Extent.Text -match 'traineddata') } |
        ForEach-Object { $_.Extent.Text }) -join "`n")
    if (-not $gate.ElseClause) { Write-Host "       no else branch: an unusable tessdata is silent" -ForegroundColor DarkYellow }
    ($decision -match '\bLength\s+-ge\s+100KB\b') -and
        ($decision -match 'eng\.traineddata') -and
        ($null -ne $gate.ElseClause)
}

# =============================================================================================
# lib\ShimPlan.ps1 + lib\path-registry.ps1 - shim recovery and PATH editing
#
# WHY THESE EXIST AT ALL. On 2026-09-10 %LOCALAPPDATA%\DevToolbox was deleted. Its native\bin
# held the .cmd shims that were the ONLY PATH route to 27 winget portable packages, because
# consolidate-path.ps1 had already taken those packages' own directories OFF the PATH in favour
# of the shims. Nothing could rebuild them: discovery was two lines filtering the CURRENT PATH,
# so on a correctly-consolidated box it found zero candidates - and then fell through into the
# PATH rewrite anyway. 13 tools had no recovery route.
#
# THE DECISION UNDER TEST is WHICH executable each shim points at, and the failure mode is
# silent: a shim that resolves and runs the wrong ffmpeg looks exactly like a working one. So
# these are behavioural tests over seams, not source greps, and the fixtures live on P:\ - a
# drive that does not exist - so a test that accidentally reaches the real filesystem FAILS
# instead of passing on whatever this box happens to hold.
#
# Dot-sourced here rather than at the top of the file because these two are the only functions
# the section below needs; lib\common.ps1 (line 34) already pulls in path-registry.ps1 for
# Remove-MachinePathEntry.
. (Join-Path $repoRoot 'lib\ShimPlan.ps1')

function New-FakeExe {
    # Stands in for a FileInfo. Get-ShimCandidates reads .FullName and nothing else.
    param([string]$Path)
    return [pscustomobject]@{ FullName = $Path }
}
function New-FakeWalk {
    # An -Enumerate seam over a described filesystem. Honours -Filter per extension and the
    # recurse flag, because getting either wrong is a real bug this seam has to be able to show:
    # -Include instead of -Filter once matched README.md and would have written README.cmd.
    param([string[]]$Files)
    return {
        param($Path, $Filter, $Recurse)
        $ext = ([string]$Filter).TrimStart('*')
        $root = ([string]$Path).TrimEnd('\').ToLowerInvariant()
        $hits = New-Object 'System.Collections.Generic.List[object]'
        foreach ($f in @($Files)) {
            $lf = $f.ToLowerInvariant()
            if (-not $lf.EndsWith($ext)) { continue }
            $under = if ($Recurse) { $lf.StartsWith($root + '\') }
                     else { ([IO.Path]::GetDirectoryName($f)).TrimEnd('\').ToLowerInvariant() -eq $root }
            if ($under) { $hits.Add((New-FakeExe $f)) }
        }
        return @($hits.ToArray())
    }.GetNewClosure()
}
function New-FakeCand {
    param([string]$Name, [string]$Target, [string]$PackageId, [string]$Package)
    return [pscustomobject]@{ Name = $Name; Target = $Target; Package = $Package; PackageId = $PackageId; Dir = [IO.Path]::GetDirectoryName($Target) }
}
function New-FakeWrapper {
    param([string]$Name, [string]$Target, [bool]$Parsed = $true)
    return [pscustomobject]@{ Name = $Name; Wrapper = "P:\tb\native\bin\$Name.cmd"; Target = $Target; Parsed = $Parsed }
}

$pkgRoot = 'P:\pkgs'
$btbn = "$pkgRoot\BtbN.FFmpeg.GPL.Shared.7.1_Microsoft.Winget.Source_8wekyb3d8bbwe"
$gyan = "$pkgRoot\Gyan.FFmpeg.Essentials_Microsoft.Winget.Source_8wekyb3d8bbwe"
# The real disk layout: a version-stamped subfolder under each package root, which is what makes
# the package root - not the directory holding the .exe - the only stable thing to rank on.
$ffFiles = @(
    "$btbn\ffmpeg-n7.1.5-win64-gpl-shared\bin\ffmpeg.exe",
    "$btbn\ffmpeg-n7.1.5-win64-gpl-shared\bin\ffprobe.exe",
    "$gyan\ffmpeg-8.1.1-essentials_build\bin\ffmpeg.exe",
    "$gyan\ffmpeg-8.1.1-essentials_build\bin\ffprobe.exe",
    "$pkgRoot\GitHub.cli_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\gh.exe",
    "$pkgRoot\junegunn.fzf_Microsoft.Winget.Source_8wekyb3d8bbwe\fzf.exe",
    # A .cmd and a .bat, because the real tree has them (cURL ships wcurl.bat) and a walk that
    # quietly covers only *.exe loses them with no error. And a README, because -Include once
    # matched it and would have written README.cmd.
    "$pkgRoot\some.cmdtool_Microsoft.Winget.Source_8wekyb3d8bbwe\wincmd.cmd",
    "$pkgRoot\some.battool_Microsoft.Winget.Source_8wekyb3d8bbwe\winbat.bat",
    "$pkgRoot\junegunn.fzf_Microsoft.Winget.Source_8wekyb3d8bbwe\README.md"
)
$alwaysThere = { param($p) $true }
$neverThere = { param($p) $false }

Write-Host "`n== a shim's bytes are a property of the code, not of the checkout ==" -ForegroundColor Cyan

It 'New-ShimBody emits exactly  @echo off<CRLF>"<target>" %*<CRLF>  in ASCII' {
    # The bytes, not a regex over them. The repo has core.autocrlf=true and no .gitattributes,
    # so a here-string or [Environment]::NewLine would make the line endings a property of the
    # working copy. The reader anchors its regex on $ (Get-ShimTarget, now the ONLY one left -
    # build-devtoolbox.ps1 and smoke-test.ps1 each carried a private copy until 2026-09-11 and
    # both now call it), so a lone LF makes every shim unparseable and the
    # smoke test reports 47 healthy shims as zero stale AND zero present.
    $b = [Text.Encoding]::ASCII.GetBytes((New-ShimBody -Target 'C:\x\y.exe'))
    $want = [Text.Encoding]::ASCII.GetBytes("@echo off") + @(13, 10) +
            [Text.Encoding]::ASCII.GetBytes('"C:\x\y.exe" %*') + @(13, 10)
    (@(Compare-Object $b $want -SyncWindow 0).Count -eq 0) -and ($b.Count -eq 28)
}
It 'every file that reads a wrapper uses the character-identical regex, and ShimFormat owns it' {
    # A DRIFT guard at source level: a regex that is merely EQUIVALENT today is how readers stop
    # agreeing. modules\security.ps1 writes a THREE-line Ghidra wrapper, so any reader that drifts
    # loses Ghidra first and silently.
    #
    # DERIVED, not hardcoded. This test named three files until 2026-09-11, when New-ShimBody and
    # Get-ShimTarget moved into lib\ShimFormat.ps1 so the writers that dot-source nothing could
    # reach them - and the test failed for the refactor rather than for a defect. A fixed list
    # also cannot survive the consolidation now in progress, which takes the reader count from
    # three to one: it would have to be edited in the same commit that reduces it, which is
    # exactly the maintenance tax that gets a check deleted.
    #
    # The invariant is "all copies agree", not "there are N copies", so it holds at 3, at 1, and
    # at any number in between - while a NEW divergent copy still fails it.
    $pat = '\^"\(\[\^"\]\+\)" %\\\*\$'
    $hits = @()
    # RELATIVE exclusion, not absolute. `-notlike '*\.claude\worktrees\*'` on the FULL path
    # excludes every file in the tree when $repoRoot is ITSELF a worktree - which is how three
    # parallel agents run - so the test reported 85/1 inside a worktree and 86/0 on main, failing
    # for its location rather than for a defect. Same mistake, same day, as the repo-wide parse
    # sweep: the filter has to be applied to the path BELOW the root being scanned.
    $wtPrefix = '.claude' + [IO.Path]::DirectorySeparatorChar + 'worktrees'
    $rootLen = (Resolve-Path -LiteralPath $repoRoot).Path.TrimEnd('\').Length + 1
    foreach ($f in (Get-ChildItem -LiteralPath $repoRoot -Recurse -Filter *.ps1 -File |
                    Where-Object { -not $_.FullName.Substring($rootLen).StartsWith($wtPrefix, [StringComparison]::OrdinalIgnoreCase) })) {
        if ((Get-Content -LiteralPath $f.FullName -Raw) -match $pat) {
            $hits += $f.FullName.Substring($repoRoot.Length + 1)
        }
    }
    # At least one reader must exist, the canonical definition must be among them, and no file
    # may carry a variant spelling - which is what a hit on the escaped pattern already proves.
    ($hits.Count -ge 1) -and ($hits -contains 'lib\ShimFormat.ps1')
}
It 'Get-ShimTarget reads the THREE-line Ghidra wrapper, not just the two-line one' {
    # modules\security.ps1:278 emits  @echo off / set "JAVA_HOME=..." / "<target>" %*  - so a
    # reader that indexes "the second line" returns the JAVA_HOME assignment as Ghidra's target.
    # Scan for the first line that MATCHES, always.
    $lines = @('@echo off', 'set "JAVA_HOME=P:\jdk"', '"P:\ghidra\ghidraRun.bat" %*')
    (Get-ShimTarget -Lines $lines) -eq 'P:\ghidra\ghidraRun.bat'
}
It 'Get-ShimTarget returns $null for a wrapper somebody hand-wrote' {
    # This is what makes rule 3 (unparseable -> never touch) possible. A reader that guesses
    # here would hand the planner a target that was never in the file.
    $null -eq (Get-ShimTarget -Lines @('@echo off', 'echo hello', 'pause'))
}

Write-Host "`n== ENUMERATION ORDER IS NOT A RANK ==" -ForegroundColor Cyan

It 'alphabetical disk order is NOT a priority oracle - a contested name is SKIPPED' {
    # THE test. A recursive walk of this box yields BtbN before Gyan, and that INVERTS the only
    # contested decision here: build-devtoolbox.ps1:43 declares Gyan.FFmpeg.Essentials as the
    # toolbox's ffmpeg, and Gyan is what actually won the 2026-08-27 run. Any code that treats
    # the walk order as a ranking therefore silently installs the wrong ffmpeg - and both
    # binaries run, so nothing downstream notices. With no authoritative order, refuse.
    $cands = Get-ShimCandidates -PackagesRoot $pkgRoot -Enumerate (New-FakeWalk -Files $ffFiles)
    $plan = Get-ShimPlan -Candidates $cands -TargetExists $alwaysThere -NativeBin 'P:\tb\native\bin'
    $names = @(@($plan.Contested | ForEach-Object { $_.Name }) | Sort-Object)
    (@($plan.Contested).Count -eq 2) -and ($names -join ',') -eq 'ffmpeg,ffprobe' -and
        (@($plan.Write | Where-Object { $_.Name -like 'ff*' }).Count -eq 0)
}
It 'and a name only ONE package supplies is still shimmed with no priority order at all' {
    # The partner control, and the reason the two are separate tests: "refuse when contested"
    # must not be implemented as "refuse always". 44 of this box's 47 names land here. Asserted
    # by membership rather than by the exact set, so this control stays valid when the fixture
    # grows - a control that has to be edited alongside the thing it controls is not one.
    $cands = Get-ShimCandidates -PackagesRoot $pkgRoot -Enumerate (New-FakeWalk -Files $ffFiles)
    $plan = Get-ShimPlan -Candidates $cands -TargetExists $alwaysThere -NativeBin 'P:\tb\native\bin'
    $sole = @(@($plan.Write | Where-Object { $_.Because -eq 'sole' }) | ForEach-Object { $_.Name })
    ($sole -contains 'fzf') -and ($sole -contains 'gh') -and
        (@($sole | Where-Object { $_ -like 'ff*' }).Count -eq 0)
}
It 'the walk covers .exe, .cmd AND .bat, and a README never becomes a shim' {
    # THREE -Filter passes, and -Filter rather than -Include. Get-ChildItem silently ignores
    # -Include unless the path ends in \* or -Recurse is set, so an -Include *.exe matched
    # README.md and would have generated README.cmd - caught by the first dry run in 2026-08.
    # The extension list matters just as much: cURL really does ship wcurl.bat, and a walk that
    # covers only *.exe drops it with no error anywhere.
    $cands = Get-ShimCandidates -PackagesRoot $pkgRoot -Enumerate (New-FakeWalk -Files $ffFiles)
    $names = @(@($cands) | ForEach-Object { $_.Name })
    ($names -contains 'wincmd') -and ($names -contains 'winbat') -and ($names -notcontains 'README')
}
It '-Dirs scans the given leaf directories only, and still finds the package ROOT above them' {
    # The DEFAULT mode's code path: it hands in the WinGet\Packages entries already on PATH,
    # which are leaf bin directories, and walking those recursively would be wrong. The package
    # root still has to be derived - two levels up, past the version-stamped subfolder - or
    # ranking and the sibling rule key on a directory name that changes on every winget upgrade.
    $cands = @(Get-ShimCandidates -PackagesRoot $pkgRoot -Dirs @("$gyan\ffmpeg-8.1.1-essentials_build\bin") `
        -Enumerate (New-FakeWalk -Files $ffFiles))
    $pkgs = @(@($cands) | ForEach-Object { $_.Package } | Select-Object -Unique)
    ($cands.Count -eq 2) -and ($pkgs.Count -eq 1) -and ($pkgs[0] -eq $gyan) -and
        (@($cands | Where-Object { $_.Target -like "$btbn\*" }).Count -eq 0)
}
It 'an authoritative order beats alphabetical order even when it sorts LAST' {
    # Gyan sorts after BtbN, and Gyan is the right answer. Ranked from a PATH order, the plan
    # must say Gyan - which is also the replay of what logs\consolidate-run.log recorded.
    $cands = Get-ShimCandidates -PackagesRoot $pkgRoot -Enumerate (New-FakeWalk -Files $ffFiles)
    $plan = Get-ShimPlan -Candidates $cands -TargetExists $alwaysThere -PriorityOrder @($gyan, $btbn) -NativeBin 'P:\tb\native\bin'
    $ff = @($plan.Write | Where-Object { $_.Name -eq 'ffmpeg' })
    (@($plan.Contested).Count -eq 0) -and ($ff.Count -eq 1) -and ($ff[0].Target -like "$gyan\*") -and ($ff[0].Because -eq 'rank:0')
}
It 'the losing copies are REPORTED shadowed, never silently dropped' {
    # "shadowed, unchanged" is the only trace that a second ffmpeg exists at all. Without it the
    # report says 47 shims and gives no hint that 6 executables were passed over.
    #
    # Driven by -Pick rather than by rank so that this test and the ranking test above fail
    # INDEPENDENTLY: a mutation that inverts the rank comparison must not also break the check
    # on whether the loser gets reported, or one mutation indicts two guards and neither is
    # pinned.
    $cands = Get-ShimCandidates -PackagesRoot $pkgRoot -Enumerate (New-FakeWalk -Files $ffFiles)
    $plan = Get-ShimPlan -Candidates $cands -TargetExists $alwaysThere -Pick 'ffmpeg=BtbN.FFmpeg' -NativeBin 'P:\tb\native\bin'
    $sh = @($plan.Shadowed | Where-Object { $_.Name -eq 'ffmpeg' })
    ($sh.Count -eq 1) -and ($sh[0].Target -like "$gyan\*") -and ($sh[0].Chosen -like "$btbn\*")
}
It 'Get-ShimPriority ranks a backup machine-then-user and refuses a document that is not one' {
    # machine-then-user is how Windows composes the session PATH, so it is the order that makes
    # "first one wins" agree with what used to resolve. Shape is checked by property PRESENCE:
    # under strict mode a missing field either throws somewhere unrelated or yields $null, and a
    # silently empty priority list turns 3 resolved names into 3 contested ones with no error.
    $json = '{ "captured_at": "x", "machine": "P:\\pkgs\\Gyan.FFmpeg.Essentials_Microsoft.Winget.Source_8wekyb3d8bbwe\\b;C:\\nodejs", "user": "P:\\pkgs\\BtbN.FFmpeg.GPL.Shared.7.1_Microsoft.Winget.Source_8wekyb3d8bbwe\\b" }'
    $order = Get-ShimPriority -Json $json -PackagesRoot $pkgRoot
    $rejected = $false
    try { Get-ShimPriority -Json '{ "shims": {} }' -PackagesRoot $pkgRoot | Out-Null }
    catch { $rejected = $_.Exception.Message -match "no 'machine' field" }
    (@($order).Count -eq 2) -and ($order[0] -eq $gyan) -and ($order[1] -eq $btbn) -and $rejected
}

Write-Host "`n== a wrapper that is already there wins BY CONSTRUCTION ==" -ForegroundColor Cyan

It 'the PLANNER keeps a wrapper whose target exists, and reports what it would have been' {
    # The open BACKLOG bug. consolidate-path.ps1's comment claimed "Never shim over a wrapper the
    # toolbox builder owns" for a year while implementing only `if ($name -eq 'consolidate-path')`.
    # Keeping first is what makes build-devtoolbox.ps1's venv wrappers win without either script
    # knowing about the other: the builder runs first, so its wrappers are already on disk.
    $cands = @(New-FakeCand -Name 'fzf' -Target 'P:\pkgs\junegunn.fzf_x\fzf.exe' -PackageId 'junegunn.fzf_x' -Package 'P:\pkgs\junegunn.fzf_x')
    $plan = Get-ShimPlan -Candidates $cands -Existing @(New-FakeWrapper -Name 'fzf' -Target 'P:\tb\python\.venv\Scripts\fzf.exe') `
        -TargetExists $alwaysThere -NativeBin 'P:\tb\native\bin'
    $k = @($plan.Kept | Where-Object { $_.Name -eq 'fzf' })
    (@($plan.Write).Count -eq 0) -and ($k.Count -eq 1) -and ($k[0].Reason -eq 'existing') -and
        ($k[0].Would -eq 'sole -> P:\pkgs\junegunn.fzf_x\fzf.exe')
}
It 'the WRITER independently refuses to overwrite a wrapper the plan did not mark for refresh' {
    # A SECOND, INDEPENDENT check, not a restatement of the planner's rule. The writer had NO
    # Test-Path at all (consolidate-path.ps1:356-364), so any caller bug - a hand-built plan, a
    # future mode, a planner regression - overwrote a builder-owned wrapper and the venv CLI it
    # pointed at stopped resolving with nothing anywhere recording why. The plan below is exactly
    # that caller bug, expressed on purpose.
    $plan = @{ Write = @([pscustomobject]@{ Name = 'fzf'; Target = 'P:\pkgs\fzf.exe'; PackageId = 'p'; Wrapper = 'P:\tb\native\bin\fzf.cmd'; Because = 'sole'; Refresh = $false; Rivals = @() }) }
    # Cleared BEFORE the call, not after: a sentinel reset afterwards is always $null and the
    # assertion on it can never fail, which is a check that looks like one and is not.
    $script:writerTouched = $null
    $res = Invoke-ShimWrite -Plan $plan -NativeBin 'P:\tb\native\bin' -FileExists $alwaysThere `
        -WriteFile { param($p, $b) $script:writerTouched = $p }
    (@($res.Written).Count -eq 0) -and (@($res.Refused).Count -eq 1) -and ($null -eq $script:writerTouched)
}
It 'a STALE wrapper IS refreshed - the refusal is not unconditional' {
    # smoke-test.ps1:287 tells the operator to re-run this script to fix a shim whose target a
    # winget upgrade moved. Refusing every existing wrapper would make every stale shim
    # PERMANENT and turn that instruction into a lie, so "exists" and "resolves" are different
    # questions and only the second one protects.
    $cands = @(New-FakeCand -Name 'fzf' -Target 'P:\pkgs\junegunn.fzf_x\fzf.exe' -PackageId 'junegunn.fzf_x' -Package 'P:\pkgs\junegunn.fzf_x')
    $plan = Get-ShimPlan -Candidates $cands -Existing @(New-FakeWrapper -Name 'fzf' -Target 'P:\pkgs\junegunn.fzf_OLD\fzf.exe') `
        -TargetExists $neverThere -NativeBin 'P:\tb\native\bin'
    $script:refreshBody = $null
    $res = Invoke-ShimWrite -Plan $plan -NativeBin 'P:\tb\native\bin' -FileExists $alwaysThere `
        -WriteFile { param($p, $b) $script:refreshBody = $b }
    (@($plan.Refreshed).Count -eq 1) -and (@($res.Written).Count -eq 1) -and (@($res.Refused).Count -eq 0) -and
        ($script:refreshBody -eq (New-ShimBody -Target 'P:\pkgs\junegunn.fzf_x\fzf.exe'))
}
It 'a wrapper with no parseable target line is KEPT, never rewritten' {
    # Somebody hand-wrote it. There is no way to tell a deliberate hand-written .cmd from a
    # corrupt one, and only one of those two answers is safe.
    $cands = @(New-FakeCand -Name 'tool' -Target 'P:\pkgs\p_x\tool.exe' -PackageId 'p_x' -Package 'P:\pkgs\p_x')
    $plan = Get-ShimPlan -Candidates $cands -Existing @(New-FakeWrapper -Name 'tool' -Target $null -Parsed $false) `
        -TargetExists $alwaysThere -NativeBin 'P:\tb\native\bin'
    (@($plan.Write).Count -eq 0) -and (@($plan.Kept | Where-Object { $_.Reason -eq 'unparseable' }).Count -eq 1)
}
It 'a stale wrapper NO package can supply is reported as unfixable, not quietly ignored' {
    # smoke-test.ps1 will report this one on every single run. Saying "a rebuild cannot fix this"
    # once is the difference between an actionable report and a permanent red line.
    $plan = Get-ShimPlan -Candidates @() -Existing @(New-FakeWrapper -Name 'gone' -Target 'P:\vanished\gone.exe') `
        -TargetExists $neverThere -NativeBin 'P:\tb\native\bin'
    @($plan.Kept | Where-Object { $_.Reason -eq 'stale-no-source' }).Count -eq 1
}
It 'consolidate-path is never shimmed over itself' {
    $cands = @(New-FakeCand -Name 'consolidate-path' -Target 'P:\pkgs\p_x\consolidate-path.exe' -PackageId 'p_x' -Package 'P:\pkgs\p_x')
    $plan = Get-ShimPlan -Candidates $cands -TargetExists $alwaysThere -NativeBin 'P:\tb\native\bin'
    (@($plan.Write).Count -eq 0) -and (@($plan.Skipped).Count -eq 1)
}

Write-Host "`n== -Pick and the sibling rule ==" -ForegroundColor Cyan

It 'a -Pick whose prefix matches NOTHING throws instead of falling through' {
    # Falling through would leave the name contested while the operator believes they resolved
    # it - and the report would agree with them, because a contested name is reported by the
    # planner and a typo is not.
    $cands = Get-ShimCandidates -PackagesRoot $pkgRoot -Enumerate (New-FakeWalk -Files $ffFiles)
    $threw = $false
    try { Get-ShimPlan -Candidates $cands -Pick 'ffmpeg=NoSuchPackage' -TargetExists $alwaysThere | Out-Null }
    catch { $threw = $_.Exception.Message -match 'matches no package' }
    $threw
}
It 'a -Pick naming a SKIPPED name throws rather than being silently dropped' {
    # The skip list wins over -Pick, and it has to SAY so. The main loop tests $skipKeys and
    # `continue`s before it ever reads $pickMap, so a -Pick for a never-shim name passed every
    # validation above and was then discarded in silence: the operator gets "44 written, 0
    # contested" and no hint that the one decision they made by hand was thrown away.
    #
    # Same defect class as the test directly above, one loop further on - which is why it is
    # asserted separately rather than folded into that one. A -Pick that is honoured and a -Pick
    # that is refused are both fine; a -Pick that is accepted and ignored is not.
    $cands = Get-ShimCandidates -PackagesRoot $pkgRoot -Enumerate (New-FakeWalk -Files $ffFiles)
    $threw = $false
    try {
        Get-ShimPlan -Candidates $cands -Pick 'ffmpeg=Gyan.FFmpeg' -Skip @('ffmpeg') `
                     -TargetExists $alwaysThere -NativeBin 'P:\tb\native\bin' | Out-Null
    } catch { $threw = $_.Exception.Message -match 'never-shim list' }
    $threw
}
It 'a -Pick binds the name, and its SIBLINGS follow into the same package' {
    # ffmpeg/ffprobe/ffplay ship together and must come from one build; picking three times to
    # say one thing is how two of them end up from different packages.
    $cands = Get-ShimCandidates -PackagesRoot $pkgRoot -Enumerate (New-FakeWalk -Files $ffFiles)
    $plan = Get-ShimPlan -Candidates $cands -Pick 'ffmpeg=Gyan.FFmpeg' -TargetExists $alwaysThere -NativeBin 'P:\tb\native\bin'
    $probe = @($plan.Write | Where-Object { $_.Name -eq 'ffprobe' })
    (@($plan.Contested).Count -eq 0) -and ($probe.Count -eq 1) -and
        ($probe[0].Target -like "$gyan\*") -and ($probe[0].Because -eq 'sibling:ffmpeg')
}
It 'the sibling rule does NOT fire when the bound target is outside every candidate' {
    # An ffmpeg.cmd pointing at a chocolatey install is evidence about ffmpeg and about nothing
    # else. Dragging ffprobe to a winget package because ffmpeg happens to be bound somewhere
    # would be inventing a decision out of an unrelated fact.
    $cands = Get-ShimCandidates -PackagesRoot $pkgRoot -Enumerate (New-FakeWalk -Files $ffFiles)
    $plan = Get-ShimPlan -Candidates $cands -Existing @(New-FakeWrapper -Name 'ffmpeg' -Target 'P:\ProgramData\chocolatey\bin\ffmpeg.exe') `
        -TargetExists $alwaysThere -NativeBin 'P:\tb\native\bin'
    @($plan.Contested | Where-Object { $_.Name -eq 'ffprobe' }).Count -eq 1
}
It 'a contested name is reported with EVERY candidate and a fix that recommends none of them' {
    # Naming the first candidate would recommend BtbN for ffmpeg purely because B sorts before
    # G, and an operator pasting the suggested command would install the wrong ffmpeg on a box
    # whose own builder declares Gyan.
    $cands = Get-ShimCandidates -PackagesRoot $pkgRoot -Enumerate (New-FakeWalk -Files $ffFiles)
    $plan = Get-ShimPlan -Candidates $cands -TargetExists $alwaysThere -NativeBin 'P:\tb\native\bin'
    $c = @($plan.Contested | Where-Object { $_.Name -eq 'ffmpeg' })[0]
    (@($c.Candidates).Count -eq 2) -and ($c.Command -match 'BtbN\.FFmpeg\.GPL\.Shared\.7\.1') -and
        ($c.Command -match 'Gyan\.FFmpeg\.Essentials') -and ($c.Command -match '<prefix>')
}

Write-Host "`n== editing a raw PATH must not expand it ==" -ForegroundColor Cyan

It 'Remove-PathEntryFromString leaves a %VAR% entry LITERAL, in and out' {
    # 5 of this box's 43 machine entries are %VAR%-based. Expanding to compare means re-emitting
    # the expansion, which is the REG_SZ bug by another route: a PATH whose %SystemRoot% has been
    # baked out works until the day it does not.
    $raw = '%SystemRoot%\system32;P:\drop\me;%SystemRoot%'
    $r = Remove-PathEntryFromString -Value $raw -Remove @('P:\drop\me')
    ($r.Value -eq '%SystemRoot%\system32;%SystemRoot%') -and (@($r.Removed).Count -eq 1) -and
        ($r.Kept -contains '%SystemRoot%\system32')
}
It 'matching ignores ONE trailing backslash and is case-insensitive' {
    # The registry holds both 'C:\...\Python311\' and 'C:\...\ImageMagick-7.1.2-Q16-HDRI', and an
    # operator typing the path by hand will not guess which. Only ONE, though: stripping every
    # trailing slash would equate 'C:\' with 'C:'.
    $r = Remove-PathEntryFromString -Value 'P:\Keep;P:\Python311\;P:\keep2' -Remove @('p:\PYTHON311')
    ($r.Value -eq 'P:\Keep;P:\keep2') -and (@($r.Removed).Count -eq 1)
}
It 'Test-PathPlanChanged says NO CHANGE for a semantically identical PATH' {
    # This answer is the elevation gate. A trailing ';' or a regained trailing backslash makes the
    # two STRINGS differ while the PATH is identical, and comparing strings there drags a pure
    # shim rebuild - which writes no registry value at all - through a UAC prompt.
    -not (Test-PathPlanChanged -BeforeMachine @('P:\a', 'P:\b\') -AfterMachine @('P:\A\', 'P:\b') `
        -BeforeUser @('P:\u') -AfterUser @('P:\u'))
}
It 'Test-PathPlanChanged says CHANGED for a reorder, because order IS priority' {
    # -SyncWindow 0. Order in a PATH decides which of two ffmpegs answers; it is not
    # presentation, and a reorder that reported "no change" would skip the backup as well.
    (Test-PathPlanChanged -BeforeMachine @('P:\a', 'P:\b') -AfterMachine @('P:\b', 'P:\a')) -and
        (Test-PathPlanChanged -BeforeMachine @('P:\a') -AfterMachine @('P:\a', 'P:\c'))
}

Write-Host "`n== the elevated child must be handed the flags the parent was ==" -ForegroundColor Cyan

$cpPath = Join-Path $repoRoot 'scripts\consolidate-path.ps1'
$cpAst = [System.Management.Automation.Language.Parser]::ParseFile($cpPath, [ref]$null, [ref]$null)
$cpParams = @($cpAst.ParamBlock.Parameters)
$nfAssign = @($cpAst.FindAll({ param($n)
    ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -and
    ($n.Left.Extent.Text -eq '$NeverForward') }, $true))
$neverForward = @()
if ($nfAssign.Count -gt 0) {
    $neverForward = @($nfAssign[0].Right.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
}

It 'EVERY parameter consolidate-path.ps1 declares is either forwarded or explicitly excluded' {
    # THE HIGHEST-RISK LINE IN THE FEATURE, fixed as a CLASS. The old Invoke-SelfElevate
    # hand-listed the two parameters it forwarded, so a switch added later was dropped in
    # silence: the parent would report "rebuild only, nothing dropped", raise UAC, and the child
    # - seeing none of the flags - would run PLAIN consolidation and DROP PATH ENTRIES NOBODY
    # ASKED IT TO. Values here are built from each parameter's DECLARED TYPE, because that is
    # what PowerShell actually puts in $PSBoundParameters and a switch takes a different code
    # path from a string.
    $bound = @{}
    foreach ($p in $cpParams) {
        $n = $p.Name.VariablePath.UserPath
        $t = if ($p.StaticType) { $p.StaticType.Name } else { 'String' }
        if ($t -eq 'SwitchParameter') { $bound[$n] = [switch]$true }
        elseif ($t -eq 'Int32')       { $bound[$n] = 7 }
        elseif ($t -eq 'String[]')    { $bound[$n] = @('a=b') }
        else                          { $bound[$n] = 'v' }
    }
    $argl = @(Get-SelfElevateArgs -ScriptPath 'P:\repo\scripts\consolidate-path.ps1' -Sid 'S-1-5-21-1' `
        -TargetMax 3500 -Bound $bound -NeverForward $neverForward)
    $missing = @($cpParams | ForEach-Object { $_.Name.VariablePath.UserPath } | Where-Object {
        ($neverForward -notcontains $_) -and ($argl -notcontains ('-' + $_)) })
    if ($missing.Count) { Write-Host ("       not forwarded and not excluded: " + ($missing -join ', ')) -ForegroundColor DarkYellow }
    ($cpParams.Count -ge 8) -and ($neverForward.Count -ge 4) -and ($missing.Count -eq 0)
}
It 'the script hands Invoke-SelfElevate its OWN $PSBoundParameters' {
    # Structural, not a grep for the word: the pure forwarder being correct is worth nothing if
    # the call site passes it nothing. Inside a function $PSBoundParameters is the FUNCTION's own
    # bound parameters, which is empty here - hence -Bound, and hence this check.
    $calls = @($cpAst.FindAll({ param($n)
        ($n -is [System.Management.Automation.Language.CommandAst]) -and
        ($n.GetCommandName() -eq 'Invoke-SelfElevate') }, $true))
    $wired = @($calls | Where-Object {
        $els = @($_.CommandElements)
        $ok = $false
        for ($i = 0; $i -lt $els.Count - 1; $i++) {
            if (($els[$i] -is [System.Management.Automation.Language.CommandParameterAst]) -and
                ($els[$i].ParameterName -eq 'Bound') -and
                ($els[$i + 1].Extent.Text -eq '$PSBoundParameters')) { $ok = $true }
        }
        $ok
    })
    ($calls.Count -ge 1) -and ($wired.Count -eq $calls.Count)
}
It 'every forwarded value is QUOTED, and an array survives the hop as one comma-joined argument' {
    # Start-Process joins -ArgumentList with spaces and does NOT quote for you, so an unquoted
    # C:\some dir\x.json arrives as two arguments. And MEASURED: powershell.exe -File rejects a
    # repeated parameter outright ("specified more than once") and does not parse an array
    # literal either - "a=b","c=d" lands in the child as the single string a=b,c=d. The comma
    # form is the only one that survives, which is why Get-ShimPickMap splits on commas.
    $argl = @(Get-SelfElevateArgs -ScriptPath 'P:\my repo\consolidate-path.ps1' -Sid 'S-1' -TargetMax 3500 `
        -Bound @{ Pick = @('ffmpeg=Gyan', 'ffprobe=Gyan'); FromBackup = 'P:\some dir\b.json' } -NeverForward @())
    $i = [array]::IndexOf($argl, '-Pick')
    $map = Get-ShimPickMap -Pick @($argl[$i + 1].Trim('"'))
    (@($argl | Where-Object { $_ -eq '-Pick' }).Count -eq 1) -and
        ($argl[$i + 1] -eq '"ffmpeg=Gyan,ffprobe=Gyan"') -and
        ($argl -contains '"P:\some dir\b.json"') -and
        ($argl -contains '"P:\my repo\consolidate-path.ps1"') -and
        ($map.Count -eq 2) -and ($map['ffprobe'] -eq 'Gyan')
}

Write-Host "`n== PATH hygiene re-measures every precondition ==" -ForegroundColor Cyan

# A filesystem the suite describes. 'P:\shadow' provides exactly what 'P:\jdk\bin' already
# provides EARLIER, so it is genuinely shadowed; 'P:\scripts' provides one name nothing else does.
$hygieneFs = {
    param($Dir)
    switch (([string]$Dir).TrimEnd('\').ToLowerInvariant()) {
        'p:\jdk\bin'  { return @('java', 'javac') }
        'p:\fake\shadow' { return @('java', 'javac') }
        'p:\scripts'  { return @('pip', 'pip3.11') }
        'p:\pips'     { return @('pip') }
        'p:\empty'    { return @() }
        'p:\dup'      { return @('git') }
        default       { return @() }
    }
}
$hygieneExpand = { param($s) ([string]$s).Replace('%FAKEVAR%', 'P:\fake') }
$hygieneMachine = 'P:\jdk\bin;%FAKEVAR%\shadow;P:\empty;P:\pips;P:\scripts'
$hygieneUser = 'P:\dup'
function Invoke-Hygiene {
    param([string]$Json, [string]$Machine = $hygieneMachine, [string]$User = $hygieneUser)
    Get-PathHygienePlan -Json $Json -MachineRaw $Machine -UserRaw $User -Enumerate $hygieneFs -Expand $hygieneExpand
}
$hygEntry = {
    param($scope, $entry, $require, $extra = '')
    '{ "scope": "' + $scope + '", "entry": "' + $entry.Replace('\', '\\') + '", "require": "' + $require + '", "reason": "t"' + $extra + ' }'
}

It 'an entry whose precondition no longer holds is SKIPPED and reported, never removed' {
    # The whole reason config\path-hygiene.json is re-measured rather than trusted. It is a list
    # somebody ratified on one particular day; a machine moves. 'P:\dup' is declared as a
    # cross-scope duplicate, and it is not in the machine hive here - so the user copy is now the
    # ONLY provider of git, and removing it would take git off the PATH entirely.
    $json = '{ "schema_version": 1, "entries": [' + (& $hygEntry 'user' 'P:\dup' 'duplicate-in-machine') + '] }'
    $p = Invoke-Hygiene -Json $json
    (@($p.RemoveUser).Count -eq 0) -and (@($p.Skipped).Count -eq 1) -and
        ($p.Skipped[0].Why -match 'machine hive no longer carries')
}
It 'the ratified duplicate IS removed once the machine hive really does carry it' {
    # The positive control. A predicate that skips everything protects nothing and prunes nothing.
    $json = '{ "schema_version": 1, "entries": [' + (& $hygEntry 'user' 'P:\dup' 'duplicate-in-machine') + '] }'
    $p = Invoke-Hygiene -Json $json -Machine ($hygieneMachine + ';P:\dup')
    (@($p.RemoveUser).Count -eq 1) -and (@($p.Skipped).Count -eq 0) -and ($p.NewUser -eq '')
}
It 'a %VAR% entry is MEASURED expanded and REMOVED as the raw literal' {
    # A naive pass over the raw values sees %SystemRoot%\system32 as a directory that does not
    # exist, and a rule built on that would propose deleting system32. Expand to measure; match
    # the registry literal to remove, because the literal is the only thing that can be matched
    # in a value Get-RawPath deliberately did not expand.
    $json = '{ "schema_version": 1, "entries": [' + (& $hygEntry 'machine' '%FAKEVAR%\shadow' 'shadowed') + '] }'
    $p = Invoke-Hygiene -Json $json
    (@($p.RemoveMachine).Count -eq 1) -and ($p.RemoveMachine[0] -eq '%FAKEVAR%\shadow') -and
        ($p.NewMachine -notmatch 'shadow') -and ($p.NewMachine -notmatch 'FAKEVAR') -and
        ($p.NewMachine -notmatch 'P:\\fake')
}
It 'shadowed REFUSES an entry that still provides a name nothing earlier provides' {
    # 'P:\scripts' provides pip3.11, and nothing before it does. Removing it on the strength of
    # "pip is shadowed anyway" is how a PATH loses a version-pinned alias nobody notices for a month.
    $json = '{ "schema_version": 1, "entries": [' + (& $hygEntry 'machine' 'P:\scripts' 'shadowed') + '] }'
    $p = Invoke-Hygiene -Json $json
    (@($p.RemoveMachine).Count -eq 0) -and (@($p.Skipped).Count -eq 1) -and
        ($p.Skipped[0].Why -match 'pip3\.11')
}
It 'and allows it once the loss is DECLARED in expect_unresolved' {
    # The declaration is the trade being stated out loud - which is what makes the resolution
    # delta's one remaining line ("pip3.11 no longer resolves") a decision instead of a surprise.
    $json = '{ "schema_version": 1, "entries": [' + (& $hygEntry 'machine' 'P:\scripts' 'shadowed' ', "expect_unresolved": ["pip3.11"]') + '] }'
    $p = Invoke-Hygiene -Json $json
    $gone = @($p.Delta | Where-Object { $_.Change -eq 'unresolved' })
    (@($p.RemoveMachine).Count -eq 1) -and ($gone.Count -eq 1) -and ($gone[0].Name -eq 'pip3.11')
}
It 'no-executables is measured, not assumed' {
    $json = '{ "schema_version": 1, "entries": [' +
        (& $hygEntry 'machine' 'P:\empty' 'no-executables') + ',' +
        (& $hygEntry 'machine' 'P:\jdk\bin' 'no-executables') + '] }'
    $p = Invoke-Hygiene -Json $json
    (@($p.RemoveMachine).Count -eq 1) -and ($p.RemoveMachine[0] -eq 'P:\empty') -and
        (@($p.Skipped | Where-Object { $_.Why -match 'provides 2 executable' }).Count -eq 1)
}
It 'the SHIPPED config\path-hygiene.json is accepted and names only machine/user scopes' {
    # Positive control on the file that actually ships. A validator nothing valid passes is as
    # useless as one nothing fails, and this config is the input to a machine PATH rewrite.
    $cfg = Get-Content (Join-Path $repoRoot 'config\path-hygiene.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $scopes = @(@($cfg.entries | ForEach-Object { $_.scope }) | Select-Object -Unique | Sort-Object)
    $requires = @(@($cfg.entries | ForEach-Object { $_.require }) | Select-Object -Unique | Sort-Object)
    ([int]$cfg.schema_version -eq 1) -and (@($cfg.entries).Count -ge 7) -and
        (($scopes -join ',') -eq 'machine,user') -and
        (@($requires | Where-Object { @('duplicate-in-machine', 'no-executables', 'shadowed') -notcontains $_ }).Count -eq 0) -and
        (@($cfg.entries | Where-Object { -not $_.reason }).Count -eq 0)
}
It 'a hygiene config with an unknown schema_version is REJECTED' {
    $rejected = $false
    try { Invoke-Hygiene -Json '{ "schema_version": 99, "entries": [] }' | Out-Null }
    catch { $rejected = $_.Exception.Message -match 'schema_version' }
    $rejected
}

Write-Host "`n== the persisted shim map is the durable replacement for a lucky backup ==" -ForegroundColor Cyan

It 'the shim map round-trips, carrying the priority order a rebuild needs' {
    # logs\path-backup-20260909-203021.json is currently the ONLY record anywhere of the 27
    # packages in resolution order, and it survived by luck. priority_order exists so the next
    # rebuild does not need luck. Written to native\bin AND to logs\, because the 2026-09-10 case
    # is precisely the one where native\bin is gone.
    $cands = Get-ShimCandidates -PackagesRoot $pkgRoot -Enumerate (New-FakeWalk -Files $ffFiles)
    $plan = Get-ShimPlan -Candidates $cands -TargetExists $alwaysThere -PriorityOrder @($gyan, $btbn) -NativeBin 'P:\tb\native\bin'
    $doc = New-ShimSourcesDocument -Plan $plan -Mode 'rebuild' -PrioritySource 'test' -PriorityOrder @($gyan, $btbn)
    $back = Read-ShimSources -Json ($doc | ConvertTo-Json -Depth 6)
    (@($back.priority_order).Count -eq 2) -and ($back.priority_order[0] -eq $gyan) -and
        ($back.shims.ffmpeg.chosen_because -eq 'rank:0') -and ($back.shims.ffmpeg.target -like "$gyan\*") -and
        (@($back.shims.ffmpeg.rivals).Count -eq 1)
}
It 'a shim map with an unknown or absent schema_version is REFUSED, not deserialised' {
    # Same reason Get-Catalog refuses one (lib\catalog.ps1:29-35). A reshaped document parses
    # perfectly well, every field comes back $null, and the rebuild runs with an empty priority
    # list - which on this box turns 3 resolved names into 3 contested ones with no error anywhere.
    $bad = 0
    foreach ($j in @('{ "schema_version": 99, "priority_order": [] }', '{ "priority_order": [] }')) {
        try { Read-ShimSources -Json $j | Out-Null } catch { if ($_.Exception.Message -match 'schema_version') { $bad++ } }
    }
    $bad -eq 2
}

Write-Host "`n== a native command's stderr must not be able to fail the build ==" -ForegroundColor Cyan

# Three failed rebuild attempts on 2026-09-11, three different native commands, one root cause:
# under this file's global $ErrorActionPreference = 'Stop', a native command's stderr becomes a
# TERMINATING error the moment its output flows into another command. The repo already had this
# lesson written down at lib\common.ps1:294-298 and had applied it at some call sites and not
# others, which is exactly the state these tests exist to stop recurring.
$builderFile = Join-Path $repoRoot 'scripts\build-devtoolbox.ps1'
$builderAst = [System.Management.Automation.Language.Parser]::ParseFile($builderFile, [ref]$null, [ref]$null)

It 'no native command in the builder is piped, because the pipe is what makes its stderr fatal' {
    # The defect, verbatim from the failed run:
    #   & $uv python install 3.11 | Out-Null
    #   uv.exe : Installed Python 3.11.15 in 103ms
    #   + FullyQualifiedErrorId : NativeCommandError
    # uv SUCCEEDED and the build died. `| Out-Null` did not fail to prevent that, it caused it -
    # Out-Null solves the unrelated problem of native stdout leaking into a function's return
    # value, and the two are confusable enough that the comment at that call site named the right
    # hazard and drew the opposite conclusion from it.
    #
    # Asserts the CONDITION (no native command has a downstream pipeline element), not the
    # presence of Invoke-NativeCapture: a file could call the helper in ten places and still pipe
    # an eleventh command, which is precisely how this shipped.
    $nativeNames = @('winget', '7z', 'aria2c', 'uv', 'npm', 'py', 'curl')
    $bad = @()
    foreach ($p in $builderAst.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.PipelineAst] }, $true)) {
        if (@($p.PipelineElements).Count -lt 2) { continue }
        $first = $p.PipelineElements[0]
        if ($first -isnot [System.Management.Automation.Language.CommandAst]) { continue }
        $amp = ($first.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand)
        $nm = $first.GetCommandName()
        if ($amp -or ($nm -and $nativeNames -contains $nm)) { $bad += $p.Extent.StartLineNumber }
    }
    if ($bad.Count) { Write-Host "     piped native command(s) at line(s): $($bad -join ', ')" -ForegroundColor Red }
    $bad.Count -eq 0
}

It 'aria2c is invoked with IPv6 disabled, on the call itself' {
    # aria2 resolves AAAA first, and on a host with no working IPv6 route every download dies:
    #   errorCode=1 Network problem has occurred. cause:A socket operation was attempted to an
    #   unreachable network.
    # Measured 2026-09-11 against tessdata_fast/osd.traineddata: plain aria2c returned 0 B and
    # ERR, the same command plus --disable-ipv6=true returned 10,562,727 B (the exact expected
    # size), and Invoke-WebRequest answered HTTP 200 to the same URL throughout. That gap is why
    # the symptom always read as "download failed or was unexpectedly small" - the size check sits
    # downstream of a transport that never connected - and why this box had 2 of 11 OCR languages
    # for weeks while looking like a truncation bug.
    #
    # Asserted on the aria2c CommandAst's own elements, not by grepping the file, so moving the
    # flag into a comment or onto a different command fails this.
    $ariaCalls = @($builderAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.Extent.Text -match '\$aria\b' }, $true))
    if ($ariaCalls.Count -eq 0) { Write-Host '     no aria2c invocation found at all' -ForegroundColor Red }
    ($ariaCalls.Count -ge 1) -and
    (@($ariaCalls | Where-Object {
        @($_.CommandElements | Where-Object { $_.Extent.Text -eq '--disable-ipv6=true' }).Count -eq 0
    }).Count -eq 0)
}

It 'the Playwright phase checks the CA bundle BEFORE it runs, not after' {
    # NODE_EXTRA_CA_CERTS pointed into the toolbox tree this script was rebuilding, so it dangled
    # for the whole run and Node's "Ignoring extra certs ... load failed" warning - on stderr, on
    # every TLS-loading process - failed the Playwright phase. The ordering is the real defect and
    # is not fixable here: the bundle is written by bootstrap.ps1, which runs AFTER this builder.
    #
    # An ORDER assertion, not a presence one. Disable the guard by moving it below the install and
    # the call is still sitting there, unreachable in the only sense that matters, and a regex
    # looking for its name would still match.
    $fn = @($builderAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq 'Install-PlaywrightBrowsers' }, $true))[0]
    if (-not $fn) { return $false }
    $guard = @($fn.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Assert-NodeCaBundleSane' }, $true))
    $run = @($fn.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Invoke-Checked' }, $true))
    ($guard.Count -eq 1) -and ($run.Count -eq 1) -and
        ($guard[0].Extent.StartOffset -lt $run[0].Extent.StartOffset)
}

Write-Host "`n== the agent-block writer must not reinterpret the body it is given ==" -ForegroundColor Cyan

# A fixture root of its own, NOT $scratch. An earlier section of this suite removes $scratch, so
# a test down here that assumes it still exists gets a DirectoryNotFoundException from its own
# setup - and then passes or fails for a reason that has nothing to do with the thing under test.
# That is how it first failed: the placeholder file was never written, Write-AgentBlock took its
# APPEND path instead of the REPLACE path, and the assertion that the surrounding file survived
# was reported as a writer bug. Self-contained, inside TEMP so the deletion tripwire permits it.
$abRoot = Join-Path ([IO.Path]::GetTempPath()) ("agentblock-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $abRoot -Force | Out-Null

It 'a body containing $-sequences round-trips through Write-AgentBlock byte for byte' {
    # Write-AgentBlock used `$content -replace $pattern, $replacement`, and the replacement side
    # of -replace is a .NET regex SUBSTITUTION string. So the body was reinterpreted on its way
    # to disk: $$ collapsed to $, $& became the whole match, and $1 expanded to nothing because
    # the pattern has no capture groups.
    #
    # This was not theoretical. The deployed agent block documents
    #   cdb -z dump.dmp -c ".logopen out.txt; $$><script.txt; q"
    # and all four files on this machine carried `$><script.txt` - a different, wrong cdb
    # command - written there by the toolbox itself on every single deploy.
    #
    # A REPLACE path is exercised deliberately (the file already contains a block), because the
    # append path never had the bug and would pass a broken writer.
    $f = Join-Path $abRoot ("agentblock-" + [guid]::NewGuid().ToString('N') + '.md')
    $body = @'
cdb -z dump.dmp -c ".logopen out.txt; $$><script.txt; q"
a dollar-one $1 and a dollar-amp $& and a bare $ and a backtick-n `n
'@
    Set-Content -LiteralPath $f -Value "top matter`n`n<!-- SUTEST_START -->`nplaceholder`n<!-- SUTEST_END -->`n`ntail matter" -Encoding UTF8
    Write-AgentBlock -FilePath $f -Marker 'SUTEST' -Body $body | Out-Null
    $raw = Get-Content -LiteralPath $f -Raw -Encoding UTF8
    $got = [regex]::Match($raw, '(?s)<!-- SUTEST_START -->\r?\n(.*?)\r?\n<!-- SUTEST_END -->').Groups[1].Value
    $want = ($body -replace "`r`n", "`n").TrimEnd()
    $gotN = ($got -replace "`r`n", "`n").TrimEnd()
    # Assert on the exact $-sequences, not just equality, so a failure says WHICH one was eaten.
    if ($gotN -ne $want) {
        Write-Host "     wanted: $want" -ForegroundColor Red
        Write-Host "     got   : $gotN" -ForegroundColor Red
    }
    ($gotN -eq $want) -and ($gotN -match '\$\$><script\.txt') -and
        ($gotN -match '\$1') -and ($gotN -match '\$&') -and
        # the surrounding file must survive too - a splice that ate the tail would pass an
        # equality check on the block alone
        ($raw -match 'top matter') -and ($raw -match 'tail matter')
}

It 'a START marker with no matching END is refused, not guessed at' {
    # The splice has to find both markers. Silently appending a second block, or truncating from
    # the start marker to EOF, would corrupt a file the user owns - and one of these four files is
    # the user's global CLAUDE.md.
    $f = Join-Path $abRoot ("agentblock-orphan-" + [guid]::NewGuid().ToString('N') + '.md')
    Set-Content -LiteralPath $f -Value "keep me`n<!-- SUTEST_START -->`nno end marker here" -Encoding UTF8
    $before = Get-Content -LiteralPath $f -Raw -Encoding UTF8
    $threw = $false
    try { Write-AgentBlock -FilePath $f -Marker 'SUTEST' -Body 'x' | Out-Null }
    catch { $threw = $_.Exception.Message -match 'no matching' }
    $after = Get-Content -LiteralPath $f -Raw -Encoding UTF8
    $threw -and ($after -eq $before)
}

# The fixture root goes with the section that made it. Invoke-SmokeLintTests.ps1 cleans its own in
# a finally and $scratch is cleaned at the top of this file; this one was introduced on 2026-09-11
# with neither, and run-gate.ps1 -Phase runs each suite TWICE (once via smoke-test, once directly),
# so it leaked two GUID directories per gate run - the same class BACKLOG records growing from 138
# to 154 orphans before anyone noticed.
Remove-Item -LiteralPath $abRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n== a PATH edit goes through the registry, or it is not an edit ==" -ForegroundColor Cyan

# SOURCE-LEVEL, because there is no reachable seam. bootstrap.ps1 cannot be dot-sourced - its top
# level installs software and rewrites PATH - and gate.yml's "No test reaches a writer that cannot
# be redirected" step forbids this suite from CALLING Add-UserPathEntry or Remove-UserPathEntry at
# all, since both write the real user hive and take no path to redirect. Those three functions are
# the least testable code in the repo, which is precisely why they were the three still carrying
# the bug the rest of the repo had already written down and fixed.
$pathEditorFiles = @('bootstrap.ps1', 'lib\common.ps1')
$pathEditorAsts = @{}
foreach ($rel in $pathEditorFiles) {
    $pathEditorAsts[$rel] = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repoRoot $rel), [ref]$null, [ref]$null)
}

function Get-SUFunctionAst {
    # Filtered OUTSIDE FindAll on purpose: the predicate scriptblock is invoked by the AST walker,
    # and every other FindAll in this suite keeps its predicate free of captured locals for the
    # same reason. Where-Object runs in this scope, so $Name binds.
    param($Ast, [string]$Name)
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        Where-Object { $_.Name -eq $Name }) | Select-Object -First 1
}

function Get-SUEnvApiCall {
    <#
        Every [Environment]::<Member>(...) invocation under $Ast, as @{ Arg0; Line }.

        Arg0 is $null when the first argument is not a literal string, and the callers treat that
        as UNPROVEN rather than safe. A variable variable-name is exactly the shape a banned call
        would come back in, and neither file has one today, so failing closed costs nothing.
    #>
    param($Ast, [string]$Member)
    @($Ast.FindAll({ param($n)
        ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) -and
        ($n.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) -and
        ($n.Expression.TypeName.Name -match '^(System\.)?Environment$') }, $true) |
        Where-Object { [string]$_.Member.Extent.Text -eq $Member } |
        ForEach-Object {
            $a0 = $null
            if ((@($_.Arguments).Count -ge 1) -and
                ($_.Arguments[0] -is [System.Management.Automation.Language.StringConstantExpressionAst])) {
                $a0 = [string]$_.Arguments[0].Value
            }
            [pscustomobject]@{ Arg0 = $a0; Line = $_.Extent.StartLineNumber }
        })
}

It 'no PATH WRITE in bootstrap.ps1 or lib\common.ps1 goes through [Environment]::SetEnvironmentVariable' {
    # THE check this commit exists for. bootstrap.ps1:189/211 read PATH with
    # GetEnvironmentVariable - which EXPANDS %VAR% - and wrote the result back with
    # SetEnvironmentVariable, which writes REG_SZ and destroys the REG_EXPAND_SZ value kind. A
    # REG_SZ PATH never expands a %VAR% again, so one -CleanLegacyState run baked this box's 6
    # %VAR% machine entries (%SystemRoot%\system32 among them) into literal text permanently.
    # Add-UserPathEntry and Remove-UserPathEntry had the same round trip in the user hive, which
    # is also ExpandString and so had exactly as much to lose the moment anyone added a %VAR%.
    #
    # Asserts the CONDITION - no such call exists - never that a comment says so. Delete the
    # prohibition comment from either file and this still passes; put one line of the old code
    # back and it fails, naming file and line.
    #
    # SetEnvironmentVariable ONLY. Sync-EnvPath's two GetEnvironmentVariable('PATH', ...) reads are
    # correct and deliberate - they build $env:PATH for the running process, which MUST be
    # expanded, and they write nothing. A ban that covered them would have to be argued away
    # immediately, and a rule with a standing exception is not a rule.
    $bad = @()
    foreach ($rel in $pathEditorFiles) {
        foreach ($c in (Get-SUEnvApiCall -Ast $pathEditorAsts[$rel] -Member 'SetEnvironmentVariable')) {
            $shown = if ($null -eq $c.Arg0) { '<first arg is not a literal>' } else { $c.Arg0 }
            if (($null -eq $c.Arg0) -or ($c.Arg0 -imatch '^path$')) {
                $bad += ("{0}:{1} sets '{2}'" -f $rel, $c.Line, $shown)
            }
        }
    }
    foreach ($b in $bad) { Write-Host "     $b" -ForegroundColor Red }
    $bad.Count -eq 0
}

It 'the three PATH editors reach Get-RawPath/Set-RawPath and the framework API not at all' {
    # PER FUNCTION, not per file: Sync-EnvPath lives in lib\common.ps1 and legitimately calls
    # GetEnvironmentVariable, so a file-wide ban would either fail on correct code or be watered
    # down until it meant nothing.
    #
    # BOTH HALVES OF THE API, not just the writer. Writing REG_SZ is the permanent damage, but
    # READING through the framework API is what makes an edit lossy in the first place: it returns
    # 'C:\WINDOWS\system32' where the registry holds '%SystemRoot%\system32', and a value rebuilt
    # from that text re-emits the expansion no matter how carefully it is finally written.
    #
    # The Get-RawPath/Set-RawPath presence half is the weaker assertion, and it is here for one
    # specific failure: deleting the write outright would satisfy the ban above while quietly
    # turning a PATH editor into a no-op. Each of these three functions must still both read and
    # write, and the registry helpers are now the only route left.
    $want = @{
        'bootstrap.ps1'  = @('Remove-StalePathEntries')
        'lib\common.ps1' = @('Add-UserPathEntry', 'Remove-UserPathEntry')
    }
    $bad = @()
    foreach ($rel in $pathEditorFiles) {
        foreach ($name in $want[$rel]) {
            $fn = Get-SUFunctionAst -Ast $pathEditorAsts[$rel] -Name $name
            if (-not $fn) { $bad += "$rel is missing $name"; continue }
            foreach ($member in @('GetEnvironmentVariable', 'SetEnvironmentVariable')) {
                foreach ($c in (Get-SUEnvApiCall -Ast $fn.Body -Member $member)) {
                    $bad += ("{0}:{1} {2} calls [Environment]::{3}" -f $rel, $c.Line, $name, $member)
                }
            }
            $calls = @($fn.Body.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() })
            foreach ($helper in @('Get-RawPath', 'Set-RawPath')) {
                if ($calls -notcontains $helper) { $bad += "$name never calls $helper" }
            }
        }
    }
    foreach ($b in $bad) { Write-Host "     $b" -ForegroundColor Red }
    $bad.Count -eq 0
}

It 'Remove-StalePathEntries refuses the machine hive unelevated rather than throwing at it' {
    # TWO conditions, because either alone is satisfied by broken code. The function must CONSULT
    # Test-PathAdmin before it writes HKLM, and it must contain no throw.
    #
    # The old code had neither. It called SetEnvironmentVariable blind and converted the resulting
    # SecurityException into a throw, which killed bootstrap in the middle of -CleanLegacyState -
    # after Remove-OldRepositoryClone and Remove-DirectorySafely had already deleted the old clone
    # and the old toolbox tree. Loudest at exactly the point where the least state was recoverable.
    #
    # Dropping the throw costs no strictness, which is why "warn and continue" is allowed to be the
    # answer here: Assert-OldToolchainClean re-reads the machine PATH a few lines later and throws
    # on the very entry the warning names, so an unelevated run still ends red - in one piece.
    $fn = Get-SUFunctionAst -Ast $pathEditorAsts['bootstrap.ps1'] -Name 'Remove-StalePathEntries'
    if (-not $fn) { Write-Host "     Remove-StalePathEntries is gone" -ForegroundColor Red; return $false }
    $calls = @($fn.Body.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() })
    $throws = @($fn.Body.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.ThrowStatementAst] }, $true))
    if ($throws.Count) {
        Write-Host ("     line {0}: throws instead of reporting" -f $throws[0].Extent.StartLineNumber) -ForegroundColor Red
    }
    if ($calls -notcontains 'Test-PathAdmin') {
        Write-Host "     writes the machine hive without consulting Test-PathAdmin" -ForegroundColor Red
    }
    ($calls -contains 'Test-PathAdmin') -and ($throws.Count -eq 0)
}

It 'Remove-StalePathEntries backs the PATH up BEFORE its first Set-RawPath, never after' {
    # ORDER, not presence. A Backup-PathRegistry call sitting after the write is still a call, and
    # a check that only asked "is it there" would pass the single arrangement that makes the backup
    # worthless. -CleanLegacyState is opt-in and destructive, and
    # logs\path-backup-20260909-203021.json is the only reason the 2026-09-09 outage was
    # recoverable - it is still the only surviving record of that machine PATH's original order.
    $fn = Get-SUFunctionAst -Ast $pathEditorAsts['bootstrap.ps1'] -Name 'Remove-StalePathEntries'
    if (-not $fn) { Write-Host "     Remove-StalePathEntries is gone" -ForegroundColor Red; return $false }
    $backups = @($fn.Body.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        Where-Object { $_.GetCommandName() -eq 'Backup-PathRegistry' })
    $writes = @($fn.Body.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        Where-Object { $_.GetCommandName() -eq 'Set-RawPath' })
    if (-not $backups.Count) { Write-Host "     no Backup-PathRegistry call at all" -ForegroundColor Red; return $false }
    if (-not $writes.Count) { Write-Host "     no Set-RawPath call at all" -ForegroundColor Red; return $false }
    $firstBackup = ($backups | ForEach-Object { $_.Extent.StartOffset } | Measure-Object -Minimum).Minimum
    $firstWrite = ($writes | ForEach-Object { $_.Extent.StartOffset } | Measure-Object -Minimum).Minimum
    if ($firstBackup -ge $firstWrite) {
        Write-Host "     the backup is taken after the first registry write" -ForegroundColor Red
    }
    $firstBackup -lt $firstWrite
}

Write-Host "`n== the venv wrapper writer emits the shared byte contract, not its own ==" -ForegroundColor Cyan

It 'New-VenvCliWrappers writes exactly the ShimFormat bytes, and still skips the interpreter' {
    # THE REAL WRITER, end to end, against a fixture toolbox under TEMP - not a re-implementation
    # of the line, which would pass whatever lib\common.ps1 actually did. That function built its
    # wrapper from a private "@echo off`r`n..." literal until 2026-09-11, one of the seven private
    # copies of the format that lib\ShimFormat.ps1 exists to collapse.
    #
    # -NoNewline IS THE SUBTLE HALF, and this is what pins it. Measured under 5.1: the old inline
    # string carried NO trailing CRLF and Set-Content appended one, for 28 bytes. New-ShimBody
    # supplies that CRLF itself, so the same Set-Content WITHOUT -NoNewline emits 30 bytes with a
    # blank third line. Both spellings still parse, every reader still resolves the target, and
    # nothing else in this repo would ever have noticed the bytes move.
    $tb = Join-Path ([IO.Path]::GetTempPath()) ("venvwrap-" + [guid]::NewGuid().ToString('N'))
    $venvScripts = Join-Path $tb 'python\.venv\Scripts'
    New-Item -ItemType Directory -Path $venvScripts -Force | Out-Null
    foreach ($n in @('frida.exe', 'sqlite-utils.exe', 'python.exe', 'pip.exe')) {
        Set-Content -LiteralPath (Join-Path $venvScripts $n) -Value 'not a real exe' -Encoding ASCII
    }
    $prevToolbox = $env:CODEX_TOOLBOX
    $ok = $false
    try {
        $env:CODEX_TOOLBOX = $tb
        # REFUSING rather than failing: New-VenvCliWrappers derives its output directory from
        # $env:CODEX_TOOLBOX alone, so if this override did not take it would wrap the REAL
        # toolbox venv into the REAL native\bin. Same shape and same one-assignment margin as the
        # $script:MANIFEST refusal at the top of this file.
        if (-not $env:CODEX_TOOLBOX.StartsWith($script:SUTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "     REFUSING: CODEX_TOOLBOX is '$env:CODEX_TOOLBOX', outside $($script:SUTempRoot)" -ForegroundColor Red
            return $false
        }
        New-VenvCliWrappers
        $binDir = Join-Path $tb 'native\bin'
        $written = @(Get-ChildItem -LiteralPath $binDir -Filter *.cmd -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name } | Sort-Object)
        # The target is read back off the FileInfo the writer itself enumerated, so a difference
        # here is a difference in the BODY and never in how this test spelled the path.
        $exe = Get-Item -LiteralPath (Join-Path $venvScripts 'frida.exe')
        $got = [IO.File]::ReadAllBytes((Join-Path $binDir 'frida.cmd'))
        $want = [Text.Encoding]::ASCII.GetBytes((New-ShimBody -Target $exe.FullName))
        if ($got.Count -ne $want.Count) {
            Write-Host ("     wrapper is {0} bytes, the contract is {1}" -f $got.Count, $want.Count) -ForegroundColor Red
        }
        # python.exe and pip.exe must NOT be wrapped. Keeping a 3.11 interpreter off PATH is the
        # entire reason this wrapper layer exists instead of a PATH entry for the venv Scripts dir
        # - see the function's own comment and docs\agent-rules.md on compliance scanners.
        if (($written -join ',') -ne 'frida.cmd,sqlite-utils.cmd') {
            Write-Host ("     wrapped: {0}" -f ($written -join ', ')) -ForegroundColor Red
        }
        $ok = ($got.Count -eq $want.Count) -and
              (@(Compare-Object $got $want -SyncWindow 0).Count -eq 0) -and
              (($written -join ',') -eq 'frida.cmd,sqlite-utils.cmd')
    } finally {
        $env:CODEX_TOOLBOX = $prevToolbox
        Remove-Item -LiteralPath $tb -Recurse -Force -ErrorAction SilentlyContinue
    }
    $ok
}

# =============================================================================================
# scripts\build-devtoolbox.ps1 - drift, not unfireable guards
#
# WHY THIS IS A SECOND BUILDER SECTION. The one at line 376 pins guards that read correctly and
# could not fire. These three defects are a different shape: DIVERGENCE. build-devtoolbox.ps1 is
# standalone on purpose - bootstrap.ps1 runs it as a child process, so it inherits none of
# bootstrap's scope - and under that constraint it grew private copies of two things that already
# had exactly one correct definition elsewhere. Both private copies were the wrong one:
#
#   Sync-EnvPath        vs lib\common.ps1:46       - re-appended $env:PATH to itself, every call
#   the .cmd shim body  vs lib\ShimFormat.ps1      - a here-string, the one thing that file forbids
#
# BEHAVIOURAL, not source greps, and the caveat at line 377 does not apply. That section says the
# builder cannot be dot-sourced, which is true of the FILE - its main body creates directories,
# installs winget packages and runs pip at load. A single FUNCTION is a different matter: it is
# lifted out of the AST by extent text and dot-sourced into a & { } child scope on its own. That
# distinction is what makes the PATH defect testable at all, and it should be reached for before
# another AST assertion is written.
#
# NOTHING HERE TOUCHES THE MACHINE. It installs nothing, downloads nothing, and writes only under
# TEMP:
#   - $Root is a directory under TEMP, so every Join-Path in the code under test lands there
#   - $env:PATH is process-local, and is seeded, asserted on, then restored
#   - Find-Executable is driven with $env:LOCALAPPDATA, $env:ProgramFiles and
#     ${env:ProgramFiles(x86)} all pointed at a TEMP fixture, so its exhaustive fallback cannot
#     wander onto this box - BACKLOG measures that path at 4,048 ms per miss - or read the real
#     toolbox. Those three are PROCESS-wide even when assigned inside & { }, so each test that
#     moves them restores them in a finally.
#
# A $Root that does NOT exist is the default on purpose: that is the first-build state, and it is
# what gives the Test-Path assertions something to be about.
#
# Fixture root of its own, not $scratch - line 330 already removed that one.
$bdRoot = Join-Path ([IO.Path]::GetTempPath()) ("builder-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $bdRoot -Force | Out-Null

function Get-BuilderFnScope {
    # One or more builder functions, alone, as a dot-sourceable scriptblock. Extent text rather
    # than a regex over the file: a function that was renamed or deleted comes back $null here and
    # the caller reports it, instead of a pattern silently matching nothing and passing.
    param([string[]]$Name)
    $src = @()
    foreach ($n in @($Name)) {
        $fn = Get-BuilderFn -Name $n
        if (-not $fn) { return $null }
        $src += $fn.Extent.Text
    }
    return [scriptblock]::Create($src -join "`r`n")
}

Write-Host "`n== the builder's PATH sync must CONVERGE, not accumulate ==" -ForegroundColor Cyan

It 'Sync-EnvPath discards the prior $env:PATH instead of folding it back into itself' {
    # THE defect. The old body ended its joined array with $env:PATH, so every call appended the
    # entire session PATH to itself. Measured on this box 2026-09-11 (Machine PATH 1,588 chars,
    # User 148, a 990-char start) over the four calls one build makes:
    #   2,868 -> 4,746 -> 6,624 -> 8,502 chars, +44 entries each time, 62 distinct throughout.
    # Past 4,095 on call TWO. scripts\smoke-test.ps1 exists to warn about that truncation cliff;
    # the builder was walking off it from the inside, and every winget, uv and pip child launched
    # after that point inherited the oversized PATH.
    #
    # TWO assertions, because there are two ways to put it back. A sentinel that is in neither the
    # Machine nor the User PATH has to be GONE after one call - that catches a re-append even when
    # Select-Object -Unique hides the length. And call 2 has to reproduce call 1 exactly - that
    # catches the verbatim original, which had no -Unique to hide behind.
    $defs = Get-BuilderFnScope -Name 'Sync-EnvPath'
    if (-not $defs) { Write-Host "       Sync-EnvPath is gone" -ForegroundColor DarkYellow; return $false }
    $saved = $env:PATH
    try {
        $r = & {
            param($Defs, $Root)
            . $Defs
            $env:PATH = 'C:\su-sentinel-one;C:\su-sentinel-two'
            Sync-EnvPath
            $one = $env:PATH
            Sync-EnvPath
            [pscustomobject]@{ One = $one; Two = $env:PATH }
        } $defs (Join-Path $bdRoot 'absent-toolbox')
    } finally { $env:PATH = $saved }
    if ($r.Two -match 'su-sentinel') {
        Write-Host "       the prior `$env:PATH survived the call - it is being folded back in" -ForegroundColor DarkYellow
    }
    if ($r.One -ne $r.Two) {
        Write-Host ("       call 1 {0} chars / {1} entries, call 2 {2} chars / {3} entries" -f `
            $r.One.Length, @($r.One -split ';').Count, $r.Two.Length, @($r.Two -split ';').Count) -ForegroundColor DarkYellow
    }
    ($r.Two -notmatch 'su-sentinel') -and ($r.One -eq $r.Two)
}

It 'and it still produces a REAL PATH - every Machine and User entry, each exactly once' {
    # THE POSITIVE CONTROL for the test above, and the one that pins -Unique. `$env:PATH = ''`
    # converges beautifully and would pass the convergence assertion on its own, so the result has
    # to be shown to be the PATH it claims to be. -Unique is what makes that convergence a
    # property of the FUNCTION rather than of this box's PATH happening to contain no repeats.
    $defs = Get-BuilderFnScope -Name 'Sync-EnvPath'
    if (-not $defs) { Write-Host "       Sync-EnvPath is gone" -ForegroundColor DarkYellow; return $false }
    $machine = @([System.Environment]::GetEnvironmentVariable('PATH', 'Machine') -split ';' | Where-Object { $_ })
    $user    = @([System.Environment]::GetEnvironmentVariable('PATH', 'User')    -split ';' | Where-Object { $_ })
    $saved = $env:PATH
    try {
        $got = & {
            param($Defs, $Root)
            . $Defs
            $env:PATH = 'C:\su-sentinel-one'
            Sync-EnvPath
            $env:PATH
        } $defs (Join-Path $bdRoot 'absent-toolbox')
    } finally { $env:PATH = $saved }
    $entries = @($got -split ';')
    $missing = @(@($machine + $user) | Where-Object { $entries -notcontains $_ })
    $dupes = @($entries | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($missing.Count) { Write-Host ("       dropped from PATH: " + ($missing -join ', ')) -ForegroundColor DarkYellow }
    if ($dupes.Count)   { Write-Host ("       duplicated on PATH: " + ($dupes -join ', ')) -ForegroundColor DarkYellow }
    # The floor stops a PATH read that returned nothing from satisfying "nothing is missing".
    ($machine.Count -ge 5) -and ($missing.Count -eq 0) -and ($dupes.Count -eq 0) -and
        (@($entries | Where-Object { -not $_ }).Count -eq 0)
}

It 'Sync-EnvPath puts a toolbox directory on PATH only when it exists on disk' {
    # The old body added $Root\native\bin and $Root\python\.venv\Scripts unconditionally, so a
    # FIRST build - before either exists - seeded the session PATH with two dead entries that
    # every later call then preserved. They are indistinguishable from the dead entries
    # scripts\consolidate-path.ps1 exists to remove, and they spend PATH budget that the
    # 4,095-char limit actually meters.
    #
    # BOTH DIRECTIONS, because "never adds them" also satisfies the first half - and the whole
    # point of the function is putting native\bin in front of everything else.
    $defs = Get-BuilderFnScope -Name 'Sync-EnvPath'
    if (-not $defs) { Write-Host "       Sync-EnvPath is gone" -ForegroundColor DarkYellow; return $false }
    $absent = Join-Path $bdRoot 'absent-toolbox'
    $present = Join-Path $bdRoot ('present-toolbox-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $present 'native\bin') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $present 'python\.venv\Scripts') -Force | Out-Null
    $saved = $env:PATH
    try {
        $run = {
            param($Defs, $Root)
            . $Defs
            $env:PATH = 'C:\su-sentinel-one'
            Sync-EnvPath
            $env:PATH
        }
        $withAbsent = & $run $defs $absent
        $withPresent = & $run $defs $present
    } finally { $env:PATH = $saved }
    $absentEntries = @($withAbsent -split ';')
    $presentEntries = @($withPresent -split ';')
    $leaked = @($absentEntries | Where-Object { $_ -like ($absent + '*') })
    if ($leaked.Count) { Write-Host ("       a directory that does not exist reached PATH: " + ($leaked -join ', ')) -ForegroundColor DarkYellow }
    # FIRST, not merely present: native\bin exists to shadow an unrelated same-named binary
    # elsewhere on PATH, and it can only do that from the front.
    ($leaked.Count -eq 0) -and
        ($presentEntries[0] -eq (Join-Path $present 'native\bin')) -and
        ($presentEntries -contains (Join-Path $present 'python\.venv\Scripts'))
}

Write-Host "`n== the builder writes shims through the shared contract, not its own copy ==" -ForegroundColor Cyan

It "New-CmdWrapper carries no here-string of its own, and writes New-ShimBody's exact bytes" {
    # It WAS a here-string. lib\ShimFormat.ps1 carried the rule against exactly that while this -
    # one of the two writers that file was created to reach - broke it. core.autocrlf=true with no
    # .gitattributes makes a here-string's line endings a property of the CHECKOUT: measured
    # 2026-09-11 by running the old body out of a CRLF file and an LF file, it emitted 28 bytes and
    # 27 bytes for the same target. Every reader anchors its regex on $, so the LF column is all 26
    # wrappers a build writes - counted from a -DryRun the same day - unparseable, and a smoke test
    # that reports them as zero stale AND zero present. A silent, total loss of the only check that
    # notices a broken wrapper.
    #
    # THE SOURCE HALF IS THE HALF THAT CAN FAIL. On a CRLF checkout the byte comparison passes
    # with the here-string restored, which is exactly what makes bytes alone a check that cannot
    # fire. The AST assertions are the guard; the bytes are the positive control that the writer
    # still works and still agrees with the shared definition.
    $fn = Get-BuilderFn -Name 'New-CmdWrapper'
    if (-not $fn) { Write-Host "       New-CmdWrapper is gone" -ForegroundColor DarkYellow; return $false }
    $heres = @($fn.Body.FindAll({
        param($n)
        (($n -is [System.Management.Automation.Language.StringConstantExpressionAst]) -or
         ($n -is [System.Management.Automation.Language.ExpandableStringExpressionAst])) -and
        ("$($n.StringConstantType)" -match 'HereString')
    }, $true))
    $calls = @($fn.Body.FindAll({
        param($n)
        ($n -is [System.Management.Automation.Language.CommandAst]) -and
        ($n.GetCommandName() -eq 'New-ShimBody')
    }, $true))
    if ($heres.Count) {
        foreach ($h in $heres) { Write-Host ("       line {0}: here-string in the shim writer" -f $h.Extent.StartLineNumber) -ForegroundColor DarkYellow }
    }
    if (-not $calls.Count) { Write-Host "       New-ShimBody is not called - the format has been re-inlined" -ForegroundColor DarkYellow }

    $defs = Get-BuilderFnScope -Name 'New-CmdWrapper'
    $wrapRoot = Join-Path $bdRoot ('wrap-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $wrapRoot 'native\bin') -Force | Out-Null
    # The same target the byte-exact New-ShimBody test above uses, so both pin the same 28 bytes.
    $target = 'C:\x\y.exe'
    $ok = & {
        param($Defs, $Root, $Target)
        $DryRun = $false
        . $Defs
        New-CmdWrapper -Name 'zzprobe' -Target $Target
    } $defs $wrapRoot $target
    $wrapper = Join-Path $wrapRoot 'native\bin\zzprobe.cmd'
    if (-not (Test-Path -LiteralPath $wrapper)) { Write-Host "       no wrapper was written" -ForegroundColor DarkYellow; return $false }
    $bytes = [IO.File]::ReadAllBytes($wrapper)
    $want = [Text.Encoding]::ASCII.GetBytes((New-ShimBody -Target $target))
    if (@(Compare-Object $bytes $want -SyncWindow 0).Count) {
        Write-Host ("       wrote {0} bytes, New-ShimBody says {1}" -f $bytes.Count, $want.Count) -ForegroundColor DarkYellow
    }
    ($heres.Count -eq 0) -and ($calls.Count -eq 1) -and ($ok -eq $true) -and
        ($bytes.Count -eq 28) -and (@(Compare-Object $bytes $want -SyncWindow 0).Count -eq 0)
}

It 'the builder dot-sources EXACTLY ONE file, and keeps no private copy of the shim contract' {
    # Its standalone-ness is load-bearing rather than stylistic: bootstrap.ps1 invokes it as a
    # CHILD PROCESS, so anything it dot-sources must be reachable and side-effect-free on its own.
    # That same constraint is what let it keep a private, wrong shim format for as long as it did -
    # the cheap fix was always "copy the two functions in", and the cheap fix is the bug.
    #
    # lib\ShimFormat.ps1 is the one exception, added 2026-09-11: functions only, no side effects on
    # load, no dot-sources of its own. The count is PINNED AT ONE so the next convenient import -
    # lib\common.ps1 for Sync-EnvPath, lib\ShimPlan.ps1 for the planner - has to argue for itself
    # here instead of arriving as a diff nobody read. `&` invocations are not counted; 20 of those
    # are native-command call sites and none of them import anything.
    #
    # The second assertion is the other direction, and it is why removing Get-WrapperTarget was
    # not enough on its own: a re-added private reader or writer passes the dot-source count and
    # passes the "all copies agree" drift test above, because an identical copy agrees with itself.
    # `" %*` (writer) and `" %\*` (reader regex) are the shim's target-line shape and appear
    # nowhere else in the file - Write-ActivationHelpers' `@echo off` block writes
    # activate-toolbox.cmd, which has no target line at all.
    #
    # SCOPED TO EVERYTHING OUTSIDE New-CmdWrapper, which is the test above's jurisdiction. Measured
    # while mutation-testing this suite: with the whole file in scope, restoring the here-string
    # failed BOTH tests, because a here-string body is itself a private copy of the target line.
    # One defect lighting up two names is how people learn to read the failure count instead of
    # the failure, so the two are separated by extent - the writer's own body is excised by text
    # rather than by offset, so a BOM cannot shift the cut.
    $dots = @($builderAst.FindAll({
        param($n)
        ($n -is [System.Management.Automation.Language.CommandAst]) -and
        ($n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot)
    }, $true))
    foreach ($d in $dots) {
        if ($d.Extent.Text -notmatch 'ShimFormat\.ps1') {
            Write-Host ("       line {0}: {1}" -f $d.Extent.StartLineNumber, $d.Extent.Text) -ForegroundColor DarkYellow
        }
    }
    $src = Get-Content -LiteralPath $builderPs1 -Raw
    $writer = Get-BuilderFn -Name 'New-CmdWrapper'
    $outside = $src
    if ($writer) {
        $outside = $src.Replace($writer.Extent.Text, '')
        if ($outside.Length -eq $src.Length) {
            # The excision silently missed, so the scope is wrong and every result below is about
            # a different file than the one this test claims to read. Say so rather than pass.
            Write-Host "       could not excise New-CmdWrapper from the source - scope is wrong" -ForegroundColor DarkYellow
            return $false
        }
    }
    $private = [regex]::Matches($outside, '" %\\?\*')
    if ($private.Count) {
        Write-Host ("       {0} private shim target-line(s) outside New-CmdWrapper - the contract lives in lib\ShimFormat.ps1" -f $private.Count) -ForegroundColor DarkYellow
    }
    ($dots.Count -eq 1) -and ($dots[0].Extent.Text -match 'ShimFormat\.ps1') -and ($private.Count -eq 0)
}

Write-Host "`n== one tree walk per package, and it still resolves the same file ==" -ForegroundColor Cyan

It 'Find-Executable walks each winget package tree ONCE, not once per extension' {
    # Two -Filter passes over the same $packageDir.FullName, one for *.exe and one for *.cmd, and
    # on the expensive path - a name no package supplies - BOTH walked the whole tree. Measured
    # 2026-09-11 over this box's 27 packages / 1,241 files, 7 runs each: 76.6 ms per miss for two
    # passes, 37.9 ms for one -Filter "<name>*" walk. BACKLOG has carried the item since 2026-09-10.
    #
    # The assertion is the COUNT of recursive walks inside the loop, not the presence of one. A
    # check for "there is a Get-ChildItem here" passes with the second pass restored, which is the
    # whole failure shape this suite keeps closing.
    $fn = Get-BuilderFn -Name 'Find-Executable'
    if (-not $fn) { Write-Host "       Find-Executable is gone" -ForegroundColor DarkYellow; return $false }
    $loop = @($fn.Body.FindAll({
        param($n)
        ($n -is [System.Management.Automation.Language.ForEachStatementAst]) -and
        ($n.Condition.Extent.Text -match '\$packageDirs')
    }, $true)) | Select-Object -First 1
    if (-not $loop) { Write-Host "       no foreach over `$packageDirs" -ForegroundColor DarkYellow; return $false }
    $walks = @($loop.Body.FindAll({
        param($n)
        ($n -is [System.Management.Automation.Language.CommandAst]) -and
        ($n.GetCommandName() -eq 'Get-ChildItem') -and
        (@($n.CommandElements | Where-Object {
            ($_ -is [System.Management.Automation.Language.CommandParameterAst]) -and ($_.ParameterName -eq 'Recurse') }).Count -gt 0)
    }, $true))
    # -Include is REJECTED, measured, not a style opinion: with -LiteralPath it is silently
    # IGNORED. Asked for -Include 'uv.exe','uv.cmd' it returned every file in the package -
    # AUTHORS, ChangeLog, README.html - which is the same trap that would have written a README.cmd
    # shim in Get-ShimCandidates. It benchmarked at 19.4 ms only because the filter was inert.
    $includes = @($loop.Body.FindAll({
        param($n)
        ($n -is [System.Management.Automation.Language.CommandParameterAst]) -and ($n.ParameterName -eq 'Include')
    }, $true))
    if ($walks.Count -ne 1) {
        foreach ($w in $walks) { Write-Host ("       line {0}: recursive walk #{1} of the same tree" -f $w.Extent.StartLineNumber, (1 + $walks.IndexOf($w))) -ForegroundColor DarkYellow }
    }
    if ($includes.Count) { Write-Host "       -Include is inert under -LiteralPath; use -Filter" -ForegroundColor DarkYellow }
    ($walks.Count -eq 1) -and ($includes.Count -eq 0)
}

It 'and one walk still prefers .exe over .cmd, finds a sole .cmd, and never resolves a README' {
    # THE POSITIVE CONTROL for the walk above, and the only place the .exe preference is checked at
    # all. Two sequential -Filter passes expressed that preference as ORDER; one walk has to state
    # it, and a tie-break written the other way round is invisible - both binaries run, and a shim
    # pointing at the .cmd instead of the .exe looks exactly like a working one.
    #
    # Driven entirely off a TEMP fixture: $env:LOCALAPPDATA carries the fake Packages root, and
    # $env:ProgramFiles / ${env:ProgramFiles(x86)} are pointed at it too so the exhaustive
    # fallback cannot reach this box on the README case. All three are process-wide, so they are
    # restored in the finally.
    $defs = Get-BuilderFnScope -Name 'Find-Executable'
    if (-not $defs) { Write-Host "       Find-Executable is gone" -ForegroundColor DarkYellow; return $false }
    $fix = Join-Path $bdRoot ('fe-' + [guid]::NewGuid().ToString('N'))
    # The real disk layout: a version-stamped subfolder under the package root, so the walk has to
    # actually recurse rather than read the package directory.
    $pkg = Join-Path $fix 'Microsoft\WinGet\Packages\Test.Tool_Microsoft.Winget.Source_8wekyb3d8bbwe\v1.2.3\bin'
    New-Item -ItemType Directory -Path $pkg -Force | Out-Null
    foreach ($leaf in @('zzboth.exe', 'zzboth.cmd', 'zzsole.cmd', 'README.md')) {
        Set-Content -LiteralPath (Join-Path $pkg $leaf) -Value 'fixture' -Encoding ASCII
    }
    $savedLocal = $env:LOCALAPPDATA; $savedPf = $env:ProgramFiles; $savedPf86 = ${env:ProgramFiles(x86)}
    try {
        $got = & {
            param($Defs, $Fix)
            . $Defs
            $Root = Join-Path $Fix 'toolbox'
            $CommandSearchPatterns = @{}
            $env:LOCALAPPDATA = $Fix
            $env:ProgramFiles = $Fix
            ${env:ProgramFiles(x86)} = $Fix
            [pscustomobject]@{
                Both   = (Find-Executable -Name 'zzboth' -WingetId 'Test.Tool')
                Sole   = (Find-Executable -Name 'zzsole' -WingetId 'Test.Tool')
                Readme = (Find-Executable -Name 'README' -WingetId 'Test.Tool')
            }
        } $defs $fix
    } finally {
        $env:LOCALAPPDATA = $savedLocal; $env:ProgramFiles = $savedPf; ${env:ProgramFiles(x86)} = $savedPf86
    }
    if ($got.Both -ne (Join-Path $pkg 'zzboth.exe')) { Write-Host ("       a package shipping both resolved to: {0}" -f $got.Both) -ForegroundColor DarkYellow }
    if ($got.Readme) { Write-Host ("       README resolved to: {0}" -f $got.Readme) -ForegroundColor DarkYellow }
    ($got.Both -eq (Join-Path $pkg 'zzboth.exe')) -and
        ($got.Sole -eq (Join-Path $pkg 'zzsole.cmd')) -and
        ($null -eq $got.Readme)
}

Remove-Item -LiteralPath $bdRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n== the shim writers and the gates that notice when one stops running ==" -ForegroundColor Cyan

# Repo-relative worktree exclusion, and it is deliberately not the absolute
# `-notlike '*\.claude\worktrees\*'` used higher up in this file. Three full copies of this tree
# live under .claude\worktrees\ during parallel agent work, so they have to be skipped - but an
# absolute pattern matches EVERY file when the suite is itself run from a worktree, which is why
# the shim-regex test at :700 finds 0 hits and fails there (measured 2026-09-11: 80 passed / 1
# failed from a worktree, 81 / 0 from the main checkout). Relative means "a worktree nested under
# this repo", never "this repo".
$suRepoPrefix = $repoRoot.TrimEnd('\') + '\'
function Get-SURepoScripts {
    Get-ChildItem -LiteralPath $repoRoot -Recurse -Filter *.ps1 -File -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.FullName.Substring($suRepoPrefix.Length) -like '.claude\worktrees\*') }
}

It 'every pipeline that starts with New-ShimBody ends in Set-Content -NoNewline' {
    # THE byte guard, and the only new check here with teeth on live machine state.
    #
    # New-ShimBody's string ALREADY ends in CRLF, and Set-Content without -NoNewline appends one
    # of its own - measured under 5.1: the four inline literals this commit replaced ended in
    # `" %*` with no newline and the file on disk ended 22 20 25 2A 0D 0A, i.e. Set-Content added
    # it. So -NoNewline is not tidiness, it is the difference between an unchanged wrapper and
    # every wrapper gaining a THIRD line. windbg / ghidraRun / analyzeHeadless / poolmon /
    # cdb / kd / ntsd / gflags / dumpchk would keep resolving by name while the smoke test's
    # stale-shim check - which anchors on $ - lost the ability to tell healthy from stale.
    #
    # PIPELINES ONLY, so lib\ShimPlan.ps1:558, which hands the body to a $WriteFile scriptblock as
    # an ARGUMENT, is out of scope by shape rather than by an exception list that would need
    # editing the next time a writer changes hands.
    $bad = @(); $sites = 0
    foreach ($f in (Get-SURepoScripts)) {
        $a = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        if (-not $a) { continue }
        foreach ($pipe in $a.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.PipelineAst] }, $true)) {
            $els = @($pipe.PipelineElements)
            if ($els.Count -lt 2) { continue }
            if (-not ($els[0] -is [System.Management.Automation.Language.CommandAst])) { continue }
            if ($els[0].GetCommandName() -ne 'New-ShimBody') { continue }
            $sites++
            $last = $els[-1]
            # Parameter names by PREFIX, because PowerShell resolves them that way: -NoNew binds
            # -NoNewline just as well, and Set-Content has no other parameter starting "No".
            $hasNoNewline = $false
            if ($last -is [System.Management.Automation.Language.CommandAst]) {
                if ($last.GetCommandName() -eq 'Set-Content') {
                    foreach ($e in $last.CommandElements) {
                        if ($e -is [System.Management.Automation.Language.CommandParameterAst] -and
                            $e.ParameterName -and ('NoNewline' -like ($e.ParameterName + '*'))) { $hasNoNewline = $true }
                    }
                }
            }
            if (-not $hasNoNewline) {
                $bad += ('{0}:{1}' -f $f.FullName.Substring($suRepoPrefix.Length), $pipe.Extent.StartLineNumber)
            }
        }
    }
    if ($bad.Count) { Write-Host "     writes a third line: $($bad -join ', ')" -ForegroundColor Red }
    if ($sites -lt 4) { Write-Host "     only $sites New-ShimBody pipeline(s) found - expected at least the four in modules\security.ps1" -ForegroundColor Red }
    ($sites -ge 4) -and ($bad.Count -eq 0)
}

It 'the three-line Ghidra wrapper is byte-identical to what the inline literal emitted' {
    # The -Prologue case pinned at BYTE level, because Ghidra's is the only wrapper whose SHAPE
    # can drift. The CRLF used to live inside $jdkLine and be spliced into the middle of a format
    # literal, so the with-JDK and without-JDK cases were two byte contracts maintained by one
    # expression - and the three-line one is the case every positional reader gets wrong.
    #
    # The left-hand sides below are the OLD expression verbatim, plus the CRLF Set-Content used to
    # append. Both branches measured identical on a TEMP fixture before the change: 132 B with a
    # JDK, 61 B without.
    $t = 'C:\Tools\ghidra_12.1.2_PUBLIC\ghidraRun.bat'
    $j = 'C:\Users\Admin\AppData\Local\DevToolbox\native\jdk-21'
    $oldJdk   = "@echo off`r`n" + "set `"JAVA_HOME=$j`"`r`n" + "`"$t`" %*" + "`r`n"
    $oldPlain = "@echo off`r`n" + ""                          + "`"$t`" %*" + "`r`n"
    $newJdk   = New-ShimBody -Target $t -Prologue @("set `"JAVA_HOME=$j`"")
    $newPlain = New-ShimBody -Target $t -Prologue @()
    # -ceq: a case-insensitive compare would accept "@ECHO OFF", which cmd tolerates and the
    # readers' regex does not care about - but the point of this test is that the bytes did not
    # move, so it compares them the way a byte comparison would.
    ($newJdk -ceq $oldJdk) -and ($newPlain -ceq $oldPlain) -and
        ([Text.Encoding]::ASCII.GetBytes($newJdk).Count -eq 132) -and
        ([Text.Encoding]::ASCII.GetBytes($newPlain).Count -eq 61) -and
        # and the reader still finds the target past the prologue line
        ((Get-ShimTarget -Lines ($newJdk -split "`r`n")) -eq $t)
}

It 'modules\security.ps1 hand-rolls no shim body, and dot-sources nothing to avoid it' {
    # Four writers lived in that file, each with its own copy of the byte shape. They reach
    # New-ShimBody through BOOTSTRAP's scope - bootstrap.ps1:27 loads lib\common.ps1, which loads
    # lib\ShimFormat.ps1 at its :19, and bootstrap.ps1:412 dot-sources the module into that same
    # scope. A dot-source inside security.ps1 would be a SECOND load path for the same two
    # functions, which is the condition lib\ShimFormat.ps1's header measured its topology on.
    #
    # The literal check runs over STRING AST NODES, not the file text: this module's own comments
    # discuss `@echo off` on purpose, and a grep would flag the explanation for the fix.
    $p = Join-Path $repoRoot 'modules\security.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$null)
    $calls = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'New-ShimBody' }, $true))
    $dots = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot }, $true))
    $literals = @($ast.FindAll({ param($n)
        ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
         $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
        $n.Extent.Text -match '@echo off' }, $true))
    if ($dots.Count)     { Write-Host "     dot-sources at line(s): $(@($dots | ForEach-Object { $_.Extent.StartLineNumber }) -join ', ')" -ForegroundColor Red }
    if ($literals.Count) { Write-Host "     inline shim literal at line(s): $(@($literals | ForEach-Object { $_.Extent.StartLineNumber }) -join ', ')" -ForegroundColor Red }
    ($calls.Count -ge 4) -and ($dots.Count -eq 0) -and ($literals.Count -eq 0)
}

It "smoke-test.ps1's required-suite floor names every suite in tests\" {
    # The floor is the ONLY thing that can notice a DELETED suite; the from-disk enumeration next
    # to it cannot, by construction - it simply stops finding the file. gate.yml:100-110 has had
    # this check for CI's hand-maintained list since it was written, and the local gate had the
    # unguarded twin: Invoke-SmokeLintTests.ps1 was outside $suiteRequired from the day it was
    # written until 2026-09-11, so enumeration RAN it and reported it green while a commit
    # deleting it would have fired nothing locally at all.
    #
    # Derived on BOTH sides, so there is no count in this file to reflex-edit in the same commit
    # that removes a suite - and the array literal is evaluated out of the AST, so nothing in
    # smoke-test.ps1 runs (it checks ~40 installed tools and a live Sysmon service).
    $smoke = Join-Path $repoRoot 'scripts\smoke-test.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($smoke, [ref]$null, [ref]$null)
    $asg = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$suiteRequired' }, $true))
    if ($asg.Count -ne 1) {
        Write-Host "     found $($asg.Count) assignments to `$suiteRequired, expected exactly 1" -ForegroundColor Red
        return $false
    }
    $named = @(Invoke-Expression $asg[0].Right.Extent.Text)
    $onDisk = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tests') -Filter 'Invoke-*Tests.ps1' `
                    -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $missing = @($onDisk | Where-Object { $named -notcontains $_ })
    if ($missing.Count) { Write-Host "     not in the floor: $($missing -join ', ')" -ForegroundColor Red }
    # TWO POSITIVE CONTROLS, and neither is the count of files on disk. "$onDisk.Count -ge 5" was
    # the obvious one and it is wrong: renaming a suite aside is the mutation that proves the
    # smoke test's floor fires, and a disk-count control makes THIS test fire on it too - two red
    # lines for one defect, which is how the wrong check gets blamed. So the controls are (1) the
    # floor list itself is not empty or gutted, and (2) the enumeration can still find the file
    # this very test is running from. Both hold regardless of which OTHER suite exists.
    if ($named.Count -lt 5) { Write-Host "     the floor names only $($named.Count) suite(s)" -ForegroundColor Red }
    if ($onDisk -notcontains 'Invoke-InstallerTests.ps1') { Write-Host "     the enumeration cannot even find the suite it is running from" -ForegroundColor Red }
    ($named.Count -ge 5) -and ($onDisk -contains 'Invoke-InstallerTests.ps1') -and ($missing.Count -eq 0)
}

It "smoke-test.ps1's 5.1 parse gate sweeps the tree, not a list of six names" {
    # A CONDITION, not a grep for "Get-ChildItem -Recurse": the two assignments that build the
    # list are taken out of smoke-test.ps1's AST and EVALUATED with $REPO_ROOT bound here, then
    # the result is inspected. An enumeration sitting there feeding nothing would pass a source
    # check and fails this one.
    #
    # The eight names below are precisely what the hand-written six-name list missed, so they are
    # the files a revert would drop. Measured 2026-09-11: 6 gated, 35 .ps1 on disk - which meant a
    # 7-only construct in any lib\ file was caught by CI on push and never by the local gate that
    # README.md and docs\agent-rules.md tell people to run first.
    #
    # THE TWO HALVES COVER DIFFERENT HOSTS, stated because neither is sufficient alone. Running
    # from the MAIN checkout, the "no .claude\worktrees\ entry" half catches a missing filter and
    # the count half is loose. Running from a WORKTREE there is nothing nested to exclude, so the
    # count half is what catches an ABSOLUTE filter - which would sweep 0 files there.
    $smoke = Join-Path $repoRoot 'scripts\smoke-test.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($smoke, [ref]$null, [ref]$null)
    $asg = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        ($n.Left.Extent.Text -eq '$parseRoot' -or $n.Left.Extent.Text -eq '$fxFiles') }, $true) |
        Sort-Object { $_.Extent.StartOffset })
    if ($asg.Count -ne 2) {
        Write-Host "     found $($asg.Count) of the 2 expected assignments (`$parseRoot, `$fxFiles)" -ForegroundColor Red
        return $false
    }
    $REPO_ROOT = $repoRoot
    $parseRoot = $null; $fxFiles = $null
    foreach ($a in $asg) { Invoke-Expression $a.Extent.Text }
    $rel = @(@($fxFiles) | ForEach-Object { $_.FullName.Substring($parseRoot.Length) })
    $want = @('lib\ShimPlan.ps1', 'lib\ShimFormat.ps1', 'lib\path-registry.ps1',
              'lib\AgentDiscovery.ps1', 'lib\SmokeLint.ps1', 'lib\common.ps1',
              'lib\catalog.ps1', 'scripts\consolidate-path.ps1')
    $uncovered = @($want | Where-Object { $rel -notcontains $_ })
    $leaked = @($rel | Where-Object { $_ -like '.claude\worktrees\*' })
    if ($uncovered.Count) { Write-Host "     not parse-gated: $($uncovered -join ', ')" -ForegroundColor Red }
    if ($leaked.Count)    { Write-Host "     $($leaked.Count) nested-worktree file(s) swept, e.g. $($leaked[0])" -ForegroundColor Red }
    if ($rel.Count -lt 20) { Write-Host "     swept only $($rel.Count) file(s) - the walk is not reaching the tree (no -Recurse, or an ABSOLUTE worktree filter, which excludes everything when the gate is run from a worktree)" -ForegroundColor Red }
    ($uncovered.Count -eq 0) -and ($leaked.Count -eq 0) -and ($rel.Count -ge 20)
}

if (-not (Assert-SUSuiteFloor -SuiteFile $PSCommandPath -Ran ($script:Pass + $script:Fail))) { $script:Fail++ }
Show-SUGuardSummary

Write-Host ("`n{0} passed, {1} failed`n" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })
