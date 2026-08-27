# Fresh Workstation Setup Checklist

Use this runbook when replacing the Windows workstation. It is intentionally
non-destructive: the old machine remains the rollback source until the new one
passes verification.

## 1. Before retiring the old workstation

Back up or transfer user-owned state this repository does not manage:

- Git repositories and uncommitted work.
- SSH keys, age/SOPS keys, signing keys, and Git configuration.
- Application credentials and CLI authentication through each product's
  supported export or sign-in flow. Do not copy opaque credential databases.
- Project `.env` files and secrets through an encrypted channel.
- Browser profiles, editor settings, fonts, licenses, and private datasets.
- WSL distributions or data, if still required.

Do not copy `%LOCALAPPDATA%\DevToolbox` as the installation method. Rebuild it
so executable paths and manifests match the new Windows profile.

## 2. Prepare Windows

Complete Windows Update, install current GPU drivers when applicable, and
install Microsoft App Installer. Verify in a normal Windows PowerShell prompt:

```powershell
git --version
winget --version
```

## 3. Clone and inspect

```powershell
git clone https://github.com/bigfnj/scripts-utilities.git
Set-Location .\scripts-utilities
git status --short --branch
.\bootstrap.ps1 -List
.\fresh-toolbox-setup-runner.ps1 -DryRun
```

Use a durable local path, not a temporary download folder or WSL UNC path.

## 4. Provision

Optional first: several native runtime packages (LibreOffice, Tesseract, QPDF,
ImageMagick, 7-Zip, Node.js LTS, Wireshark) are machine-scope only and each
prompts for UAC during a normal-user run. To collapse those into a single
elevation, run this once with an admin/SYSTEM token before the runner; the
runner then detects them present and skips them silently:

```powershell
.\scripts\install-machine-scope.ps1
```

If you drive elevation through a SYSTEM helper that detaches from your shell,
pass `-LogPath` and read the log afterwards (it ends with a `DONE (...)`
sentinel):

```powershell
.\scripts\install-machine-scope.ps1 -LogPath C:\Users\Public\ms-install.log
```

Then provision as the normal user:

```powershell
.\fresh-toolbox-setup-runner.ps1
```

Optional variants:

```powershell
.\fresh-toolbox-setup-runner.ps1 -SkipHeavy
.\fresh-toolbox-setup-runner.ps1 -SkipWireshark
.\fresh-toolbox-setup-runner.ps1 -InstallGhidra
.\fresh-toolbox-setup-runner.ps1 -SkipHeavy -SkipPlaywrightBrowsers
```

Run from a normal prompt. Let individual installers request UAC when necessary.
Keep `logs\fresh-workstation` if a step fails.

## 5. Verify

The runner executes the repository smoke test. Confirm zero failures, then:

```powershell
$toolbox = Join-Path $env:LOCALAPPDATA "DevToolbox"
& "$toolbox\python\.venv\Scripts\python.exe" -m pip check
Get-Content "$toolbox\toolbox-manifest.json" -Raw | ConvertFrom-Json |
    Select-Object schema_version, created_at, root
. "$toolbox\scripts\Activate-CodexToolbox.ps1"
python --version
rg --version
```

If heavy packages were installed, review the generated heavy smoke report under
`%LOCALAPPDATA%\DevToolbox\notes\smoke`. CUDA depends on the new GPU and driver.

## 6. Restore user state deliberately

Restore projects and secrets only after the base smoke test passes.
Reauthenticate `gh`, cloud CLIs, editors, and other applications through
supported sign-in flows. Test a representative Git fetch/push and encrypted
secret decrypt before retiring the old workstation.

Keep the old workstation or a verified backup intact until the new machine has
completed normal work for several days.
