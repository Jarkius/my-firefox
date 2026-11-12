# Portable Firefox for Windows x64 (system policies ignored)

Builds a self-contained Firefox ZIP that ignores enterprise policies set in the
Windows registry (GPO), with DevTools and the Remote Agent always available.

## Quick start: fully automated (spare Windows laptop)

On a Windows 10/11 x64 PC with about 50 GB free on `C:`, open **PowerShell** and run:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Jarkius/my-firefox/main/build.ps1)))
```

Or, if you already cloned or downloaded this repo, double-click **`build.cmd`**.

That's it. `build.ps1` then does everything unattended:

1. Checks the machine (64-bit, disk space, RAM, warns if on battery).
2. Installs **Git for Windows** and **MozillaBuild** if they're missing. You
   approve one UAC prompt for each; nothing else needs input.
3. Clones this repo to `C:\my-firefox` (only when run via the one-liner).
4. Runs `build-portable.sh` in the MozillaBuild shell: clones the Firefox
   source to `C:\mozilla-source\firefox`, runs `mach bootstrap`, patches the
   source, then builds, packages, assembles and verifies.
5. Extracts the result to `C:\FirefoxPortable\firefox` and adds a
   **Firefox Portable** shortcut to the desktop.

The PC is kept awake for the whole build, and output goes to `logs\build-*.log`.
The first run takes several hours. It is safe to re-run after a failure:
the source checkout, toolchains and build output are reused. A rebuild keeps
your existing portable profile (bookmarks, logins).

Tip: excluding `C:\mozilla-source` and `C:\mozilla-build` from Microsoft
Defender real-time scanning makes the build much faster. The script does not
change security settings for you.

### Options

Pass them to `build.cmd` / `build.ps1`, e.g. `build.cmd -Policy devtools -Ref release`.
With the one-liner, append them after the closing parenthesis.

| Option | Meaning |
|---|---|
| `-Policy all` (default) | Ignore all registry/GPO policies, and ignore `DisableDeveloperTools` from any source. |
| `-Policy devtools` | Keep registry/GPO policies (proxy, certificates, etc.); only ignore `DisableDeveloperTools`. |
| `-Ref <branch/tag>` | Firefox version, e.g. `release` or `FIREFOX_150_0_RELEASE`. Default `main` (Nightly). |
| `-Update` | Fetch `-Ref` again into the existing source checkout. |
| `-Clobber` | Full rebuild from scratch. |
| `-InstallDir DIR` | Where to extract the result (default `C:\FirefoxPortable`). |
| `-NoInstall` | Only produce the ZIP in `dist\`; no extraction or shortcut. |
| `-SrcDir DIR` | Firefox source checkout (default `C:\mozilla-source\firefox`; no spaces). |
| `-Force` | Continue even when the free-space check fails. |

### Manual mode

Inside the MozillaBuild shell (`C:\mozilla-build\start-shell.bat`) you can run
the build step directly: `./build-portable.sh --help`. It takes the same options
in lowercase form (`--policy`, `--ref`, `--update`, `--clobber`, `--skip-bootstrap`).

## What the script changes

`build-portable.sh` drives `tools/customize.py`:

- **`--policy all`**
  - `mozconfig` adds `--disable-system-policies`. That sets
    `AppConstants.MOZ_SYSTEM_POLICIES` to false.
  - `toolkit/components/enterprisepolicies/EnterprisePoliciesParent.sys.mjs`:
    the `if (AppConstants.MOZ_SYSTEM_POLICIES)` that adds the Windows GPO
    provider becomes `if (false && ...)`, a second safeguard.
  - The `DisableDeveloperTools` patch below is also applied, so a
    `distribution\policies.json` can't lock DevTools either.
- **Both modes**: `browser/components/enterprisepolicies/Policies.sys.mjs`
  replaces the body of `DisableDeveloperTools.onBeforeAddons` with a no-op. That
  policy is also what sets `remote.policy.disabled`, which blocks Marionette and
  the Remote Agent.

Patching stops with an error if the upstream code no longer matches, instead
of building an unpatched browser. After packaging, the script opens the
`omni.ja` archives inside the ZIP and checks that the patches are really there.

## Files

| File | Purpose |
|---|---|
| `build.cmd` / `build.ps1` | Fully automated entry point: prerequisites, build, install, shortcut. |
| `build-portable.sh` | The build itself (run in the MozillaBuild shell; called by `build.ps1`). |
| `tools/customize.py` | Source patches, portable ZIP assembly, verification. |
| `mozconfig` / `mozconfig.optionB` | Build config for `--policy all` / `--policy devtools`. |
| `launch.bat` | Starts Firefox with `-no-remote -profile <folder>\profile --remote-debugging-port=9222`. |
| `.github/workflows/build-windows.yml` | Same build on GitHub Actions (needs a big runner). |

## Verify on the laptop

- `about:policies`: with `--policy all`, the Active tab should be empty even
  when registry GPOs exist (unless you add a `distribution\policies.json`).
- DevTools (F12) should open.
- Recent Firefox (~141+) removed CDP. `--remote-debugging-port` now serves
  WebDriver BiDi, so `http://127.0.0.1:9222/json/version` may not respond; use a
  BiDi client (e.g. Puppeteer with `browser: "firefox"`, or Selenium BiDi).

## CI

`.github/workflows/build-windows.yml` (manual `workflow_dispatch`) installs
MozillaBuild and runs `build-portable.sh`, then uploads the ZIP as an artifact.
Standard `windows-latest` runners have too little disk and time for a full
build; pass a large or self-hosted runner label in the `runner` input.
