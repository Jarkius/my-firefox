#!/usr/bin/env bash
# Build a custom portable Firefox for Windows x64.
#
# Run inside the MozillaBuild shell (C:\mozilla-build\start-shell.bat):
#   cd /c/path/to/my-firefox
#   ./build-portable.sh                 # default: ignore all system policies
#   ./build-portable.sh --policy devtools
#
# Steps: clone/update Firefox source, mach bootstrap, write mozconfig,
# patch the source, mach build, mach package, assemble + verify portable ZIP.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY=all
REF=main
SRC=/c/mozilla-source/firefox
OUT="$HERE/dist"
REPO=https://github.com/mozilla-firefox/firefox.git
UPDATE=0
BOOTSTRAP=1
CLOBBER=0

usage() {
  cat <<EOF
Usage: $0 [options]
  --policy all|devtools  all: ignore registry/GPO policies (and DisableDeveloperTools);
                         devtools: keep other policies, only ignore DisableDeveloperTools
                         (default: $POLICY)
  --ref REF              Firefox branch or tag to build (default: $REF)
  --src DIR              Firefox source checkout (default: $SRC)
  --out DIR              Where the portable ZIP goes (default: $OUT)
  --update               Fetch REF again into an existing checkout (discards local edits)
  --skip-bootstrap       Skip './mach bootstrap' (after the first successful run)
  --clobber              Full rebuild ('./mach clobber' first)
  -h, --help             Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --policy) POLICY="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --src) SRC="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --update) UPDATE=1; shift ;;
    --skip-bootstrap) BOOTSTRAP=0; shift ;;
    --clobber) CLOBBER=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$POLICY" in all|devtools) ;; *) echo "--policy must be all or devtools" >&2; exit 2 ;; esac

step() { printf '\n==> %s\n' "$*"; }

case "$(uname -s)" in
  MINGW*|MSYS*) ;;
  *) echo "Run this from the MozillaBuild shell on Windows (C:\\mozilla-build\\start-shell.bat)." >&2; exit 1 ;;
esac
command -v git >/dev/null || { echo "git not found: install Git for Windows and reopen the MozillaBuild shell." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found: is this the MozillaBuild shell?" >&2; exit 1; }

# Accept Windows paths (C:\foo) as well as MSYS paths (/c/foo).
SRC="$(cygpath -u "$SRC")"
OUT="$(cygpath -u "$OUT")"
win() { cygpath -w "$1"; }   # for MozillaBuild's native Windows python3

PATCHED_FILES=(
  toolkit/components/enterprisepolicies/EnterprisePoliciesParent.sys.mjs
  browser/components/enterprisepolicies/Policies.sys.mjs
)

step "Firefox source ($REF) in $SRC"
if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$(dirname "$SRC")"
  git clone --depth 1 --branch "$REF" "$REPO" "$SRC"
elif [ "$UPDATE" = 1 ]; then
  git -C "$SRC" fetch --depth 1 origin "$REF"
  git -C "$SRC" checkout -f FETCH_HEAD
else
  echo "Using existing checkout at $(git -C "$SRC" rev-parse --short HEAD) (pass --update to refresh)"
  # Undo our previous patches so they are reapplied cleanly.
  git -C "$SRC" checkout -- "${PATCHED_FILES[@]}"
fi

cd "$SRC"

if [ "$BOOTSTRAP" = 1 ]; then
  step "Bootstrap toolchains (full build, not artifact mode)"
  ./mach --no-interactive bootstrap --application-choice=browser
fi

step "mozconfig (policy: $POLICY)"
if [ "$POLICY" = all ]; then
  cp "$HERE/mozconfig" "$SRC/mozconfig"
else
  cp "$HERE/mozconfig.optionB" "$SRC/mozconfig"
fi
cat "$SRC/mozconfig"

step "Patch source"
python3 "$(win "$HERE/tools/customize.py")" patch --src "$(win "$SRC")" --policy "$POLICY"
git --no-pager diff --stat

if [ "$CLOBBER" = 1 ]; then
  step "Clobber"
  ./mach clobber
fi

step "Build (this takes a while)"
./mach build

step "Package"
./mach package

step "Assemble portable ZIP"
python3 "$(win "$HERE/tools/customize.py")" assemble \
  --objdir "$(win "$SRC/obj-portable")" \
  --launcher "$(win "$HERE/launch.bat")" \
  --out "$(win "$OUT")" \
  --policy "$POLICY"

step "Done"
echo "Extract the ZIP anywhere and run firefox\\launch.bat."
