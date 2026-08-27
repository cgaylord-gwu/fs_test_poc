# Scratch benchmark POC — IOR / mdtest

Purpose: establish a first, repeatable baseline for `/scratch/c1/cgaylord`
(GPFS, currently
TCP failover, no verbs) before formalizing this with Joe and Fong. Built to be
run solo by Clark on log002, then handed off as a working artifact rather than
a proposal.

## Layout

- `00_build.sh` — builds IOR and mdtest from source via pixi/conda-forge, no
  root needed. Skip if a module or existing binary is already available.
- `01_ior_single_node.sh` — sequential write/read baseline, one node.
- `02_ior_multi_node.sh` — 4 nodes, 4 tasks/node (16 total), to see aggregate
  throughput/contention behavior over TCP. As of 2026-08 this explicitly
  forces cross-node task placement with `--map-by node` and verifies it with
  a logged `hostname` fan-out before the real test — earlier runs did not
  force this, and it's possible (unconfirmed either way) that OpenMPI's
  default mapping put all tasks on one node despite the 4-node allocation.
  The script now warns loudly in its own output if placement doesn't match
  expectations, so results are self-verifying going forward.
- `05_ior_multi_node_1ppn.sh` — 4 nodes, 1 task/node (4 total). Isolates
  genuine cross-node network/GPFS-client effects from the same-node
  multi-task effects (shared local TCP stack, page cache) that are mixed
  into `02`'s 16-task result. Compare this run's per-task bandwidth against
  `01`'s per-task bandwidth (divide `01`'s aggregate by its task count) to
  see whether cross-node placement alone changes per-task IO performance.
- `03_mdtest_single_node.sh` — metadata create/stat/remove, small file count,
  sized to be safe against qumulo1 pressure (this hits GPFS scratch, not
  qumulo, but kept conservative regardless — see note below).
- `04_run_all.sh` — convenience wrapper, submits 01-03 in sequence, waits,
  collects results. Does not currently include `05` — run that one
  separately when you want the 1-task/node comparison.
- `parse_results.py` — pulls the key numbers out of IOR/mdtest stdout into one
  CSV row per run, appends to `results.csv` so repeat runs build a timeseries.
- `send_to_zabbix.py` — reads `results.csv` (does not re-parse raw output) and
  emits `zabbix_sender`-format lines, either printed for manual piping or sent
  directly if `zabbix_sender` is installed and a server is given.

## Data flow / schema

```
IOR / mdtest stdout  -->  parse_results.py  -->  results.csv  -->  send_to_zabbix.py
                                                       |
                                                       +--> R / Python / gnuplot
```

`results.csv` is the single source of truth, kept in tidy long format (one row
per metric observation) so it works two ways without reshaping:

- **R / Python / gnuplot**: plain columns, no nested structures.
  `read.csv("results.csv")` in R, `pd.read_csv("results.csv")` in pandas, or
  `plot 'results.csv' using 2:9 with linespoints` in gnuplot (with
  `set datafile separator ','`) all work directly against it.
- **Zabbix**: two columns exist specifically for this — `epoch_ts` (unix
  timestamp, what `zabbix_sender -T` wants) and `metric_key` (a stable
  dotted key like `scratch.ior.write.block_size_1m_transfer_size_1m` or
  `scratch.mdtest.file_creation`, built the same way every run so it can be
  used directly as a Zabbix trapper item key). `run_id` groups rows from the
  same benchmark invocation, for both Zabbix "run completed" style markers
  and grouping in R/pandas without touching source files.

This means the Zabbix view and the plotted view can never drift apart — both
read the same rows.

### Getting data into Zabbix

`send_to_zabbix.py` requires trapper items pre-created on a Zabbix host
(default expected name `scratch-poc`) with keys matching what `metric_key`
produces — e.g. `scratch.ior.write.block_size_1m_transfer_size_1m` as a
Numeric (float) trapper item. This script only sends values; it doesn't
create items.

```bash
# See what would be sent, without sending anything:
python3 send_to_zabbix.py --dry-run

# Send everything not yet sent (tracked via .sent_to_zabbix marker):
python3 send_to_zabbix.py --zabbix-server <zbx-host> --host scratch-poc

# Send just the most recent run, ignoring the sent-marker:
python3 send_to_zabbix.py --zabbix-server <zbx-host> --host scratch-poc --latest-only
```

Requires the `zabbix_sender` binary on whatever host runs this (part of the
`zabbix-sender` or `zabbix-get` package family) — it isn't required at all
for the `--dry-run` / R / Python / gnuplot path.

## Before running

1. **MPI note (important):** the module-tree `openmpi/gcc/64/4.1.6` is
   confirmed broken as of 2026-08 — its `lib/` has no `libpmix.so` at all,
   so `mpirun` fails at `orte_init` for any job, even `-np 1`, on both
   log002 and compute nodes. All scripts here (`00_build.sh` and the three
   `.sh` files) instead point directly at `/usr/mpi/gcc/openmpi-4.1.7a1`,
   a working vendor/OFED-provided install confirmed present in the same
   location on log002 and a compute node (cpu009), with a real
   `libpmix.so.2` bundled. No `module load` needed for MPI; don't `ml
   openmpi/gcc/64/4.1.6` before running these, since a manually loaded
   module can shadow the vendor path. This is worth flagging to Glen/Joe
   independently — it's a gap in the module tree, not specific to this POC.

   Also as of 2026-08: this vendor build's hwloc CPU-binding logic fails
   outright under Slurm's cgroup-restricted CPU sets
   (`hwloc_set_cpubind returned "Error"`), killing every rank before the
   app starts. All `mpirun` calls in the `.sh` files pass `--bind-to none`
   to work around this — safe for an I/O benchmark since the bottleneck is
   the filesystem, not CPU cache locality, so unlike a compute-bound MPI
   code, disabling binding here doesn't affect what's being measured.
2. Confirm `/scratch/c1/cgaylord` is the intended target and has enough free
   space for a ~16GB working set per node during the run
   (`df -h /scratch/c1/cgaylord`). This is Clark's own scratch space, distinct
   from CBI's scratch usage — no coordination needed there.
3. Confirm with Joe/Glen informally that a short multi-node job on 4 nodes
   won't collide with anything sensitive — this is a courtesy heads-up, not
   a design review, since you're intentionally doing this solo first.
4. Edit `SCRATCH_TEST_DIR` at the top of each `.sh` file if you want a
   specific subdirectory rather than the default
   `/scratch/c1/cgaylord/benchmark-poc`.

## Running

```bash
cd /home/claude/ior-poc   # or wherever you've copied this on log002
./00_build.sh             # one-time, only if IOR/mdtest aren't already available
./04_run_all.sh
python3 parse_results.py
```

Results land in `results.csv` — one row per run, with timestamp, so this is
safe to re-run monthly or after fabric/GPFS changes and get a trend line for
free.

**Note on existing data:** the `02_ior_multi_node` rows already in
`results.csv` (job 73608640, run 2026-08-27) predate the forced
`--map-by node` placement and hostname verification step added below.
Checked independently via `sacct -j 73608640 --format=JobID,NodeList` —
Slurm allocated 4 distinct nodes (`cpu[008-011]`), and OpenMPI's own
`orted` remote-daemon steps show `cpu[009-011]` alongside the batch
script's `cpu008`, confirming MPI ranks were not all confined to one
node. This is reasonable evidence the original run was genuinely
cross-node, though it doesn't confirm an even 4-tasks-per-node split
across all four. Re-run with the current script for a self-verifying
result that logs placement directly in its own output.

## What this intentionally does NOT do yet

- No verbs/RDMA comparison run — that requires cordoning off nodes with IB
  re-enabled, which is a bigger ask and probably the next step to propose
  once you have the TCP baseline in hand.
- No NAS/Qumulo-side benchmark — different tool shape (this would lean more
  fio/NFS-client-side), kept out of scope to keep this POC narrow.
- Zabbix ingestion is scaffolded (`send_to_zabbix.py`, `metric_key`/`epoch_ts`
  columns) but not wired to a real server or item set yet — that's a
  five-minute step once you and Rubeel agree on a host name and item
  layout in Zabbix, not a design question left open by this POC.

