#!/usr/bin/env python3
"""Audit that every platform.json parameter is wired through the components that
need it.

Two layers:

  1. DETERMINISTIC generation chain (hard pass/fail) --
     platform.json key -> CMakeLists.txt parse -> src/platform_config.vh.in
     `define -> a `PLATFORM_* macro actually used in synthesizable RTL. This
     chain is mechanical, so a break here is a real bug (a parsed-but-unemitted
     value, a defined-but-unused macro, or a dead key nothing reads).

  2. REFERENCE MAP (advisory) -- for each parameter, which component buckets
     mention it. The script seeds needles from the macro name and the
     platform_config.py constant(s) derived from the key, then expands them
     transitively across the scanned files (so re-exports like
     DEFAULT_BAUD = UART_BAUD and template vars like {{ default_baud }} are
     followed). A blank cell is NOT necessarily a bug: whether a given bucket is
     *required* depends on the parameter's kind -- see SKILL.md's expectation
     table. The script reports facts; the agent applies that policy.

Usage:
    check_platform_config.py [--root DIR] [key ...]

With no key args, audits all parameters. Positional args filter to specific
keys (e.g. the one you just added: `check_platform_config.py addr_limit`).
"""

import argparse
import json
import os
import re
import sys

# Identifiers too generic to promote into needles (would over-match).
STOP = {"int", "str", "data", "val", "value", "self", "get", "if", "else",
        "is", "in", "for", "and", "or", "not", "true", "false", "none",
        "n", "i", "v", "c", "p", "r", "kwargs", "args", "isinstance"}

# Component buckets: (label, predicate(relpath) -> bool). Order = display order.
def _is(*names):
    names = set(names)
    return lambda p: os.path.basename(p) in names

DEVTEST_FILES = {"test_device_hw.py", "test_device_conformance.py"}

BUCKETS = [
    ("RTL",          lambda p: p.startswith("src/") and p.endswith((".v", ".sv"))
                               and not p.endswith(("platform_config.vh", "platform_config.vh.in"))),
    ("sim-tests",    lambda p: p.startswith("sim/") and p.endswith((".v", ".sv"))),
    ("host-loader",  lambda p: p == "platform_config.py"),
    ("webapp",       lambda p: p.startswith("webapp/") and p.endswith(".py")
                               and "/tests/" not in p),
    ("webapp-front", lambda p: p.startswith("webapp/templates/") or p.startswith("webapp/static/")),
    ("web-tests",    lambda p: p.startswith("webapp/tests/") and p.endswith(".py")
                               and os.path.basename(p) not in DEVTEST_FILES),
    ("device-tests", lambda p: os.path.basename(p) in DEVTEST_FILES),
    ("scripts",      lambda p: p.startswith("scripts/") and p.endswith(".py")),
    ("docs",         lambda p: p.endswith(".md")),
]

SCAN_DIRS = ["src", "sim", "webapp", "scripts", "doc"]
SCAN_FILES = ["platform.json", "platform_config.py", "CMakeLists.txt",
              "README.md", "CLAUDE.md"]
SKIP_DIRS = {"node_modules", "__pycache__", ".git", "build", "impl"}


def collect_files(root):
    out = {}
    for f in SCAN_FILES:
        ap = os.path.join(root, f)
        if os.path.isfile(ap):
            out[f] = _read(ap)
    for d in SCAN_DIRS:
        base = os.path.join(root, d)
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [x for x in dirnames if x not in SKIP_DIRS]
            for fn in filenames:
                if not fn.endswith((".v", ".sv", ".vh", ".py", ".html", ".js", ".md", ".in")):
                    continue
                ap = os.path.join(dirpath, fn)
                rel = os.path.relpath(ap, root).replace(os.sep, "/")
                out[rel] = _read(ap)
    return out


def _read(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def flatten_params(cfg):
    """platform.json is two-level: section -> {key: value}."""
    params = []
    for section, body in cfg.items():
        if isinstance(body, dict):
            for key, value in body.items():
                params.append((section, key, value))
        else:  # tolerate a flat key
            params.append((None, section, body))
    return params


def py_key_to_consts(pyc):
    """Dataflow over platform_config.py: map each json key to the exported
    UPPER_CASE constants that ultimately derive from it (following local refs)."""
    direct, refs, assigned = {}, {}, set()
    for line in pyc.splitlines():
        m = re.match(r"\s*([A-Za-z_]\w*)\s*=\s*(.*)", line)
        if not m:
            continue
        name, rhs = m.group(1), m.group(2)
        assigned.add(name)
        direct.setdefault(name, set()).update(re.findall(r'\["([a-z_0-9]+)"\]', rhs))
        refs.setdefault(name, set()).update(re.findall(r"\b([A-Za-z_]\w*)\b", rhs))

    def keys_of(name, seen):
        if name in seen:
            return set()
        seen.add(name)
        ks = set(direct.get(name, ()))
        for r in refs.get(name, ()):
            if r in assigned:
                ks |= keys_of(r, seen)
        return ks

    k2c = {}
    for name in assigned:
        if name.startswith("_") or not name.isupper():
            continue
        for k in keys_of(name, set()):
            k2c.setdefault(k, set()).add(name)
    return k2c


def word_in(needle, text):
    return re.search(r"(?<![A-Za-z0-9_])" + re.escape(needle) + r"(?![A-Za-z0-9_])", text) is not None


def expand_needles(seeds, files):
    """Grow the host needle set by following ALL_CAPS re-export constants
    (DEFAULT_BAUD = UART_BAUD, REG_COUNT = MODBUS_ADDR_LIMIT, ...) so a value
    that ultimately comes from the platform constant is matched wherever the
    re-export is used. Only ALL_CAPS names are promoted: lowercase locals
    (reg_count, baud, slave) collide with unrelated code, and the genuinely
    user-facing lowercase indirection -- Jinja template vars -- is handled
    precisely via render_template() kwargs in template_vars()."""
    needles = set(seeds)
    py = {p: t for p, t in files.items() if p.endswith(".py")}
    for _ in range(4):  # a few hops to fixpoint in practice
        changed = False
        for text in py.values():
            for m in re.finditer(r"\b([A-Z][A-Z0-9_]{2,})\s*=\s*([^\n;]+)", text):
                lhs, rhs = m.group(1), m.group(2)
                if lhs in needles or lhs.lower() in STOP:
                    continue
                if any(word_in(n, rhs) for n in needles):
                    needles.add(lhs)
                    changed = True
        if not changed:
            break
    return needles


def template_vars(needles, files):
    """Template variables fed from a needle via render_template(..., var=EXPR).
    Lets the webapp-front bucket see {{ var }} that ultimately carries a platform
    constant, without promoting the collision-prone lowercase name globally."""
    out = set()
    for rel, text in files.items():
        if not (rel.startswith("webapp/") and rel.endswith(".py")):
            continue
        for call in re.finditer(r"render_template\((.*?)\)", text, re.DOTALL):
            for kw, rhs in re.findall(r"(\w+)\s*=\s*([^,)\n]+)", call.group(1)):
                if any(word_in(n, rhs) for n in needles):
                    out.add(kw)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=os.getcwd())
    ap.add_argument("keys", nargs="*", help="only audit these json keys")
    args = ap.parse_args()
    root = os.path.abspath(args.root)

    pj = os.path.join(root, "platform.json")
    if not os.path.isfile(pj):
        sys.exit(f"platform.json not found under {root}")
    cfg = json.loads(_read(pj))
    params = flatten_params(cfg)
    if args.keys:
        want = set(args.keys)
        params = [p for p in params if p[1] in want]
        if not params:
            sys.exit(f"none of {sorted(want)} found in platform.json")

    files = collect_files(root)
    cmake = files.get("CMakeLists.txt", "")
    key2var = {m.group(1): m.group(2) for m in
               re.finditer(r"platform_json_(?:int|hex|enum)\(\s*\"([^\"]+)\"\s+(\w+)", cmake)}
    vhin = files.get("src/platform_config.vh.in", "")
    emitted = dict(re.findall(r"`define\s+(\w+)\s+@(\w+)@", vhin))   # macro -> var
    emitted_vars = set(emitted.values())
    pyc = files.get("platform_config.py", "")
    k2consts = py_key_to_consts(pyc)

    hard_findings = []
    rows = []
    for section, key, value in params:
        var = key2var.get(key)
        consts = sorted(k2consts.get(key, ()))

        # ---- deterministic chain ----
        cmake_ok = var is not None
        vh_ok = bool(var) and var in emitted_vars
        rtl_files = []
        if var:
            for rel, text in files.items():
                if rel.startswith("src/") and rel.endswith((".v", ".sv")) \
                        and not rel.endswith(("platform_config.vh", "platform_config.vh.in")):
                    if word_in(var, text):
                        rtl_files.append(rel)
        rtl_ok = bool(rtl_files)
        loader_ok = word_in(f'"{key}"', pyc)

        # classify the chain
        if not cmake_ok and not consts and not loader_ok:
            hard_findings.append(f"[DEAD] '{key}': nothing reads it (no CMake parse, no host loader constant).")
        if cmake_ok and not vh_ok:
            hard_findings.append(f"[GAP]  '{key}': parsed in CMake ({var}) but not emitted in platform_config.vh.in.")
        if vh_ok and not rtl_ok:
            hard_findings.append(f"[WARN] '{key}': macro {var} is generated but never used in RTL (reserved, or a missing wire-up).")

        # ---- reference map ----
        # RTL/sim are matched by the macro; host buckets by the platform_config.py
        # constant(s) and their transitive re-exports; docs by any of the above.
        host_needles = expand_needles(set(consts), files) if consts else set()
        tvars = template_vars(host_needles, files) if host_needles else set()
        present = {}
        for label, pred in BUCKETS:
            hit = False
            for rel, text in files.items():
                if not pred(rel):
                    continue
                if label in ("RTL", "sim-tests"):
                    ok = bool(var) and word_in(var, text)
                elif label == "host-loader":
                    ok = word_in(f'"{key}"', text) or any(word_in(n, text) for n in host_needles)
                elif label == "webapp-front":
                    ok = any(word_in(n, text) for n in host_needles | tvars)
                elif label == "docs":
                    ok = word_in(key, text) or (var and word_in(var, text)) \
                         or any(word_in(n, text) for n in host_needles)
                else:  # webapp / web-tests / device-tests / scripts
                    ok = any(word_in(n, text) for n in host_needles)
                if ok:
                    hit = True
                    break
            present[label] = hit
        rows.append((section, key, var, consts, cmake_ok, vh_ok, rtl_ok, present))

    # ---- print ----
    print("Platform-config coverage audit")
    print("=" * 78)
    print(f"root: {root}")
    print(f"parameters audited: {len(rows)}\n")

    print("Generation chain (json -> CMake -> platform_config.vh.in -> RTL):")
    print(f"  {'parameter':<34}{'CMake':<7}{'vh.in':<7}{'RTL':<6}status")
    for section, key, var, consts, cmake_ok, vh_ok, rtl_ok, present in rows:
        name = f"{section}.{key}" if section else key
        status = "OK" if (cmake_ok and vh_ok and rtl_ok) else ("host-only" if (not cmake_ok and consts) else "CHECK")
        print(f"  {name:<34}{_yn(cmake_ok):<7}{_yn(vh_ok):<7}{_yn(rtl_ok):<6}{status}")

    print("\nReference map (component buckets that mention each parameter):")
    labels = [b[0] for b in BUCKETS]
    header = "  " + f"{'parameter':<32}" + "".join(f"{l[:12]:<13}" for l in labels)
    print(header)
    for section, key, var, consts, cmake_ok, vh_ok, rtl_ok, present in rows:
        name = f"{section}.{key}" if section else key
        cells = "".join(f"{('YES' if present[l] else chr(0x2014)):<13}" for l in labels)
        print(f"  {name:<32}{cells}")

    print("\nFindings:")
    if hard_findings:
        for f in hard_findings:
            print(f"  {f}")
    else:
        print("  generation chain intact for every parameter.")
    print("\nNote: a blank reference cell is only a problem if that bucket is")
    print("REQUIRED for the parameter's kind -- consult the expectation table in")
    print("SKILL.md and judge per parameter. The reference map follows re-exports")
    print("transitively but can still miss indirection; verify flagged buckets by")
    print("reading the code before concluding a component was missed.")


def _yn(b):
    return "yes" if b else "no"


if __name__ == "__main__":
    main()
