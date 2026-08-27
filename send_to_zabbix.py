#!/usr/bin/env python3
"""
Read results.csv and emit input suitable for `zabbix_sender -i -`, or send
directly if zabbix_sender is on PATH and a server is configured.

This deliberately does NOT re-parse IOR/mdtest output -- it reads the same
results.csv that R/Python/gnuplot use, so there is exactly one source of
truth and the Zabbix view can never drift from the plotted view.

Usage:
    # Just print the zabbix_sender input format (safe, no send):
    python3 send_to_zabbix.py --dry-run

    # Send new (unsent) rows to a Zabbix server via zabbix_sender:
    python3 send_to_zabbix.py --zabbix-server zbx.gwu.edu --host scratch-poc

    # Send only rows from the last run instead of all unsent rows:
    python3 send_to_zabbix.py --zabbix-server zbx.gwu.edu --host scratch-poc --latest-only

Zabbix-side prerequisite: a host (e.g. "scratch-poc") with trapper items
whose keys match the metric_key column, e.g.:
    scratch.ior.write.block_size_1m_transfer_size_1m  (Numeric, float)
    scratch.mdtest.file_creation                       (Numeric, float)
Item keys can be created ahead of time or via Zabbix's low-level discovery;
this script only emits data, it does not create items.

The value sent is mean_mib_s for IOR rows and iops for mdtest rows (falls
back to max_mib_s if mean is blank).
"""

import argparse
import csv
import os
import subprocess
import sys

RESULTS_CSV = "results.csv"
SENT_MARKER = ".sent_to_zabbix"


def load_sent():
    if not os.path.exists(SENT_MARKER):
        return set()
    with open(SENT_MARKER) as f:
        return set(line.strip() for line in f if line.strip())


def save_sent(sent):
    with open(SENT_MARKER, "w") as f:
        f.write("\n".join(sorted(sent)) + "\n")


def row_key(row):
    # Unique per (run, metric) so re-sends are avoidable across invocations.
    return f"{row['run_id']}::{row['metric_key']}"


def row_value(row):
    for field in ("mean_mib_s", "iops", "max_mib_s"):
        v = row.get(field, "")
        if v not in ("", None):
            return v
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zabbix-server", help="Zabbix server/proxy hostname or IP. If omitted, only prints (dry run).")
    ap.add_argument("--host", default="scratch-poc", help="Zabbix host name as configured in Zabbix (default: scratch-poc)")
    ap.add_argument("--port", type=int, default=10051, help="Zabbix server trapper port (default: 10051)")
    ap.add_argument("--latest-only", action="store_true", help="Only send rows from the most recent run_id, ignoring the sent-marker.")
    ap.add_argument("--dry-run", action="store_true", help="Print zabbix_sender input format, do not send even if --zabbix-server is given.")
    args = ap.parse_args()

    if not os.path.exists(RESULTS_CSV):
        print(f"{RESULTS_CSV} not found. Run parse_results.py first.", file=sys.stderr)
        sys.exit(1)

    with open(RESULTS_CSV, newline="") as f:
        all_rows = list(csv.DictReader(f))

    if not all_rows:
        print("results.csv is empty, nothing to send.")
        return

    if args.latest_only:
        # Tie-break on run_id (source filename) so that same-timestamp runs
        # (e.g. IOR and mdtest launched in the same batch) resolve
        # deterministically rather than depending on iteration order.
        latest_row = max(all_rows, key=lambda r: (int(r["epoch_ts"]), r["run_id"]))
        latest_run = latest_row["run_id"]
        candidate_rows = [r for r in all_rows if r["run_id"] == latest_run]
    else:
        sent = load_sent()
        candidate_rows = [r for r in all_rows if row_key(r) not in sent]

    if not candidate_rows:
        print("No new rows to send. (Use --latest-only to resend the most recent run regardless.)")
        return

    # zabbix_sender input format: <host> <key> <timestamp> <value>
    lines = []
    for row in candidate_rows:
        value = row_value(row)
        if value is None:
            continue
        lines.append(f"{args.host} {row['metric_key']} {row['epoch_ts']} {value}")

    payload = "\n".join(lines) + "\n"

    if args.dry_run or not args.zabbix_server:
        print(payload, end="")
        if not args.zabbix_server:
            print(f"\n({len(lines)} metric(s). Pass --zabbix-server to send, or pipe this to zabbix_sender -i - manually.)", file=sys.stderr)
        return

    try:
        proc = subprocess.run(
            [
                "zabbix_sender",
                "-z", args.zabbix_server,
                "-p", str(args.port),
                "-i", "-",
                "-T",  # use per-line timestamps
            ],
            input=payload,
            text=True,
            capture_output=True,
        )
    except FileNotFoundError:
        print(
            "zabbix_sender not found on PATH. Install the zabbix-sender package "
            "(or zabbix-get bundle) on this host, or run with --dry-run and pipe "
            "the output to zabbix_sender manually / on a host that has it.",
            file=sys.stderr,
        )
        sys.exit(1)

    print(proc.stdout)
    if proc.returncode != 0:
        print(proc.stderr, file=sys.stderr)
        sys.exit(proc.returncode)

    if not args.latest_only:
        sent = load_sent()
        sent.update(row_key(r) for r in candidate_rows)
        save_sent(sent)
        print(f"Sent {len(lines)} metric(s), marked as sent.")
    else:
        print(f"Sent {len(lines)} metric(s) from latest run ({candidate_rows[0]['run_id']}).")


if __name__ == "__main__":
    main()

