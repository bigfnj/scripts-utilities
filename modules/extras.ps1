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
    $items  = @(Get-CatalogTools -Group "extras")
    $failed = 0
    foreach ($item in $items) {
        $ok = Install-CatalogItem -Item $item
        if (-not $ok) {
            $failed++
            if ($item.name -eq "pytoshop") {
                Write-Warn "pytoshop not installed - PSD authoring unavailable"
            } else {
                Write-Warn "install failed: $($item.name) [$($item.channel) $($item.id)]"
            }
        }
    }
    # This loop already had the right per-item shape; what it did not do was
    # AGGREGATE, so every item could fail and "extras group complete" still printed.
    if ($failed -eq 0) {
        Write-Ok "extras group complete ($($items.Count) tools)"
    } else {
        Write-Err "extras group INCOMPLETE: $failed of $($items.Count) failed to install (see the warnings above)"
    }
    # RETURNED, not just printed. Write-Err is Write-Host - it produces no error
    # record - so a caller has no way to know this group failed unless the count
    # travels. Without this, bootstrap.ps1 printed "bootstrap complete" after a run
    # in which every single install failed.
    return $failed
}
