#Requires -Version 5.1
<#
DevToolbox installer GUI - a thin WinForms front-end over the existing scripts.

It renders catalog.json as grouped checkboxes with live status, plus toggles for
the toolbox layers and optional components, and drives the real work by shelling
out to fresh-toolbox-setup-runner.ps1 / install-*.ps1 / uninstall-toolbox.ps1.
No install logic lives here - the GUI only composes a selection and streams the
child process output into the log pane.

  powershell -NoProfile -ExecutionPolicy Bypass -File gui\toolbox-gui.ps1
  ... -SelfTest      # build the form and exit (headless construction check)
#>
[CmdletBinding()]
param([switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$REPO_ROOT = Split-Path $PSScriptRoot
. (Join-Path $REPO_ROOT "lib\common.ps1")
. (Join-Path $REPO_ROOT "lib\catalog.ps1")

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Runner    = Join-Path $REPO_ROOT "fresh-toolbox-setup-runner.ps1"
$Uninstall = Join-Path $REPO_ROOT "scripts\uninstall-toolbox.ps1"
$catalog   = Get-Catalog
# Per-tool checkboxes for the installable groups; the LLM runtime is driven by its
# own toggle (below), not a per-tool box.
$tools     = @($catalog.tools | Where-Object { $_.group -ne 'llm' })
$groups    = @($tools | Select-Object -ExpandProperty group -Unique)

# -- Form scaffold -------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "DevToolbox Installer"
$form.Size = New-Object System.Drawing.Size(860, 640)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(720, 520)

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = "Fill"
$split.Orientation = "Horizontal"
$form.Controls.Add($split)

# Elevation status banner (docked top; added after the split so it wins the top
# edge and the split fills below).
$banner = New-Object System.Windows.Forms.Label
$banner.Dock = "Top"; $banner.Height = 30; $banner.TextAlign = "MiddleLeft"
$banner.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$banner.ForeColor = [System.Drawing.Color]::White
$banner.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$banner.Text = "  Elevation: (not checked yet)"
$form.Controls.Add($banner)

# Probe the RunAS Helper CLI gate WITHOUT launching anything: the "validate" verb
# runs the same gate check but only validates the token (no CreateProcess). A
# closed gate replies "Command line is disabled..."; an open gate streams
# validation logs. Absent service/pipe => unavailable. All three mean the same
# thing for us at the top level: only 'open' avoids UAC prompts.
function Test-RunAsGate {
    param([int]$ConnectMs = 1200, [int]$IoMs = 4000)
    try { if (-not ([System.IO.Directory]::GetFiles("\\.\pipe\") -match 'RunAsHelper')) { return 'unavailable' } } catch { }
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', 'RunAsHelper', [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
    try { $pipe.Connect($ConnectMs) } catch { return 'unavailable' }
    $cts = New-Object System.Threading.CancellationTokenSource; $cts.CancelAfter($IoMs)
    function ReadN($p, $n, $tok) { $buf = New-Object byte[] $n; $off = 0; while ($off -lt $n) { $t = $p.ReadAsync($buf, $off, $n - $off, $tok); try { $t.Wait() } catch { return $null }; $c = $t.Result; if ($c -le 0) { return $null }; $off += $c }; return $buf }
    try {
        $json = '{"CommandLine":"validate","Priority":1,"Verb":"validate","WorkingDirectory":"","ShowWindow":1,"Account":"ti","Source":"cli"}'
        $body = [System.Text.Encoding]::UTF8.GetBytes($json)
        $pipe.Write([System.BitConverter]::GetBytes([int]$body.Length), 0, 4); $pipe.Write($body, 0, $body.Length); $pipe.Flush()
        $got = $false; $closed = $false
        for ($i = 0; $i -lt 12; $i++) {
            $lb = ReadN $pipe 4 $cts.Token; if (-not $lb) { break }
            $l = [System.BitConverter]::ToInt32($lb, 0); if ($l -le 0 -or $l -gt 1mb) { break }
            $bb = ReadN $pipe $l $cts.Token; if (-not $bb) { break }
            $s = [System.Text.Encoding]::UTF8.GetString($bb, 0, $bb.Length); $got = $true
            if ($s -match 'Command line is disabled|gate closed') { $closed = $true }
            if ($s -match '"Type":"result"') { break }
        }
        if ($closed) { return 'closed' } elseif ($got) { return 'open' } else { return 'unavailable' }
    } finally { $pipe.Dispose() }
}

function Update-GateBanner {
    $banner.Text = "  Elevation: checking RunAS gate..."
    $banner.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $form.Refresh()
    switch (Test-RunAsGate) {
        'open' {
            $banner.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 0)
            $banner.Text = "  Elevation: RunAS gate OPEN - machine-scope installs run elevated, no UAC prompts."
        }
        'closed' {
            $banner.BackColor = [System.Drawing.Color]::FromArgb(176, 0, 0)
            $banner.Text = "  Elevation: RunAS gate CLOSED - machine-scope installs will FALL BACK TO UAC prompts.  Open it: tray -> Activate -> Settings -> Allow command line."
        }
        default {
            $banner.BackColor = [System.Drawing.Color]::FromArgb(176, 0, 0)
            $banner.Text = "  Elevation: RunAS helper NOT reachable (service stopped / not installed) - machine-scope installs will use UAC prompts."
        }
    }
}

# SplitterDistance must be set once the container has real dimensions, or it
# throws on an unsized control - do it on Shown, and run the gate pre-check then.
$form.Add_Shown({ try { $split.SplitterDistance = 340 } catch { }; try { Update-GateBanner } catch { } })

# Top: a scrolling panel of group boxes + toggles
$top = New-Object System.Windows.Forms.FlowLayoutPanel
$top.Dock = "Fill"; $top.AutoScroll = $true; $top.WrapContents = $false; $top.FlowDirection = "TopDown"
$split.Panel1.Controls.Add($top)

$script:toolChecks = @{}   # name -> CheckBox

function New-ToolGroupBox {
    param([string]$Group)
    $gb = New-Object System.Windows.Forms.GroupBox
    $gb.Text = $Group
    $gb.AutoSize = $true; $gb.AutoSizeMode = "GrowAndShrink"
    $flp = New-Object System.Windows.Forms.FlowLayoutPanel
    $flp.FlowDirection = "TopDown"; $flp.AutoSize = $true; $flp.WrapContents = $false
    $flp.Location = New-Object System.Drawing.Point(8, 18)
    foreach ($t in ($tools | Where-Object { $_.group -eq $Group })) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.AutoSize = $true
        $cb.Checked = [bool]$t.default
        $cb.Text = "{0}  -  {1}" -f $t.name, $t.notes
        $cb.Tag = $t.name
        $script:toolChecks[$t.name] = $cb
        $flp.Controls.Add($cb)
    }
    $gb.Controls.Add($flp)
    return $gb
}

foreach ($g in $groups) { $top.Controls.Add((New-ToolGroupBox -Group $g)) }

# Toggles for layers / optional components
$optBox = New-Object System.Windows.Forms.GroupBox
$optBox.Text = "Toolbox layers & optional components"
$optBox.AutoSize = $true; $optBox.AutoSizeMode = "GrowAndShrink"
$optFlp = New-Object System.Windows.Forms.FlowLayoutPanel
$optFlp.FlowDirection = "TopDown"; $optFlp.AutoSize = $true; $optFlp.WrapContents = $false
$optFlp.Location = New-Object System.Drawing.Point(8, 18)
function New-Toggle { param([string]$Text, [bool]$Checked)
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.AutoSize = $true; $cb.Text = $Text; $cb.Checked = $Checked
    $optFlp.Controls.Add($cb); return $cb
}
$chkHeavy      = New-Toggle "Heavy GPU/ML stack (torch CUDA, onnxruntime-gpu, ...)" $true
$chkPlaywright = New-Toggle "Playwright browsers (Chromium/Firefox/WebKit)" $true
$chkWireshark  = New-Toggle "Wireshark / tshark (machine-scope, UAC)" $true
$chkGhidra     = New-Toggle "Ghidra + portable JDK (optional RE suite)" $false
$chkLlm        = New-Toggle "Local LLM stack (Ollama + models + reranker)" $false
$optBox.Controls.Add($optFlp)
$top.Controls.Add($optBox)

# Bottom: buttons + log
$bottom = New-Object System.Windows.Forms.Panel
$bottom.Dock = "Fill"
$split.Panel2.Controls.Add($bottom)

$btnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$btnPanel.Dock = "Top"; $btnPanel.Height = 40; $btnPanel.WrapContents = $false
$bottom.Controls.Add($btnPanel)

$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = "Both"; $log.WordWrap = $false
$log.Dock = "Fill"; $log.BackColor = [System.Drawing.Color]::Black
$log.ForeColor = [System.Drawing.Color]::Gainsboro
$log.Font = New-Object System.Drawing.Font("Consolas", 9)
$bottom.Controls.Add($log)
$log.BringToFront()

function Add-Log { param([string]$Text) $log.AppendText($Text + "`r`n") }

# -- Child-process streaming ---------------------------------------------------
function Invoke-Streamed {
    param([string]$File, [string[]]$ScriptArgs)
    $argLine = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$File`"") + $ScriptArgs
    Add-Log ("`r`n>>> powershell {0}" -f ($argLine -join ' '))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command powershell.exe).Source
    $psi.Arguments = ($argLine -join ' ')
    $psi.WorkingDirectory = $REPO_ROOT
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    while (-not $proc.HasExited) {
        while (-not $proc.StandardOutput.EndOfStream) {
            Add-Log $proc.StandardOutput.ReadLine()
            [System.Windows.Forms.Application]::DoEvents()
        }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 40
    }
    $tailOut = $proc.StandardOutput.ReadToEnd(); if ($tailOut) { Add-Log $tailOut.TrimEnd() }
    $tailErr = $proc.StandardError.ReadToEnd();  if ($tailErr) { Add-Log $tailErr.TrimEnd() }
    Add-Log ("<<< exit {0}" -f $proc.ExitCode)
    return $proc.ExitCode
}

function Get-RunnerArgs {
    $a = @()
    if (-not $chkHeavy.Checked)      { $a += "-SkipHeavy" }
    if (-not $chkPlaywright.Checked) { $a += "-SkipPlaywrightBrowsers" }
    if ($chkWireshark.Checked -eq $false) { $a += "-SkipWireshark" }
    if ($chkGhidra.Checked)          { $a += "-InstallGhidra" }
    if ($chkLlm.Checked)             { $a += "-InstallLlm" }
    return $a
}

function Set-Busy {
    param([bool]$Busy)
    foreach ($b in $btnPanel.Controls) { $b.Enabled = -not $Busy }
    $form.Cursor = if ($Busy) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }
}

# -- Buttons -------------------------------------------------------------------
function New-Button { param([string]$Text, [int]$Width, [scriptblock]$OnClick)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Width = $Width; $b.Height = 28
    $b.Add_Click($OnClick)
    $btnPanel.Controls.Add($b); return $b
}

$null = New-Button "Test elevation" 110 {
    Set-Busy $true
    try { Update-GateBanner; Add-Log "elevation re-checked" } finally { Set-Busy $false }
}

$null = New-Button "Refresh status" 110 {
    Set-Busy $true
    try {
        foreach ($t in $tools) {
            $state = Get-CatalogItemState -Item $t
            $cb = $script:toolChecks[$t.name]
            $cb.ForeColor = if ($state.installed) { [System.Drawing.Color]::ForestGreen } else { [System.Drawing.Color]::DimGray }
        }
        Add-Log "status refreshed (green = present on this machine)"
    } finally { Set-Busy $false }
}

$null = New-Button "Dry run" 90 {
    Set-Busy $true
    try { Invoke-Streamed -File $Runner -ScriptArgs (@("-DryRun") + (Get-RunnerArgs)) | Out-Null }
    finally { Set-Busy $false }
}

$null = New-Button "Install / Update" 120 {
    Set-Busy $true
    try { Invoke-Streamed -File $Runner -ScriptArgs (Get-RunnerArgs) | Out-Null }
    finally { Set-Busy $false }
}

$null = New-Button "Install selected only" 140 {
    # Advanced: install just the checked gap-fill tools via Install-CatalogItem
    # (winget/npm resolve standalone; pip-toolbox items need the venv to exist).
    Set-Busy $true
    try {
        $names = @($script:toolChecks.Values | Where-Object { $_.Checked } | ForEach-Object { $_.Tag })
        if (-not $names) { Add-Log "no tools checked"; return }
        $csv = ($names | ForEach-Object { "'$_'" }) -join ','
        $cmd = ". '$REPO_ROOT\lib\common.ps1'; . '$REPO_ROOT\lib\catalog.ps1'; foreach (`$n in @($csv)) { Install-CatalogItem -Item (Get-CatalogItem -Name `$n) | Out-Null }"
        # -File cannot take an inline command, so run this one via -Command:
        $argLine = @("-NoProfile","-ExecutionPolicy","Bypass","-Command", "`"$cmd`"")
        Add-Log ("`r`n>>> powershell -Command <install " + ($names -join ', ') + ">")
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Command powershell.exe).Source
        $psi.Arguments = ($argLine -join ' ')
        $psi.WorkingDirectory = $REPO_ROOT
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        while (-not $p.HasExited) { while (-not $p.StandardOutput.EndOfStream) { Add-Log $p.StandardOutput.ReadLine(); [System.Windows.Forms.Application]::DoEvents() }; [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
        $t2 = $p.StandardError.ReadToEnd(); if ($t2) { Add-Log $t2.TrimEnd() }
        Add-Log ("<<< exit {0}" -f $p.ExitCode)
    } finally { Set-Busy $false }
}

$null = New-Button "Uninstall..." 90 {
    $removeTools = [System.Windows.Forms.MessageBox]::Show(
        "Remove the whole toolbox.`n`nAlso uninstall the gap-fill tools this toolbox installed (winget/npm)?`n`nYes = also remove tools   No = toolbox layer only   Cancel = abort",
        "Confirm uninstall", "YesNoCancel", "Warning")
    if ($removeTools -eq "Cancel") { return }
    Set-Busy $true
    try {
        $a = @("-Yes")
        if ($removeTools -eq "Yes") { $a += "-RemoveWingetTools" }
        Invoke-Streamed -File $Uninstall -ScriptArgs $a | Out-Null
    } finally { Set-Busy $false }
}

Add-Log "DevToolbox Installer - $($tools.Count) tools across $($groups.Count) groups."
Add-Log "Buttons run the repo scripts and stream output here. 'Dry run' changes nothing."

if ($SelfTest) {
    Write-Host "selftest ok: form built, $($tools.Count) tools, $($groups.Count) groups, $($btnPanel.Controls.Count) buttons"
    $form.Dispose()
    exit 0
}

[void]$form.ShowDialog()
