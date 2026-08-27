#!/bin/bash
#SBATCH --job-name=ior-poc-4node-1ppn
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:20:00
#SBATCH --output=%x-%j.out

# 4-node IOR run with exactly ONE task per node (as opposed to
# 02_ior_multi_node.sh's 4 tasks/node = 16 total). Purpose: isolate
# genuine cross-node network/GPFS-client effects from same-node
# multi-task effects (shared local TCP stack, page cache, etc.) that are
# mixed into the 16-task result. This answers "how does IO look when
# tasks are forced onto different nodes" as its own question, distinct
# from "what's the aggregate throughput of N tasks however they land."
#
# Compare this run's per-task bandwidth against 01_ior_single_node.sh's
# per-task bandwidth (divide 01's aggregate by its task count) to see
# whether cross-node placement alone changes per-task IO performance,
# independent of aggregate scaling effects.

set -euo pipefail

# MPI setup: see 01_ior_single_node.sh for why this points at the
# vendor OpenMPI instead of the module tree (openmpi/gcc/64/4.1.6 is
# missing libpmix cluster-wide), and why --bind-to none is passed on
# every mpirun call below (this vendor build's hwloc CPU-binding fails
# outright under Slurm's cgroup-restricted CPU sets).
VENDOR_MPI_PREFIX="/usr/mpi/gcc/openmpi-4.1.7a1"
if [ -x "${VENDOR_MPI_PREFIX}/bin/mpirun" ]; then
  export PATH="${VENDOR_MPI_PREFIX}/bin:${PATH}"
  export LD_LIBRARY_PATH="${VENDOR_MPI_PREFIX}/lib64:${LD_LIBRARY_PATH:-}"
elif ! command -v mpirun >/dev/null 2>&1; then
  echo "No mpirun found (vendor MPI absent, none on PATH). Load an MPI" >&2
  echo "module or fix VENDOR_MPI_PREFIX at the top of this script." >&2
  exit 1
fi

export PATH="${HOME}/opt/ior/bin:${PATH}"
SCRATCH_TEST_DIR="${SCRATCH_TEST_DIR:-/scratch/c1/cgaylord/benchmark-poc}"
mkdir -p "${SCRATCH_TEST_DIR}"

TS="$(date +%Y%m%d-%H%M%S)"
OUTFILE="ior_multi_node_1ppn_${TS}.txt"
NTASKS=$((SLURM_NNODES * SLURM_NTASKS_PER_NODE))

echo "=== IOR multi-node (1 task/node) run: ${TS} ===" | tee "${OUTFILE}"
echo "Nodes: ${SLURM_NNODES}, tasks: ${NTASKS}" | tee -a "${OUTFILE}"
echo "Target: ${SCRATCH_TEST_DIR}" | tee -a "${OUTFILE}"

# Verify placement -- with 1 task/node this should trivially show N
# distinct hostnames, but confirm rather than assume.
echo "--- Task placement check (should show all ${SLURM_NNODES} distinct nodes) ---" | tee -a "${OUTFILE}"
mpirun -np "${NTASKS}" --bind-to none --map-by node hostname | sort | uniq -c | tee -a "${OUTFILE}"
DISTINCT_NODES=$(mpirun -np "${NTASKS}" --bind-to none --map-by node hostname | sort -u | wc -l)
if [ "${DISTINCT_NODES}" -lt "${SLURM_NNODES}" ]; then
  echo "" | tee -a "${OUTFILE}"
  echo "WARNING: expected ${SLURM_NNODES} distinct nodes, tasks only landed" | tee -a "${OUTFILE}"
  echo "on ${DISTINCT_NODES}. Results below do NOT represent genuine" | tee -a "${OUTFILE}"
  echo "one-task-per-node placement -- do not treat them as this baseline." | tee -a "${OUTFILE}"
fi

# Same block/transfer sizes as 01_ior_single_node.sh's first test, scaled
# down per-task working set isn't needed here since it's still 1 task/node
# -- keep it comparable to 01's per-task numbers.
echo "--- File-per-process, transfer size 1m, 1 task/node ---" | tee -a "${OUTFILE}"
mpirun -np "${NTASKS}" --bind-to none --map-by node ior \
  -a POSIX \
  -w -r \
  -b 4g \
  -t 1m \
  -o "${SCRATCH_TEST_DIR}/ior_test_1ppn" \
  -F \
  -i 1 \
  -e \
  2>&1 | tee -a "${OUTFILE}"

rm -f "${SCRATCH_TEST_DIR}"/ior_test_1ppn*

echo "Done. Output: ${OUTFILE}"

