#Requires -Version 5.1
<#
    SysmonConfig.ps1 - rendering and validating the deletion-forensics Sysmon config.

    Separate from install-deletion-forensics.ps1 for the same reason ForensicsReport.Core.ps1
    is separate from the report generator: the installer is a script whose top-level code
    self-elevates and changes machine state, so nothing can import it to test a function. A
    validator that has never been shown to reject anything is not a validator.

    WHY A TEMPLATE AT ALL. Sysmon cannot do this itself. Its condition set is a fixed list -
    is, is not, contains, begin with, end with, image, and a handful more - with no
    environment-variable expansion, no wildcard and no per-user construct anywhere in the
    schema (checked against `Sysmon64.exe -s`, schema 4.91). Two of the three include rules
    could be written machine-agnostically as `contains \AppData\Local\` and
    `contains \Documents\`, but the third - a dot-directory immediately under a profile root -
    cannot be expressed in that grammar, so substitution is required rather than convenient.

    Tested by: tests\Invoke-InstallerTests.ps1
#>

function Get-RenderedSysmonConfig {
    <#
        The template with |USERPROFILE| substituted. Returns TEXT, so the result can be linted
        and compared before anything touches ProgramData.

        A literal .Replace, never [Environment]::ExpandEnvironmentVariables: that would also
        expand a legitimate %VAR% inside a path rule, and under RunAs it expands the
        administrator's profile rather than the interactive user's - which is the exact trap
        this whole change exists to close.
    #>
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$ProfilePath
    )
    $t = [IO.File]::ReadAllText($TemplatePath)
    return $t.Replace('|USERPROFILE|', $ProfilePath.TrimEnd('\'))
}

function Test-RenderedSysmonConfig {
    <#
        Refuse to deploy a config that cannot work. Returns a list of problems; empty is good.

        Sysmon offers no offline validation - applying is the only true parse - so these are
        the checks available without touching the running sensor. The include-prefix check is
        the one that would actually have caught the original bug: for a year the rules named a
        profile that exists on exactly one machine, and everywhere else they matched nothing
        while -Verify reported fully green. Matching nothing and recording nothing are
        indistinguishable in every report downstream.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$ProfilePath,
        # Test seam. Supply a predicate so the suite can describe a filesystem that does not
        # exist here, rather than depending on this machine's directory layout.
        [scriptblock]$DirectoryExists = { param($p) Test-Path -LiteralPath $p -PathType Container }
    )
    $problems = New-Object 'System.Collections.Generic.List[string]'

    $xml = $null
    try { $xml = [xml]$Text } catch { $problems.Add("not well-formed XML: $($_.Exception.Message)") }

    # A pipe is illegal in every Windows path, so a survivor is unambiguously an unrendered
    # placeholder and never data. That total, machine-checkable assertion is the entire reason
    # the token is |USERPROFILE| and not {{USERPROFILE}} or %USERPROFILE% - braces and percent
    # signs are both legal in real paths, so neither would permit this check.
    if ($Text -match '\|') { $problems.Add('an unsubstituted |PLACEHOLDER| survived rendering') }

    if ($xml) {
        $inc = @($xml.SelectNodes("//FileDeleteDetected[@onmatch='include']/TargetFilename"))
        if ($inc.Count -eq 0) {
            $problems.Add('no FileDeleteDetected include rules - the sensor would record nothing')
        }
        foreach ($n in $inc) {
            $prefix = ([string]$n.InnerText).TrimEnd('\')
            # The rules deliberately end mid-name - "<profile>\." catches every dot-directory -
            # so test the deepest component that is supposed to be a real directory.
            $dir = if (& $DirectoryExists $prefix) { $prefix } else { Split-Path $prefix -Parent }
            if (-not (& $DirectoryExists $dir)) {
                $problems.Add("include rule points at a directory that does not exist: $prefix")
            }
        }
    }

    if ($ProfilePath -and -not (& $DirectoryExists $ProfilePath.TrimEnd('\'))) {
        $problems.Add("profile directory does not exist: $ProfilePath")
    }
    return $problems.ToArray()
}
