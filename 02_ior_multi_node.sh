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

# Shared-file pattern (-F omitted) in addition to file-per-process, since
# shared-file is where GPFS lock/token contention over TCP tends to show up
# most clearly.

echo "--- File-per-process, transfer size 1m ---" | tee -a "${OUTFILE}"
mpirun -np "${NTASKS}" --bind-to none ior \
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
mpirun -np "${NTASKS}" --bind-to none ior \
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
