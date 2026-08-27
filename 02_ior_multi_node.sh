#!/bin/bash
#SBATCH --job-name=ior-poc-4node
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:20:00
#SBATCH --output=%x-%j.out

# 4-node IOR run: same pattern as single-node, to see aggregate throughput
# and any contention/degradation as more nodes hit /scratch concurrently
# over TCP. This is the first real signal on how TCP failover behaves
# under fan-in, which is the actual open question right now.

set -euo pipefail

# MPI setup: see 01_ior_single_node.sh for why this points at the
# vendor OpenMPI instead of the module tree (openmpi/gcc/64/4.1.6 is
# missing libpmix cluster-wide), and why --bind-to none is passed on
# every mpirun call below (this vendor build's hwloc CPU-binding fails
# outright under Slurm's cgroup-restricted CPU sets).
#
# Multi-node caveat: this vendor install isn't the module tree's usual
# OpenMPI, so its Slurm/PMI integration for launching across nodes hasn't
# been verified here the way single-node was. If this job hangs at
# startup or processes don't land on all nodes, that's the first thing to
# suspect -- worth running 01_ior_single_node.sh successfully first as
# a sanity check before this one.
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
OUTFILE="ior_multi_node_${TS}.txt"
NTASKS=$((SLURM_NNODES * SLURM_NTASKS_PER_NODE))

echo "=== IOR multi-node run: ${TS} ===" | tee "${OUTFILE}"
echo "Nodes: ${SLURM_NNODES}, tasks: ${NTASKS}" | tee -a "${OUTFILE}"
echo "Target: ${SCRATCH_TEST_DIR}" | tee -a "${OUTFILE}"

# --map-by node forces OpenMPI to round-robin ranks across the allocated
# nodes (rank 0 -> node A, rank 1 -> node B, rank 2 -> node C, rank 3 ->
# node D, rank 4 -> node A, ...) rather than filling one node's slots
# before moving to the next, which is OpenMPI's usual default and would
# silently put all --ntasks-per-node ranks on a single node if the
# allocation and mapping don't line up as expected. Without this, a
# "4-node" run's IO could really be happening on one node -- which
# matters a lot for what the numbers actually mean.
#
# Verify placement explicitly rather than inferring it from IOR's own
# output (IOR's "Machine:" field only reports the launching rank's
# hostname, not where every task landed).
echo "--- Task placement check (should show all ${SLURM_NNODES} distinct nodes) ---" | tee -a "${OUTFILE}"
mpirun -np "${NTASKS}" --bind-to none --map-by node hostname | sort | uniq -c | tee -a "${OUTFILE}"
DISTINCT_NODES=$(mpirun -np "${NTASKS}" --bind-to none --map-by node hostname | sort -u | wc -l)
if [ "${DISTINCT_NODES}" -lt "${SLURM_NNODES}" ]; then
  echo "" | tee -a "${OUTFILE}"
  echo "WARNING: expected ${SLURM_NNODES} distinct nodes, tasks only landed" | tee -a "${OUTFILE}"
  echo "on ${DISTINCT_NODES}. Results below do NOT represent genuine" | tee -a "${OUTFILE}"
  echo "cross-node IO -- do not treat them as a multi-node baseline." | tee -a "${OUTFILE}"
fi

# Shared-file pattern (-F omitted) in addition to file-per-process, since
# shared-file is where GPFS lock/token contention over TCP tends to show up
# most clearly.

echo "--- File-per-process, transfer size 1m ---" | tee -a "${OUTFILE}"
mpirun -np "${NTASKS}" --bind-to none --map-by node ior \
  -a POSIX \
  -w -r \
  -b 2g \
  -t 1m \
  -o "${SCRATCH_TEST_DIR}/ior_test_fpp" \
  -F \
  -i 1 \
  -e \
  2>&1 | tee -a "${OUTFILE}"

echo "--- Shared file, transfer size 1m ---" | tee -a "${OUTFILE}"
mpirun -np "${NTASKS}" --bind-to none --map-by node ior \
  -a POSIX \
  -w -r \
  -b 2g \
  -t 1m \
  -o "${SCRATCH_TEST_DIR}/ior_test_shared" \
  -i 1 \
  -e \
  2>&1 | tee -a "${OUTFILE}"

rm -f "${SCRATCH_TEST_DIR}"/ior_test_fpp* "${SCRATCH_TEST_DIR}"/ior_test_shared*

echo "Done. Output: ${OUTFILE}"

