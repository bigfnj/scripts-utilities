# extras - remaining Tier 4 gap-fills.
#
# markdownlint-cli (npm global), jupyterlab / sqlite-utils / csvkit / pytoshop
# (toolbox venv pip). These are small additions that round out the toolbox
# without introducing new heavy dependencies.

function extras_desc { "markdownlint-cli (npm), jupyterlab + sqlite-utils + csvkit + pytoshop (toolbox venv)" }

function extras_install {
    # Tool definitions live in catalog.json. pytoshop is an import-only library
    # with no CLI, so it sets register_manifest=false there (the manifest's
    # Phase-1 binary check would otherwise fail); it is validated by the
    # toolbox-venv import check in scripts/smoke-test.ps1.
    foreach ($item in (Get-CatalogTools -Group "extras")) {
        $ok = Install-CatalogItem -Item $item
        if (-not $ok -and $item.name -eq "pytoshop") {
            Write-Warn "pytoshop not installed - PSD authoring unavailable"
        }
    }
    Write-Ok "extras group complete"
}
