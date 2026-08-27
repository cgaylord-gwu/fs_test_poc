#!/bin/bash
#SBATCH --job-name=ior-poc-mdtest
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --time=00:15:00
#SBATCH --output=%x-%j.out

# mdtest metadata baseline: file create/stat/remove at a conservative count.
# Kept deliberately small for a first POC run — metadata ops on a shared
# filesystem can generate outsized load fast, and this is a first look,
# not a stress test. Scale -n up in a follow-up run once this completes
# cleanly and the impact is understood.

set -euo pipefail

# MPI setup: see 01_ior_single_node.slurm for why this points at the
# vendor OpenMPI instead of the module tree (openmpi/gcc/64/4.1.6 is
# missing libpmix cluster-wide).
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
SCRATCH_TEST_DIR="${SCRATCH_TEST_DIR:-/scratch/benchmark-poc}"
mkdir -p "${SCRATCH_TEST_DIR}/mdtest"

TS="$(date +%Y%m%d-%H%M%S)"
OUTFILE="mdtest_${TS}.txt"

echo "=== mdtest run: ${TS} ===" | tee "${OUTFILE}"
echo "Target: ${SCRATCH_TEST_DIR}/mdtest" | tee -a "${OUTFILE}"

# -n 1000: 1000 files per task (4 tasks = 4000 files total)
# -z 0 -b 1: flat directory, no tree depth — keep the first pass simple
# -u: unique working dir per task, avoids cross-task interference
mpirun -np "${SLURM_NTASKS}" mdtest \
  -n 1000 \
  -z 0 \
  -b 1 \
  -u \
  -d "${SCRATCH_TEST_DIR}/mdtest" \
  -F \
  2>&1 | tee -a "${OUTFILE}"

echo "Done. Output: ${OUTFILE}"
echo "Note: mdtest cleans up its own files by default unless -k was passed."

