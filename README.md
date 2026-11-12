# Portable Firefox (Windows ZIP, system policies disabled)

Files here are meant to be copied into the Firefox source tree
(e.g. `C:\mozilla-source\firefox`) and `launch.bat` into the extracted build.

## 1. Environment
1. Install MozillaBuild (default `C:\mozilla-build`), run `start-shell.bat`.
2. Bootstrap:
   ```
   mkdir -p /c/mozilla-source && cd /c/mozilla-source
   wget https://raw.githubusercontent.com/mozilla-firefox/firefox/refs/heads/main/python/mozboot/bin/bootstrap.py
   python3 bootstrap.py
   ```
   Choose **Firefox for Desktop** (full build), NOT Artifact Mode.

## 2. Policy bypass
- **Option A** (all system policies): copy `mozconfig` to the source root as `mozconfig`.
  Verify the flag exists first: `grep -rn "policies" build/moz.configure browser/moz.configure`.
  If unknown, configure only warns and policies stay active; use Option B.
- **Option B** (only DisableDeveloperTools): in
  `browser/components/enterprisepolicies/Policies.sys.mjs` make it a no-op:
  ```js
  DisableDeveloperTools: {
    onBeforeAddons(manager, param) {
      // Intentionally ignored in this private build.
    },
  },
  ```
  Check `remote/components/Marionette.sys.mjs` doesn't force `remote.policy.disabled`.
  Copy `mozconfig.optionB` to `mozconfig`.

## 3. Build and package
```
./mach build
./mach package
```
Output: `obj-portable/dist/firefox-<version>.en-US.win64.zip`.

## 4. Make portable
Extract the ZIP (e.g. `D:\Apps\FirefoxPortable\`), put `launch.bat` next to
`firefox.exe`. It uses `-no-remote -profile <dir>\profile`.

## 5. Verify
- `about:policies` Active tab should be empty with Option A.
- Recent Firefox (~141+) removed CDP; `--remote-debugging-port` now serves
  WebDriver BiDi, so `http://127.0.0.1:9222/json/version` may not respond.
  Use a BiDi/WebSocket client instead.

## CI
`.github/workflows/build-windows.yml` (manual `workflow_dispatch`) runs steps 1-4 on a
Windows runner and uploads `firefox-portable-win64`. It is untested. Standard
`windows-latest` runners have too little disk/time for a full build; pass a large or
self-hosted runner label via the `runner` input.
