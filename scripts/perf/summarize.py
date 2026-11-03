# Licensed under GPL-3.0. See LICENSE.
#
# Summarizes the traces trace-screen-share.sh records, pass by pass:
#   python3 scripts/perf/summarize.py ~/Desktop/nook-traces-...
# CPU time per process (Nook, its WebKit helpers, WindowServer), the heaviest functions in Nook and
# WindowServer, hitches, and SwiftUI updates, so a share pass can be read against the baseline.

import collections
import pathlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

TOP = 12


def export(trace, xpath=None):
    args = ["xcrun", "xctrace", "export", "--input", str(trace)]
    args += ["--xpath", xpath] if xpath else ["--toc"]
    result = subprocess.run(args, capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else ""


def schemas(trace):
    toc = export(trace)
    return [t.get("schema") for t in ET.fromstring(toc).iter("table")] if toc else []


def rows(trace, schema):
    """Each row's columns with xctrace's id/ref deduplication resolved."""
    xml = export(trace, f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]')
    if not xml:
        return
    seen = {}
    for row in ET.fromstring(xml).iter("row"):
        for element in row.iter():
            if element.get("id"):
                seen[element.get("id")] = element
        yield [resolve(c, seen) for c in row]


def value(element):
    text = (element.text or "").strip()
    return int(text) if text.isdigit() else 0


def resolve(element, seen):
    return seen.get(element.get("ref"), element) if element is not None and element.get("ref") else element


def process_name(thread, seen):
    process = resolve(thread.find("process"), seen) if thread is not None else None
    label = process.get("fmt", "") if process is not None else ""
    return re.sub(r"\s*\(\d+\)$", "", label) or "?"


def leaf(backtrace, seen):
    frame = resolve(backtrace.find("frame"), seen) if backtrace is not None else None
    return frame.get("name", "?") if frame is not None else "?"


def time_profile(trace):
    per_process = collections.Counter()
    per_symbol = collections.defaultdict(collections.Counter)
    xml = export(trace, '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]')
    if not xml:
        return None
    seen = {}
    for row in ET.fromstring(xml).iter("row"):
        for element in row.iter():
            if element.get("id"):
                seen[element.get("id")] = element
        columns = {c.tag: resolve(c, seen) for c in row}
        weight = value(columns["weight"]) if "weight" in columns else 1
        process = process_name(columns.get("thread"), seen)
        per_process[process] += weight
        if process.startswith(("Nook", "WindowServer", "com.apple.WebKit")):
            per_symbol[process][leaf(columns.get("backtrace"), seen)] += weight
    return per_process, per_symbol


def ms(nanoseconds):
    return f"{nanoseconds / 1e6:8.0f} ms"


def summarize_time_profile(trace):
    result = time_profile(trace)
    if not result:
        print("  (no time profile)")
        return
    per_process, per_symbol = result
    print("  CPU by process:")
    for process, weight in per_process.most_common(8):
        print(f"    {ms(weight)}  {process}")
    for process in sorted(per_symbol):
        if process.startswith(("Nook", "WindowServer")):
            print(f"  Heaviest leaf functions in {process}:")
            for symbol, weight in per_symbol[process].most_common(TOP):
                print(f"    {ms(weight)}  {symbol[:110]}")


def summarize_tables(trace, keyword):
    found = [s for s in schemas(trace) if keyword in s]
    if not found:
        print(f"  (no {keyword} tables)")
    for schema in found:
        count, kinds = 0, collections.Counter()
        duration = 0
        for columns in rows(trace, schema):
            count += 1
            for column in columns:
                if column.tag == "duration":
                    duration += value(column)
            labels = [c.get("fmt") for c in columns if c.get("fmt") and not c.tag.endswith(("time", "duration"))]
            if labels:
                kinds[labels[0][:90]] += 1
        extra = f", {ms(duration).strip()} in total" if duration else ""
        print(f"  {schema}: {count} rows{extra}")
        for label, n in kinds.most_common(6):
            print(f"    {n:6d}  {label}")


def main():
    folder = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    for pass_name in ("baseline", "share"):
        traces = sorted(folder.glob(f"{pass_name}-*.trace"))
        if not traces:
            continue
        print(f"=== {pass_name} ===")
        for trace in traces:
            print(f"- {trace.name}")
            if "time-profile" in trace.name:
                summarize_time_profile(trace)
            elif "hitches" in trace.name:
                summarize_tables(trace, "hitch")
            elif "swiftui" in trace.name:
                summarize_tables(trace, "swiftui")
    share_sim = folder / "share-sim.txt"
    if share_sim.exists():
        print("=== capture ===")
        print(share_sim.read_text().strip())


if __name__ == "__main__":
    main()
