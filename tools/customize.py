#!/usr/bin/env python3
"""Source patches and packaging helpers for the portable Firefox build.

Subcommands:
  patch     Apply the policy patches to a Firefox source tree.
  assemble  Turn the `mach package` ZIP into a portable ZIP with launch.bat.
  verify    Check that a built ZIP actually contains the patches.

Only the standard library is used, so it runs with MozillaBuild's python3.
"""

import argparse
import glob
import os
import re
import shutil
import sys
import zipfile

PARENT = "toolkit/components/enterprisepolicies/EnterprisePoliciesParent.sys.mjs"
POLICIES = "browser/components/enterprisepolicies/Policies.sys.mjs"

# Gate around the Windows GPO / macOS providers in _buildProvider().
SYSTEM_GATE = "if (AppConstants.MOZ_SYSTEM_POLICIES) {"
SYSTEM_GATE_PATCHED = (
    "// Portable build: never read policies from the Windows registry or macOS.\n"
    "    if (false && AppConstants.MOZ_SYSTEM_POLICIES) {"
)

DEVTOOLS_BODY = (
    "\n      // Portable build: DisableDeveloperTools is intentionally ignored.\n    "
)


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def read(path):
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def matching_brace(text, open_idx):
    """Index of the '}' matching the '{' at open_idx (skips strings/comments)."""
    depth = 0
    i = open_idx
    n = len(text)
    while i < n:
        c = text[i]
        if c in "\"'`":
            q = c
            i += 1
            while i < n and text[i] != q:
                i += 2 if text[i] == "\\" else 1
        elif text.startswith("//", i):
            i = text.find("\n", i)
            if i < 0:
                break
        elif text.startswith("/*", i):
            i = text.find("*/", i) + 1
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    die("unbalanced braces while patching")


def devtools_method_span(text):
    """(start, end) of the body of DisableDeveloperTools.onBeforeAddons."""
    m = re.search(r"\n  DisableDeveloperTools: \{", text)
    if not m:
        return None
    block_end = matching_brace(text, m.end() - 1)
    mm = re.compile(r"onBeforeAddons\(manager, param\) \{").search(
        text, m.end(), block_end
    )
    if not mm:
        return None
    body_open = mm.end() - 1
    return body_open + 1, matching_brace(text, body_open)


def patch_system_policies(src):
    path = os.path.join(src, PARENT)
    text = read(path)
    if SYSTEM_GATE_PATCHED in text:
        print(f"  already patched: {PARENT}")
        return
    if text.count(SYSTEM_GATE) != 1:
        die(
            f"expected exactly one '{SYSTEM_GATE}' in {PARENT}; "
            "upstream code changed, update tools/customize.py"
        )
    write(path, text.replace(SYSTEM_GATE, SYSTEM_GATE_PATCHED))
    print(f"  patched: {PARENT} (registry/GPO provider disabled)")


def patch_devtools(src):
    path = os.path.join(src, POLICIES)
    text = read(path)
    span = devtools_method_span(text)
    if not span:
        die(f"DisableDeveloperTools.onBeforeAddons not found in {POLICIES}")
    start, end = span
    if text[start:end] == DEVTOOLS_BODY:
        print(f"  already patched: {POLICIES}")
        return
    write(path, text[:start] + DEVTOOLS_BODY + text[end:])
    print(f"  patched: {POLICIES} (DisableDeveloperTools is a no-op)")


def cmd_patch(args):
    src = args.src
    if not os.path.isfile(os.path.join(src, "mach")):
        die(f"{src} is not a Firefox source tree")
    print(f"Applying '{args.policy}' patches to {src}")
    if args.policy == "all":
        patch_system_policies(src)
    # Also ignore DisableDeveloperTools from policies.json in 'all' mode, so
    # DevTools and the Remote Agent stay available whatever the policy source.
    patch_devtools(src)


def find_package(objdir):
    zips = [
        z
        for z in glob.glob(os.path.join(objdir, "dist", "firefox-*.zip"))
        if not re.search(r"\.(tests|crashreporter-symbols|.*symbols)\b", z)
    ]
    if not zips:
        die(f"no firefox-*.zip in {objdir}/dist; did './mach package' run?")
    return max(zips, key=os.path.getmtime)


def cmd_assemble(args):
    pkg = find_package(args.objdir)
    name = os.path.basename(pkg)
    m = re.match(r"firefox-(.+?)\.[a-z]{2}(-[A-Z]{2})?\.(win64(-aarch64)?)\.zip$", name)
    version = m.group(1) if m else "custom"
    os.makedirs(args.out, exist_ok=True)
    stage = os.path.join(args.out, f"FirefoxPortable-{version}-win64")
    if os.path.exists(stage):
        shutil.rmtree(stage)
    os.makedirs(stage)
    print(f"Extracting {name}")
    with zipfile.ZipFile(pkg) as z:
        z.extractall(stage)
    app = os.path.join(stage, "firefox")
    if not os.path.isfile(os.path.join(app, "firefox.exe")):
        die("firefox.exe not found in package")
    shutil.copy(args.launcher, os.path.join(app, "launch.bat"))
    os.makedirs(os.path.join(app, "profile"), exist_ok=True)
    out_zip = shutil.make_archive(stage, "zip", stage, "firefox")
    print(f"Portable folder: {app}")
    print(f"Portable ZIP:    {out_zip}")
    if args.verify:
        verify_zip(out_zip, args.policy)


def omni_read(outer, inner_omni, member):
    """Read a file from an omni.ja inside the outer ZIP, or None."""
    import io

    try:
        with outer.open(inner_omni) as f:
            data = f.read()
        with zipfile.ZipFile(io.BytesIO(data)) as omni:
            return omni.read(member).decode("utf-8", "replace")
    except (KeyError, zipfile.BadZipFile):
        return None


def verify_zip(path, policy):
    print(f"Verifying {os.path.basename(path)} ({policy})")
    ok = True
    with zipfile.ZipFile(path) as z:
        parent = omni_read(z, "firefox/omni.ja", "modules/EnterprisePoliciesParent.sys.mjs")
        consts = omni_read(z, "firefox/omni.ja", "modules/AppConstants.sys.mjs")
        pol = omni_read(z, "firefox/browser/omni.ja", "modules/policies/Policies.sys.mjs")
    if policy == "all":
        if consts is None:
            print("  ? AppConstants.sys.mjs not readable, skipped")
        elif re.search(r"MOZ_SYSTEM_POLICIES:\s*false", consts):
            print("  ok MOZ_SYSTEM_POLICIES is false (--disable-system-policies applied)")
        else:
            print("  !! MOZ_SYSTEM_POLICIES is not false")
            ok = False
        if parent is None:
            print("  ? EnterprisePoliciesParent.sys.mjs not readable, skipped")
        elif "false && AppConstants.MOZ_SYSTEM_POLICIES" in parent:
            print("  ok registry/GPO provider patched out")
        else:
            print("  !! registry/GPO provider patch missing")
            ok = False
    if pol is None:
        print("  ? Policies.sys.mjs not readable, skipped")
    else:
        span = devtools_method_span(pol)
        if span and "devtools.policy.disabled" not in pol[span[0]:span[1]]:
            print("  ok DisableDeveloperTools is a no-op")
        else:
            print("  !! DisableDeveloperTools patch missing")
            ok = False
    if not ok:
        die("verification failed")


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("patch")
    sp.add_argument("--src", required=True)
    sp.add_argument("--policy", choices=["all", "devtools"], default="all")
    sp.set_defaults(func=cmd_patch)

    sa = sub.add_parser("assemble")
    sa.add_argument("--objdir", required=True)
    sa.add_argument("--launcher", required=True)
    sa.add_argument("--out", required=True)
    sa.add_argument("--policy", choices=["all", "devtools"], default="all")
    sa.add_argument("--no-verify", dest="verify", action="store_false")
    sa.set_defaults(func=cmd_assemble)

    sv = sub.add_parser("verify")
    sv.add_argument("zip")
    sv.add_argument("--policy", choices=["all", "devtools"], default="all")
    sv.set_defaults(func=lambda a: verify_zip(a.zip, a.policy))

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
