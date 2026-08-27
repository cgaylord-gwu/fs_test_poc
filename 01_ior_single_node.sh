#!/bin/bash
#SBATCH --job-name=ior-poc-1node
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --time=00:20:00
#SBATCH --output=%x-%j.out

# Single-node IOR baseline: sequential write/read at two block sizes.
# Goal: establish per-node throughput ceiling on /scratch over TCP before
# looking at multi-node contention behavior.

set -euo pipefail

# MPI setup: openmpi/gcc/64/4.1.6 (module tree) is confirmed missing
# libpmix -- mpirun fails at orte_init cluster-wide under that module.
# /usr/mpi/gcc/openmpi-4.1.7a1 is a working vendor/OFED-provided install
# confirmed present in the same location on log002 and compute nodes
# (cpu009), with a real libpmix.so.2 bundled. Use it directly.
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
mkdir -p "${SCRATCH_TEST_DIR}"

TS="$(date +%Y%m%d-%H%M%S)"
OUTFILE="ior_single_node_${TS}.txt"

echo "=== IOR single-node run: ${TS} ===" | tee "${OUTFILE}"
echo "Target: ${SCRATCH_TEST_DIR}"        | tee -a "${OUTFILE}"

# 1MB transfer size, 4GB per process (4 tasks = 16GB working set)
echo "--- Block size 1m, transfer size 1m ---" | tee -a "${OUTFILE}"
mpirun -np "${SLURM_NTASKS}" ior \
  -a POSIX \
  -w -r \
  -b 4g \
  -t 1m \
  -o "${SCRATCH_TEST_DIR}/ior_test_1m" \
  -F \
  -i 1 \
  -e \
  2>&1 | tee -a "${OUTFILE}"

# 4MB transfer size, same working set
echo "--- Block size 1m, transfer size 4m ---" | tee -a "${OUTFILE}"
mpirun -np "${SLURM_NTASKS}" ior \
  -a POSIX \
  -w -r \
  -b 4g \
  -t 4m \
  -o "${SCRATCH_TEST_DIR}/ior_test_4m" \
  -F \
  -i 1 \
  -e \
  2>&1 | tee -a "${OUTFILE}"

# cleanup test files
rm -f "${SCRATCH_TEST_DIR}"/ior_test_1m* "${SCRATCH_TEST_DIR}"/ior_test_4m*

echo "Done. Output: ${OUTFILE}"

