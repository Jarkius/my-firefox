# Portable Firefox for Windows x64 (system policies ignored)

Builds a self-contained Firefox ZIP that ignores enterprise policies set in the
Windows registry (GPO), with DevTools and the Remote Agent always available.

## Quick start (spare Windows laptop)

One-time prerequisites:
1. Install [MozillaBuild](https://wiki.mozilla.org/MozillaBuild) (default `C:\mozilla-build`).
2. Install [Git for Windows](https://git-scm.com/download/win).
3. Have about 50 GB free on `C:` and preferably 16 GB+ RAM.

Then open `C:\mozilla-build\start-shell.bat` and run:

```sh
cd /c
git clone https://github.com/Jarkius/my-firefox.git
cd my-firefox
./build-portable.sh
```

The first run clones the Firefox source to `C:\mozilla-source\firefox`, installs
the toolchains (`mach bootstrap`), and compiles everything. Expect several hours.
The result is `dist\FirefoxPortable-<version>-win64.zip`.

Extract it anywhere and run `firefox\launch.bat`.

### Options

| Option | Meaning |
|---|---|
| `--policy all` (default) | Ignore all registry/GPO policies, and ignore `DisableDeveloperTools` from any source. |
| `--policy devtools` | Keep registry/GPO policies (proxy, certificates, etc.); only ignore `DisableDeveloperTools`. |
| `--ref <branch/tag>` | Firefox version to build, e.g. `release` or `FIREFOX_150_0_RELEASE`. Default `main` (Nightly). |
| `--update` | Fetch `--ref` again into an existing checkout (discards local source edits). |
| `--skip-bootstrap` | Skip `mach bootstrap` on later runs. |
| `--clobber` | Full rebuild from scratch. |
| `--src DIR`, `--out DIR` | Source checkout and output locations. |

Later rebuilds reuse the checkout and the object directory, so they are much faster:
`./build-portable.sh --skip-bootstrap`.

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
| `build-portable.sh` | End-to-end build script (run in the MozillaBuild shell). |
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
