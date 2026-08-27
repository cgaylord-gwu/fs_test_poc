#!/usr/bin/env python3
"""
Parse IOR and mdtest output files in this directory and append one row per
run to results.csv. Safe to re-run repeatedly (monthly, post-change, etc.)
-- it only appends rows for files it hasn't seen before, tracked via a
.parsed_files marker.

Usage:
    python3 parse_results.py
"""

import re
import csv
import glob
import os
from datetime import datetime

RESULTS_CSV = "results.csv"
PARSED_MARKER = ".parsed_files"

# Schema notes:
#
# This stays long-format (one row per metric observation) so it drops
# straight into R (read.csv / readr::read_csv), pandas, or gnuplot
# (`plot 'results.csv' using ...` with `set datafile separator ','`)
# with zero reshaping.
#
# Two fields exist specifically to make Zabbix ingestion mechanical later,
# without changing this schema again:
#   - epoch_ts   : unix timestamp, which is what zabbix_sender wants for
#                  historical/backfilled sends (`-T` mode); human timestamp
#                  is kept alongside it for readability in R/Python/gnuplot.
#   - metric_key : a stable dotted key (e.g. scratch.ior.write.mean_mibs)
#                  built the same way every time, suitable to use directly
#                  as (or to derive 1:1) a Zabbix trapper item key. Keeping
#                  key construction here means send_to_zabbix.py and any
#                  future Zabbix item config are just reading a column, not
#                  re-deriving naming logic.
#   - run_id     : groups rows that came from the same benchmark invocation
#                  (multiple operations/block sizes in one file share a
#                  run_id), useful for both a Zabbix "run completed" marker
#                  and for grouping in R/pandas without re-parsing source_file.
CSV_FIELDS = [
    "timestamp", "epoch_ts", "run_id", "run_type", "source_file", "test_label",
    "operation", "metric_key", "max_mib_s", "mean_mib_s", "iops",
    "nodes", "tasks",
]


def make_metric_key(run_type, test_label, operation):
    """
    Build a stable, Zabbix-safe dotted key from run metadata.
    e.g. ior.write.block_size_1m_transfer_size_1m
         mdtest.file_creation
    Zabbix item keys tolerate alnum + underscore/dot cleanly; avoid spaces,
    parens, commas.
    """
    def slug(s):
        s = s.strip().lower()
        s = re.sub(r"[^a-z0-9]+", "_", s)
        return s.strip("_")

    parts = [run_type, slug(operation)]
    if test_label and test_label != run_type and test_label != "mdtest":
        parts.append(slug(test_label))
    return "scratch." + ".".join(p for p in parts if p)


def load_parsed():
    if not os.path.exists(PARSED_MARKER):
        return set()
    with open(PARSED_MARKER) as f:
        return set(line.strip() for line in f if line.strip())


def save_parsed(parsed):
    with open(PARSED_MARKER, "w") as f:
        f.write("\n".join(sorted(parsed)) + "\n")


def parse_ior_file(path):
    """
    IOR summary lines look like:
    write     1234.56    1200.00    ...    12345   0   1.234567  EXCEL
    Extract operation, Max(MiB), Mean(MiB) from the 'Results:' table.
    Falls back gracefully if IOR version formats this table differently.
    """
    rows = []
    with open(path, errors="replace") as f:
        text = f.read()

    # find each labeled section (--- Block size ... ---) so we can tag rows
    sections = re.split(r"^--- (.+?) ---$", text, flags=re.MULTILINE)
    # sections[0] is preamble, then alternating (label, body)
    labeled_bodies = []
    if len(sections) > 1:
        for i in range(1, len(sections), 2):
            label = sections[i].strip()
            body = sections[i + 1] if i + 1 < len(sections) else ""
            labeled_bodies.append((label, body))
    else:
        labeled_bodies = [("run", text)]

    for label, body in labeled_bodies:
        # IOR 4.x output has TWO tables per test that both have lines
        # starting with "write"/"read": the per-test "Results:" table
        # (columns: access bw(MiB/s) IOPS Latency(s) ...) and the
        # "Summary of all tests:" table (columns: Operation Max(MiB)
        # Min(MiB) Mean(MiB) ...). We want only the summary table. Scanning
        # the whole body for write/read lines matches both and misreads
        # columns from the wrong table -- so only look at lines *after*
        # the Operation/Max(MiB) header, not the full section body.
        header_match = re.search(r"^Operation\s+Max\(MiB\).*$", body, flags=re.MULTILINE)
        if not header_match:
            continue
        header_cols = header_match.group(0).split()
        try:
            max_idx = header_cols.index("Max(MiB)")
            mean_idx = header_cols.index("Mean(MiB)")
        except ValueError:
            continue

        body_after_header = body[header_match.end():]
        for line in body_after_header.splitlines():
            line = line.strip()
            if line.startswith("write") or line.startswith("read"):
                parts = line.split()
                if len(parts) <= max(max_idx, mean_idx):
                    continue
                op = parts[0]
                try:
                    max_val = float(parts[max_idx])
                    mean_val = float(parts[mean_idx])
                except (ValueError, IndexError):
                    continue
                rows.append({
                    "run_type": "ior",
                    "test_label": label,
                    "operation": op,
                    "max_mib_s": max_val,
                    "mean_mib_s": mean_val,
                    "iops": "",
                })
    return rows


def parse_mdtest_file(path):
    """
    mdtest-4.0.0 SUMMARY rate lines look like (no colon, whitespace-separated):
       File creation                7000.398       7000.398       7000.398          0.000
       File stat                  153875.650     153875.650     153875.650          0.000
    Older mdtest versions used a colon separator:
       File creation     :  12345.678  12000.000  11000.000  ...
    Columns are: Operation, Max, Min, Mean, Std Dev (ops/sec). Handle both
    by making the colon optional.
    """
    rows = []
    with open(path, errors="replace") as f:
        text = f.read()

    pattern = re.compile(
        r"^\s*(File creation|File stat|File read|File removal|"
        r"Directory creation|Directory stat|Directory removal|Tree creation|Tree removal)"
        r"\s*:?\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)",
        flags=re.MULTILINE,
    )
    for m in pattern.finditer(text):
        op, max_val, min_val, mean_val = m.groups()
        rows.append({
            "run_type": "mdtest",
            "test_label": "mdtest",
            "operation": op,
            "max_mib_s": "",
            "mean_mib_s": "",
            "iops": mean_val,
        })
    return rows


def get_nodes_tasks(text):
    nodes = ""
    tasks = ""
    # 02_ior_multi_node.sh's own echo line: "Nodes: 4, tasks: 16"
    m = re.search(r"Nodes:\s*(\d+),\s*tasks:\s*(\d+)", text)
    if m:
        nodes, tasks = m.groups()
        return nodes, tasks

    # mdtest-4.0.0's own launch banner: "mdtest-4.0.0 was launched with
    # 4 total task(s) on 1 node(s)"
    m = re.search(r"was launched with (\d+) total task\(s\) on (\d+) node\(s\)", text)
    if m:
        tasks, nodes = m.groups()
        return nodes, tasks

    # IOR-4.0.0's own "Options:" block reports nodes/tasks directly, e.g.:
    #   nodes               : 1
    #   tasks               : 4
    m_nodes = re.search(r"^nodes\s*:\s*(\d+)", text, flags=re.MULTILINE)
    m_tasks = re.search(r"^tasks\s*:\s*(\d+)", text, flags=re.MULTILINE)
    if m_nodes or m_tasks:
        nodes = m_nodes.group(1) if m_nodes else ""
        tasks = m_tasks.group(1) if m_tasks else ""
        return nodes, tasks

    # Older mdtest versions: "clients = N"
    m = re.search(r"clients\s*=\s*(\d+)", text)
    if m:
        tasks = m.group(1)
    return nodes, tasks


def main():
    parsed = load_parsed()
    all_files = sorted(
        glob.glob("ior_single_node_*.txt")
        + glob.glob("ior_multi_node_*.txt")
        + glob.glob("mdtest_*.txt")
    )
    new_files = [f for f in all_files if f not in parsed]

    if not new_files:
        print("No new result files to parse. (Delete .parsed_files to reparse everything.)")
        return

    file_exists = os.path.exists(RESULTS_CSV)
    with open(RESULTS_CSV, "a", newline="") as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=CSV_FIELDS)
        if not file_exists:
            writer.writeheader()

        for path in new_files:
            with open(path, errors="replace") as f:
                text = f.read()
            nodes, tasks = get_nodes_tasks(text)
            ts_match = re.search(r"(\d{8}-\d{6})", path)
            if ts_match:
                timestamp = ts_match.group(1)
                dt = datetime.strptime(timestamp, "%Y%m%d-%H%M%S")
            else:
                dt = datetime.now()
                timestamp = dt.strftime("%Y%m%d-%H%M%S")
            epoch_ts = int(dt.timestamp())
            # run_id groups every row parsed from the same source file —
            # one benchmark invocation, however many operations/labels it
            # produced.
            run_id = path

            if path.startswith("mdtest_"):
                rows = parse_mdtest_file(path)
            else:
                rows = parse_ior_file(path)

            for row in rows:
                row["timestamp"] = timestamp
                row["epoch_ts"] = epoch_ts
                row["run_id"] = run_id
                row["source_file"] = path
                row["nodes"] = nodes
                row["tasks"] = tasks
                row["metric_key"] = make_metric_key(
                    row["run_type"], row.get("test_label", ""), row["operation"]
                )
                writer.writerow(row)

            print(f"Parsed {path}: {len(rows)} row(s)")
            parsed.add(path)

    save_parsed(parsed)
    print(f"\nAppended to {RESULTS_CSV}")


if __name__ == "__main__":
    main()

