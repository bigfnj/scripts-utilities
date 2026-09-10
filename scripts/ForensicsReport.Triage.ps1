#Requires -Version 5.1
<#
    ForensicsReport.Triage.ps1 - the optional model-assisted layer of the deletion report.

    WHAT THIS IS ALLOWED TO BE. A lead generator. Everything above it in the report is measured:
    counts, bursts, sentinel hits, pairings never seen before. Those are facts and they render
    first, completely, and without this file being involved at all. This adds one thing the
    arithmetic cannot - a sentence about what a cluster of events might MEAN - and it is fenced
    off, labelled a hypothesis, and never allowed to change a number.

    WHY THE FENCE IS THE POINT. This project spent an audit round removing code that printed
    confident sentences about things it never checked, and then built Invoke-PMChange in the
    sibling project so a claim cannot be made without a post-condition. A language model is,
    structurally, a machine for producing exactly that kind of sentence. Dropping one into a
    forensics report unfenced would reintroduce the whole class with better prose.

    So the same rule is applied to the model that was applied to the code: IT MUST POINT AT
    FACTS. Every finding it returns has to cite a process and a directory that were in the input
    it was given. Anything citing something that was not is discarded before it reaches the page
    - a hallucinated process name is cheaply detectable, and detecting it is not optional.

    THREE HARD CONSTRAINTS, in priority order:
      1. The report renders identically when Ollama is absent, down, slow or gibberish. This is
         an addition, never a dependency.
      2. It cannot gate, filter, reorder or suppress a fact.
      3. Its output is visually and structurally separate, and says plainly that it is a
         hypothesis produced by a model.

    Testability: the HTTP call is injectable via -Responder, so the suite exercises the
    validation logic - which is the part that matters - without needing a model running and
    without depending on what one happens to say today.
#>

function Test-FxLlmAvailable {
    <#
        Cheap liveness check. /api/tags loads no model and returned in 92 ms when measured;
        anything heavier would make "is it worth asking" cost more than asking.
    #>
    param([string]$BaseUri = 'http://127.0.0.1:11434', [int]$TimeoutSec = 5)
    try {
        $null = Invoke-RestMethod -Uri "$BaseUri/api/tags" -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $true
    } catch {
        # System.Net.WebException / "Unable to connect to the remote server" when nothing is
        # listening. Measured under 5.1; caught broadly because a proxy, a TLS setting or a
        # half-open service produces different types for the same practical situation.
        return $false
    }
}

function Resolve-FxTriageModel {
    <#
        Pick a model that is actually INSTALLED, rather than trusting a hardcoded tag.

        Ollama resolves tags exactly. The default here was 'mistral-small3.2:24b' - correct on
        the machine this was written on, and a 404 anywhere else, including a box provisioned by
        this repo's own install-llm.ps1, which pulls 'mistral-small'. Because triage is on by
        default and degrades silently, a wrong default does not produce an error: it produces a
        report that quietly never has a triage panel, forever, and looks exactly like a machine
        with no model at all.

        Returns $null when nothing usable is installed, which the caller treats as "no model".
    #>
    param(
        [string]$Preferred = 'mistral-small3.2:24b',
        [string]$BaseUri = 'http://127.0.0.1:11434',
        [int]$TimeoutSec = 5,
        [string[]]$Installed          # test seam; skips the HTTP call entirely
    )
    $names = $Installed
    if ($null -eq $names) {
        try {
            $r = Invoke-RestMethod -Uri "$BaseUri/api/tags" -TimeoutSec $TimeoutSec -ErrorAction Stop
            $names = @($r.models | ForEach-Object { [string]$_.name })
        } catch { return $null }
    }
    $names = @($names | Where-Object { $_ })
    if (-not $names.Count) { return $null }

    if ($names -contains $Preferred) { return $Preferred }

    # Same family, any tag. Compared both ways on the part before the colon, because the drift
    # runs in both directions: preferred 'mistral-small3.2:24b' should accept an installed
    # 'mistral-small:latest', and preferred 'mistral-small' should accept 'mistral-small3.2:24b'.
    $pBase = ($Preferred -split ':')[0]
    foreach ($n in $names) {
        $nBase = ($n -split ':')[0]
        if ($nBase -eq $pBase -or $nBase.StartsWith($pBase) -or $pBase.StartsWith($nBase)) { return $n }
    }

    # Anything that can hold a conversation. Embedding, reranker and vision-only models cannot
    # answer this prompt at all, so naming one is worse than returning nothing.
    #
    # This is a NAME heuristic and it is only as good as the list - 'bge-m3' is an embedding
    # model with no "embed" anywhere in its name, which is exactly how this list was found to be
    # too short. It is acceptable because the downstream cost of a bad pick is bounded: a model
    # that cannot answer produces unparseable output or uncited claims, and both are already
    # discarded, so the failure mode is "no triage panel" rather than a wrong one.
    $notChat = 'embed|rerank|moondream|^bge|^gte|^e5|^nomic|^mxbai|^snowflake-arctic|^all-minilm|^paraphrase'
    foreach ($n in $names) { if ($n -notmatch $notChat) { return $n } }
    return $null
}

function ConvertTo-FxTriagePrompt {
    <#
        The model sees AGGREGATES, never the raw log.

        Not a context-window concern - 13,450 characters answered in 0.6 s when measured. It is
        that 9,000 raw rows invite summarising, and a summary of facts the report already states
        exactly is the least useful and most error-prone thing this could produce. Given the
        aggregates, the only thing left to add is interpretation, which is the one thing it is
        here for.
    #>
    param($Facts)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('DELETION TELEMETRY from one Windows workstation, already aggregated.')
    $lines.Add('')
    $lines.Add('TOP PROCESSES BY DELETION COUNT:')
    foreach ($p in @($Facts.TopProcesses)) { $lines.Add(('  {0} | {1} deletions' -f $p.Name, $p.Count)) }
    $lines.Add('')
    $lines.Add('BURSTS (one process, many files, short window):')
    if (@($Facts.Bursts).Count) {
        foreach ($b in @($Facts.Bursts)) { $lines.Add(('  {0} | {1} files in {2}s' -f $b.Image, $b.Count, $b.Seconds)) }
    } else { $lines.Add('  none') }
    $lines.Add('')
    $lines.Add('PAIRINGS NEVER SEEN IN ANY PREVIOUS RUN:')
    if (@($Facts.Novel).Count) {
        foreach ($n in @($Facts.Novel)) { $lines.Add(('  {0} | {1} | {2} deletions' -f $n.Image, $n.Dir, $n.Count)) }
    } else { $lines.Add('  none') }
    $lines.Add('')
    $lines.Add('DELETIONS IN QUIET, VALUABLE DIRECTORIES (credentials, agent configs, toolchains):')
    if (@($Facts.Sentinels).Count) {
        foreach ($s in @($Facts.Sentinels)) { $lines.Add(('  {0} | {1} | {2} deletions' -f $s.Image, $s.Dir, $s.Count)) }
    } else { $lines.Add('  none') }
    $lines.Add('')
    $lines.Add('TASK: identify at most 4 things a human should look at, most important first.')
    $lines.Add('RULES:')
    $lines.Add('  - Every finding MUST name a process and a directory that appear VERBATIM above.')
    $lines.Add('  - Do not invent names. Do not restate a count as a finding.')
    $lines.Add('  - If nothing looks worth attention, return an empty findings array.')
    $lines.Add('  - Routine software maintaining its own caches is NOT worth attention.')
    $lines.Add('Reply ONLY with JSON:')
    $lines.Add('{"findings":[{"process":"...","directory":"...","concern":"one sentence","confidence":"low|medium|high"}]}')
    return ($lines -join "`n")
}

function Invoke-FxLlm {
    <#
        One non-streaming request. Returns the raw response text, or $null for ANY failure -
        unreachable, timeout, malformed, model missing. A degraded model must look exactly like
        an absent one to the caller, because the report's behaviour has to be the same either way.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Model = 'mistral-small3.2:24b',
        [string]$BaseUri = 'http://127.0.0.1:11434',
        [int]$TimeoutSec = 300
    )
    # temperature 0 for the closest thing to reproducibility available here. Measured identical
    # across repeated calls on this box - but NOT relied upon: nothing downstream assumes two
    # runs agree, and the facts above this layer are what a week-over-week diff should use.
    $body = @{
        model = $Model; prompt = $Prompt; stream = $false; format = 'json'
        options = @{ temperature = 0 }
    } | ConvertTo-Json -Depth 6
    try {
        # '; charset=utf-8' is NOT decoration. Under 5.1 - which is what the scheduled task runs -
        # a string body sent as plain 'application/json' is encoded with the ANSI codepage, so a
        # path containing an accented or CJK character reaches the model corrupted. It does not
        # error; it silently sends different bytes than intended. Measured: the same input
        # produced a different embedding under 5.1 vs curl until this parameter was added. pwsh 7
        # gets it right either way, which is exactly what makes it easy to miss.
        $r = Invoke-RestMethod -Uri "$BaseUri/api/generate" -Method Post -Body $body `
                -ContentType 'application/json; charset=utf-8' -TimeoutSec $TimeoutSec -ErrorAction Stop
        if ($r -and $r.response) { return [string]$r.response }
        return $null
    } catch { return $null }
}

function Get-FxTriage {
    <#
        Ask, then VALIDATE. Returns @{ Findings; Model; Rejected; Reason } - and Findings is
        only ever populated with claims that cite something real.

        -Responder exists so the suite can exercise the validation without a model running. The
        validation is the part worth testing; what a model says on a given day is not.
    #>
    param(
        [Parameter(Mandatory)]$Facts,
        [string]$Model = 'mistral-small3.2:24b',
        [string]$BaseUri = 'http://127.0.0.1:11434',
        [int]$TimeoutSec = 300,
        [scriptblock]$Responder
    )
    $out = @{ Findings = @(); Model = $Model; Rejected = 0; Reason = $null }

    # Everything the model is allowed to name, taken from what it was actually shown. Compared
    # case-insensitively on the LEAF process name and on a directory PREFIX, because a model
    # reasonably writes "rm.exe" for a full path and may quote a parent directory.
    $okProc = @{}
    $okDir = New-Object 'System.Collections.Generic.List[string]'
    foreach ($set in @($Facts.TopProcesses, $Facts.Bursts, $Facts.Novel, $Facts.Sentinels)) {
        foreach ($x in @($set)) {
            $n = if ($x.Name) { $x.Name } elseif ($x.Image) { $x.Image } else { $null }
            if ($n) { $okProc[([IO.Path]::GetFileName([string]$n)).ToLowerInvariant()] = $true }
            if ($x.Dir) { $okDir.Add(([string]$x.Dir).TrimEnd('\', '/').ToLowerInvariant()) }
        }
    }

    # Nothing below may throw out of this function. Constraint 1 is that the report renders
    # identically whether the model is absent, down, slow or talking nonsense - and a throw
    # propagating from here would fail the whole report generation, making the optional layer
    # into a hard dependency by accident. Invoke-FxLlm already swallows its own failures; this
    # catches everything else, including a caller-supplied -Responder that throws.
    $raw = $null
    try {
        $prompt = ConvertTo-FxTriagePrompt -Facts $Facts
        $raw = if ($Responder) { & $Responder $prompt }
               else { Invoke-FxLlm -Prompt $prompt -Model $Model -BaseUri $BaseUri -TimeoutSec $TimeoutSec }
    } catch {
        $out.Reason = "triage failed: $($_.Exception.Message)"
        return $out
    }
    if (-not $raw) { $out.Reason = 'no response'; return $out }

    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json } catch { $out.Reason = 'response was not JSON'; return $out }
    if (-not $parsed -or -not $parsed.findings) { $out.Reason = 'no findings in response'; return $out }

    $kept = @()
    foreach ($f in @($parsed.findings)) {
        $proc = [string]$f.process
        $dir = [string]$f.directory
        if (-not $proc -or -not $dir -or -not $f.concern) { $out.Rejected++; continue }
        $leaf = ([IO.Path]::GetFileName($proc)).ToLowerInvariant()
        if (-not $okProc.ContainsKey($leaf)) { $out.Rejected++; continue }
        # The directory must be one we showed it, or an ANCESTOR of one. A model quoting a parent
        # is being imprecise; a model quoting somewhere never mentioned is making it up.
        #
        # This was a bare bidirectional prefix test, and an audit demonstrated it accepted two
        # things it is the entire point of this function to reject:
        #   - "C" and "C:" - a one-character citation is a prefix of every path we ever show, so
        #     any concern at all rendered as a lead while the panel truthfully reported
        #     "0 claim(s) discarded". The fence was open and said it was shut.
        #   - a CHILD of a shown directory, e.g. shown "...\.ssh", claimed
        #     "...\.ssh\exfiltrated-to-attacker". That is not imprecision in either direction;
        #     it is a specific invented location, which is the most dangerous shape here because
        #     it reads as the most authoritative.
        # So: exact match always passes; anything else must be a strict ancestor, must break on a
        # SEGMENT boundary, and must itself be specific enough to mean something.
        $dl = $dir.TrimEnd('\', '/').ToLowerInvariant()
        $dlSegments = @($dl -split '[\\/]' | Where-Object { $_ }).Count
        $dirOk = $false
        foreach ($d in $okDir) {
            if ($d -eq $dl) { $dirOk = $true; break }
            # Strict ancestor, on a separator boundary so "C:\Users\Ad" cannot match
            # "C:\Users\Admin", and at least three segments so a drive or "C:\Users" cannot
            # stand in as a citation for everything beneath it.
            if ($dlSegments -ge 3 -and $d.StartsWith($dl + '\')) { $dirOk = $true; break }
        }
        if (-not $dirOk) { $out.Rejected++; continue }
        # Normalise the CASE rather than discarding it: "HIGH" is a valid answer typed loudly,
        # not an invalid one. -notin is case-insensitive, so the old form let "HIGH" through
        # unnormalised and rendered it verbatim into the page.
        $conf = ([string]$f.confidence).Trim().ToLowerInvariant()
        if ($conf -notin @('low', 'medium', 'high')) { $conf = 'low' }
        $kept += [pscustomobject]@{ Process = $proc; Directory = $dir; Concern = [string]$f.concern; Confidence = $conf }
    }
    $out.Findings = @($kept | Select-Object -First 4)
    if (-not $out.Findings.Count -and $out.Rejected) { $out.Reason = 'every finding cited something it was not shown' }
    return $out
}
