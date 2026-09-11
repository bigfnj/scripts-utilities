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
    # working copy. Three separate readers anchor their regex on $ (build-devtoolbox.ps1:336,
    # smoke-test.ps1:280, Get-ShimTarget), so a lone LF makes every shim unparseable and the
    # smoke test reports 47 healthy shims as zero stale AND zero present.
    $b = [Text.Encoding]::ASCII.GetBytes((New-ShimBody -Target 'C:\x\y.exe'))
    $want = [Text.Encoding]::ASCII.GetBytes("@echo off") + @(13, 10) +
            [Text.Encoding]::ASCII.GetBytes('"C:\x\y.exe" %*') + @(13, 10)
    (@(Compare-Object $b $want -SyncWindow 0).Count -eq 0) -and ($b.Count -eq 28)
}
It 'the shim regex is character-identical in all three files that read a wrapper' {
    # A DRIFT guard, deliberately at source level: the three readers are in three files nothing
    # forces to agree, and a regex that is merely equivalent today is how they stop agreeing.
    # modules\security.ps1 writes a THREE-line Ghidra wrapper, so any reader that stops matching
    # loses Ghidra first and silently.
    $pat = '\^"\(\[\^"\]\+\)" %\\\*\$'
    $hits = @()
    foreach ($f in @('lib\ShimPlan.ps1', 'scripts\build-devtoolbox.ps1', 'scripts\smoke-test.ps1')) {
        $src = Get-Content (Join-Path $repoRoot $f) -Raw
        if ($src -match $pat) { $hits += $f }
    }
    $hits.Count -eq 3
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

if (-not (Assert-SUSuiteFloor -SuiteFile $PSCommandPath -Ran ($script:Pass + $script:Fail))) { $script:Fail++ }
Show-SUGuardSummary

Write-Host ("`n{0} passed, {1} failed`n" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })
