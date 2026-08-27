# cli-tools - developer CLI tools that close the Linux/Windows capability gap.
#
# Tool definitions (winget IDs, binaries, notes) live in catalog.json and are
# installed via lib/catalog.ps1. Verify an ID with `winget search <name>` if an
# install fails after a package rename, then fix it in catalog.json.

function cli-tools_desc { "gh, fzf, bat, delta, just, hyperfine, sops, age, tokei, podman, docker-compose, yt-dlp, deno" }

function cli-tools_install {
    Install-CatalogGroup -Group "cli-tools"
    Write-Ok "cli-tools group complete"
}
