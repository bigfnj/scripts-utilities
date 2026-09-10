# cli-tools - developer CLI tools that close the Linux/Windows capability gap.
#
# Tool definitions (winget IDs, binaries, notes) live in catalog.json and are
# installed via lib/catalog.ps1. Verify an ID with `winget search <name>` if an
# install fails after a package rename, then fix it in catalog.json.

# Printed by 'bootstrap.ps1 -List' and by get.ps1 - i.e. BEFORE the user agrees to
# anything - so it has to name what will actually be installed. It listed 13 tools
# while the catalog group held 15, quietly omitting pwsh (a MACHINE-scope install
# that needs elevation) and curl-libressl. Invoke-InstallerTests.ps1 now fails if
# this string and the catalog group drift apart again.
function cli-tools_desc { "gh, pwsh, fzf, bat, delta, just, hyperfine, sops, age, tokei, podman, docker-compose, curl-libressl, yt-dlp, deno" }

function cli-tools_install {
    $failed = Install-CatalogGroup -Group "cli-tools"
    $total  = @(Get-CatalogTools -Group "cli-tools").Count
    if ($failed -eq 0) {
        Write-Ok "cli-tools group complete ($total tools)"
    } else {
        Write-Err "cli-tools group INCOMPLETE: $failed of $total failed to install (see the warnings above)"
    }
    # RETURNED, not just printed. Write-Err is Write-Host - it produces no error
    # record - so a caller has no way to know this group failed unless the count
    # travels. Without this, bootstrap.ps1 printed "bootstrap complete" after a run
    # in which every single install failed.
    return $failed
}
