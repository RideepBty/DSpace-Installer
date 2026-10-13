#!/usr/bin/env python3
"""Summarise DSpace installer test runs recorded by record-run.sh.

Usage:
    python3 summarize-results.py FOLDER [--matrix test-matrix.csv] [--out summary.md]

FOLDER is searched for every results.csv (for example one copied back from each VM).
The summary is printed as Markdown and also saved to --out (default: FOLDER/summary.md).
"""
import argparse
import csv
import os
import re
import statistics
from collections import defaultdict

CHECKS = [("exit_code", "0", "exit"), ("api_local", "200", "API"), ("api_public", "200", "public API"),
          ("rest_url_localhost", "no", "localhost URL"), ("ui_local", "200", "UI"), ("login", "200", "login"),
          ("solr_search", "yes", "Solr")]
CLOUDS = {"oracle": "Oracle Cloud", "ibm": "IBM Cloud", "akamai": "Akamai",
          "aws": "AWS", "azure": "Azure", "gcp": "Google Cloud"}
ROBUST = re.compile(r"-(rerun|int\d*|resume|reboot)(-\d+)?$")
REPEAT = re.compile(r"-r\d+(-\d+)?$")
PRACTICE = re.compile(r"-p\d+(-\d+)?$")


def load(folder):
    rows, seen = [], set()
    for root, _, files in os.walk(folder):
        if "results.csv" not in files:
            continue
        with open(os.path.join(root, "results.csv"), newline="", encoding="utf-8", errors="replace") as f:
            for r in csv.DictReader(f):
                key = (r.get("run_id"), r.get("date_utc"), r.get("start_utc"), r.get("provider"))
                if key in seen:
                    continue
                seen.add(key)
                r["_dir"] = os.path.join(root, r.get("run_id", ""))
                rows.append(r)
    return rows


def installer(r):
    src = r.get("installer", "")
    m = re.search(r"install-dspace(\d+)\.sh", src)
    if m:
        return "DSpace " + m.group(1)
    m = re.search(r"-d(\d+)-", r.get("label", ""))
    return ("DSpace " + m.group(1)) if m else (src or "?")


def ubuntu(r):
    m = re.search(r"(\d+\.\d+)", r.get("os", ""))
    return m.group(1) if m else "?"


def minutes(r):
    try:
        return float(r.get("minutes", ""))
    except ValueError:
        return None


def vm_type(r):
    """The cloud's VM type, or vCPUs and RAM when the metadata service gave no type."""
    return r.get("instance_type") or f"{r.get('vcpus', '?')} vCPU, {r.get('ram_gb', '?')} GB"


def failed_checks(r):
    return ", ".join(name for key, ok, name in CHECKS
                     if not (r.get("kind") == "check" and key == "exit_code") and r.get(key, "") != ok)


def table(head, body):
    out = ["| " + " | ".join(head) + " |", "| " + " | ".join("---" for _ in head) + " |"]
    out += ["| " + " | ".join(str(c) for c in row) + " |" for row in body]
    return "\n".join(out)


def fmt(x):
    return f"{x:.0f}" if x is not None else ""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", nargs="?", default=".")
    ap.add_argument("--matrix")
    ap.add_argument("--out")
    a = ap.parse_args()
    rows = load(a.folder)
    if not rows:
        raise SystemExit(f"No results.csv found under {a.folder}")
    out = []
    rebuild = [r for r in rows if r.get("label", "").startswith("rebuild")]
    cloud = [r for r in rows if r.get("provider") in CLOUDS and r not in rebuild
             and not PRACTICE.search(r.get("label", ""))]
    other = [r for r in rows if r not in cloud and r not in rebuild]
    installs = [r for r in cloud if r.get("kind") == "install"]
    passed = [r for r in installs if r.get("pass") == "yes"]
    out.append(f"# Test-run summary\n\nCloud: {len(cloud)} recorded runs, of which {len(installs)} full installs "
               f"and {len(passed)} passed all checks. Practice runs ({len(other)}) and AI-rebuild runs "
               f"({len(rebuild)}) are listed separately at the end.")

    # 1. The reported matrix: cloud installs labelled -r1, -r2, ...
    groups = defaultdict(list)
    for r in installs:
        if r.get("provider") in CLOUDS and REPEAT.search(r.get("label", "")):
            groups[(CLOUDS[r["provider"]], ubuntu(r), installer(r))].append(r)
    body = []
    for key in sorted(groups):
        g = groups[key]
        ok = [r for r in g if r.get("pass") == "yes"]
        mins = [m for m in (minutes(r) for r in ok) if m is not None]
        rng = f"{fmt(min(mins))}-{fmt(max(mins))}" if mins else ""
        itypes = ", ".join(sorted({vm_type(r) for r in g}))
        body.append([*key, itypes, len(g), len(ok), fmt(statistics.median(mins)) if mins else "", rng])
    out.append("\n## Results by cloud, Ubuntu release and installer\n\n" + (table(
        ["Cloud", "Ubuntu", "Installer", "VM type", "Runs", "Passed", "Median minutes", "Range"], body)
        if body else "No cloud runs labelled -r1, -r2 ... yet."))

    # 2. Failed full installs
    fails = [r for r in installs if r.get("pass") != "yes"]
    out.append("\n## Failed cloud installs\n\n" + (table(
        ["Run", "Exit code", "Last installer step", "Checks not passed", "Note"],
        [[r["run_id"], r.get("exit_code", ""), r.get("last_stage", ""), failed_checks(r), r.get("note", "")]
         for r in fails]) if fails else "None."))

    # 3. Robustness: re-run, interrupted, resumed and post-reboot runs
    rob = [r for r in cloud if ROBUST.search(r.get("label", ""))]
    out.append("\n## Re-run, interruption and reboot tests\n\n" + (table(
        ["Run", "Kind", "Passed", "Exit code", "URIEncoding count", "Nested webapp", "Checks not passed"],
        [[r["run_id"], r.get("kind", ""), r.get("pass", ""), r.get("exit_code", ""),
          r.get("uriencoding_count", ""), r.get("nested_webapp", ""),
          "" if r.get("kind") == "interrupted" else failed_checks(r)] for r in rob]) if rob else "None yet."))

    # 4. Time per installer step (passing cloud installs)
    per_stage = defaultdict(list)
    order = {}
    for r in passed:
        if r.get("provider") not in CLOUDS:
            continue
        path = os.path.join(r["_dir"], "stages.csv")
        if not os.path.exists(path):
            continue
        with open(path, newline="", encoding="utf-8", errors="replace") as f:
            for s in csv.DictReader(f):
                k = (installer(r), s["stage"])
                per_stage[k].append(float(s["minutes"]))
                order.setdefault(k, int(s["stage_no"]))
    if per_stage:
        body = [[k[0], k[1], len(v), f"{statistics.median(v):.1f}", f"{max(v):.1f}"]
                for k, v in sorted(per_stage.items(), key=lambda kv: (kv[0][0], order[kv[0]]))]
        out.append("\n## Minutes per installer step (passing cloud installs)\n\n" +
                   table(["Installer", "Step", "Runs", "Median", "Max"], body))

    # 5. Practice runs (local VMs, and -p1 runs on each cloud) and AI-rebuild runs, kept apart from the reported runs
    for title, group in (("Practice runs", other), ("AI-rebuild runs", rebuild)):
        if group:
            out.append(f"\n## {title}\n\n" + table(
                ["Run", "Kind", "Passed", "Minutes", "Exit code", "Last installer step", "Checks not passed"],
                [[r["run_id"], r.get("kind", ""), r.get("pass", ""), r.get("minutes", ""), r.get("exit_code", ""),
                  r.get("last_stage", ""), "" if r.get("kind") == "interrupted" else failed_checks(r)]
                 for r in group]))

    # 6. Matrix coverage
    if a.matrix:
        with open(a.matrix, newline="", encoding="utf-8") as f:
            planned = [m for m in csv.DictReader(f) if m.get("reported", "yes") == "yes"]
        done = {r.get("label") for r in rows}
        ok = {r.get("label") for r in rows if r.get("pass") == "yes" or r.get("kind") == "interrupted"}
        missing = [m["label"] for m in planned if m["label"] not in done]
        retry = [m["label"] for m in planned if m["label"] in done and m["label"] not in ok]
        out.append(f"\n## Matrix coverage\n\n{len(planned) - len(missing)} of {len(planned)} planned runs "
                   f"recorded.\n\n- Not run yet: {', '.join(missing) or 'none'}\n"
                   f"- Recorded but not passed: {', '.join(retry) or 'none'}")

    text = "\n".join(out) + "\n"
    print(text)
    dest = a.out or os.path.join(a.folder, "summary.md")
    with open(dest, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"Saved to {dest}")


if __name__ == "__main__":
    main()
