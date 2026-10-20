# Source enumeration excludes protected names before descending into directories.
# Functions only. ListDirectory is injectable so pruning can be tested with names
# alone, without creating or accessing protected fixtures.
function Test-SUSourcePath {
    param([Parameter(Mandatory)][string]$Path)
    foreach ($part in ($Path -split '[\\/]')) {
        if ($part -ieq '.git' -or $part -ieq '.npmrc' -or
            $part -like '*.env' -or $part -like '.env.*' -or
            $part -like '*.pem' -or $part -like '*.key' -or
            $part -like '*.p12' -or $part -like '*.pfx' -or
            $part -like '*.keystore' -or $part -like 'privatekey*') {
            return $false
        }
    }
    return $true
}

function Get-SUSourceFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$Extension = @(),
        [string]$Filter = '*',
        [switch]$Recurse,
        [string[]]$ExcludeRelative = @(),
        [scriptblock]$RootMetadata = {
            param($Directory)
            Get-Item -LiteralPath $Directory -Force -ErrorAction Stop
        },
        [scriptblock]$ListDirectory = {
            param($Directory)
            Get-ChildItem -LiteralPath $Directory -ErrorAction SilentlyContinue
        }
    )
    $rootPath = ([IO.Path]::GetFullPath($Root)).TrimEnd('\')
    if (-not (Test-SUSourcePath -Path $rootPath)) { throw 'Source root has a protected path component.' }
    $rootItem = $RootMetadata.Invoke($rootPath)
    if ($null -eq $rootItem -or -not $rootItem.PSIsContainer) { throw 'Source root must be an existing directory.' }
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Source root is a link or junction; refusing enumeration.' }
    $prefix = $rootPath + '\'
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($rootPath)
    while ($pending.Count) {
        $directory = $pending.Pop()
        foreach ($item in @($ListDirectory.Invoke($directory))) {
            $full = $item.FullName
            if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not (Test-SUSourcePath -Path $full)) { continue }
            # Never follow a link into another tree, including directory junctions.
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $relative = $full.Substring($prefix.Length)
            $excluded = $false
            foreach ($pattern in $ExcludeRelative) {
                if ($relative -like $pattern -or $relative -ieq $pattern.TrimEnd('\*')) {
                    $excluded = $true
                    break
                }
            }
            if ($excluded) { continue }
            if ($item.PSIsContainer) {
                if ($Recurse) { $pending.Push($full) }
                continue
            }
            if ($Extension.Count -and $Extension -notcontains $item.Extension) { continue }
            if ($item.Name -notlike $Filter) { continue }
            $item
        }
    }
}
