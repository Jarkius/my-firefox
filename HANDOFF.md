# Handoff: make the automated build work on Windows

You are an agent on a Windows 10/11 x64 machine. Your job: make the automated
portable Firefox build in this repo work end to end. When a script fails, fix
it, until a working portable Firefox is produced and verified.

## What the repo does

- **`build.ps1` / `build.cmd`:** the single entry point.
  1. Checks the machine (64-bit, disk, RAM, battery).
  2. Installs Git for Windows and MozillaBuild (`C:\mozilla-build`) if missing.
  3. Clones this repo to `C:\my-firefox` when run from the one-liner.
  4. Runs `build-portable.sh` in MozillaBuild's MSYS2 bash
     (`MSYSTEM=MINGW64`, `MSYS2_PATH_TYPE=inherit`), keeping the PC awake.
     The log goes to `C:\my-firefox\logs\build-*.log`.
  5. Extracts the result to `C:\FirefoxPortable\firefox`, keeping any existing
     profile, and creates a "Firefox Portable" desktop shortcut.
- **`build-portable.sh`:**
  1. Shallow-clones `mozilla-firefox/firefox` to `C:\mozilla-source\firefox`.
  2. Runs `./mach --no-interactive bootstrap --application-choice=browser`.
  3. Copies `mozconfig` (for `--policy all`) or `mozconfig.optionB`
     (for `--policy devtools`).
  4. Patches the source with `tools/customize.py`.
  5. Runs `mach build` and `mach package`.
  6. Assembles and verifies the portable ZIP in `dist\`.
- **`tools/customize.py`:**
  - `EnterprisePoliciesParent.sys.mjs`: `if (AppConstants.MOZ_SYSTEM_POLICIES)`
    becomes `if (false && ...)`, which disables the Windows GPO/registry
    provider. Applied in `all` mode only.
  - `Policies.sys.mjs`: the body of `DisableDeveloperTools.onBeforeAddons`
    becomes a no-op. That policy also sets `remote.policy.disabled`. Applied in
    both modes.
  - Patching fails loudly if the upstream code no longer matches.
  - `verify` reads the `omni.ja` files inside the final ZIP to confirm that the
    patches are present.
- **`mozconfig`:** `--disable-system-policies`, `--enable-release`,
  `--disable-updater`, `--disable-maintenance-service`, objdir `obj-portable`.

## Current status

The first real Windows run found two problems. They are fixed on branch
**`fix/windows-first-run`**, which is not merged into `main` yet:

1. `build.ps1`: Windows PowerShell 5.1 strips embedded double quotes from
   native-command arguments, which broke `bash -lc "<string>"`. The fix writes
   the command to `logs\run-build.sh` and runs that file instead.
2. `mozconfig*`: `MOZ_PARALLEL_BUILD=4`, because unlimited parallel
   rustc/clang jobs exhausted RAM (`STATUS_DLL_INIT_FAILED`).

**Work on `fix/windows-first-run`**, not `main`:

```powershell
cd C:\my-firefox
git fetch origin
git checkout fix/windows-first-run
git pull
```

Not yet confirmed to work on Windows:
- whether the build now completes with the two fixes
- `mach package` and the assemble step
- whether Python's `zipfile` can read Mozilla's `omni.ja`. If it can't, verify
  prints `? skipped` instead of failing; find another way to confirm the
  patches.
- install, the desktop shortcut, and keeping the profile on a rebuild
- all the runtime checks below

Things the scripts can't handle yet and may need: Defender slowdowns (ask
before changing any security setting), and a bootstrap that prompts or asks for
Visual Studio components.

## Steps

1. Run `C:\my-firefox\build.cmd` from the `fix/windows-first-run` checkout.
   Re-runs are incremental. Use `-Update` (refresh the source) or `-Clobber`
   (full rebuild) only when needed.
2. On failure:
   1. Read the newest log in `C:\my-firefox\logs`.
   2. Find the root cause.
   3. Fix the scripts in this repo. Don't hand-edit the Firefox source: the
      build must stay reproducible from a clean machine.
   4. Re-run.
3. Keep each fix minimal, one commit per problem, and explain the cause in the
   commit message. Push to `fix/windows-first-run`. Never push to `main`; the
   owner reviews and merges.
4. When a build succeeds, verify each of these and report the result:
   - a. The verify step printed `ok` for every patch, or you explained each
     `? skipped` and confirmed that patch another way.
   - b. The "Firefox Portable" shortcut launches Firefox with
     `C:\FirefoxPortable\firefox\profile` (check `about:profiles`).
   - c. Registry policies are ignored. With `--policy all`, set a test GPO:
     `HKLM\SOFTWARE\Policies\Mozilla\Firefox`, `DisableDeveloperTools = 1`
     (DWORD). Confirm that the portable build's `about:policies` shows no
     active policy while an installed Firefox, if any, obeys it. Remove the
     test key afterwards.
   - d. DevTools (F12) opens.
   - e. Remote debugging listens on `127.0.0.1:9222`. This is WebDriver BiDi:
     Firefox removed CDP, so `/json/version` may not exist. Check with
     `netstat -ano | findstr 9222` or a BiDi client.
   - f. Re-running `build.cmd` keeps the existing profile.
5. Don't weaken or remove the patches. Don't skip or loosen the verify step to
   get a green result. Don't change Defender or other security settings without
   asking the owner.

## Final report

- What failed, why, and how you fixed it (with commit links).
- Results of checks a to f.
- Total build time and the machine specs (CPU threads, RAM).
- Anything still unverified.

Then update the **Current status** section of this file to match, on the same
branch.
