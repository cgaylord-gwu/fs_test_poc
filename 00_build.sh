#!/usr/bin/env bash
# Build IOR + mdtest (both ship in the same ior-hpc repo) from source.
# No root required — installs to $HOME/opt/ior.
#
# Requires: MPI (mpicc) available on PATH. On log002/Pegasus this should be
# an existing module or pixi environment — adjust the `module load` line
# below to whatever your MPI stack actually is, or delete it if mpicc is
# already on PATH.

set -euo pipefail

PREFIX="${HOME}/opt/ior"
SRC_DIR="${HOME}/src/ior-build"

# --- adjust to your environment ---
# module load mpi/openmpi-x86_64   # uncomment / edit as needed
# -----------------------------------

if ! command -v mpicc >/dev/null 2>&1; then
  echo "mpicc not found on PATH. Load your MPI module first (see comment" >&2
  echo "at the top of this script), then re-run." >&2
  exit 1
fi

mkdir -p "${SRC_DIR}"
cd "${SRC_DIR}"

if [ ! -d ior ]; then
  git clone https://github.com/hpc/ior.git
fi

cd ior
git pull --ff-only || true

./bootstrap
./configure --prefix="${PREFIX}"
make -j"$(nproc)"
make install

echo ""
echo "Built. IOR and mdtest installed to ${PREFIX}/bin"
echo "Add to PATH for this session:"
echo "  export PATH=\"${PREFIX}/bin:\${PATH}\""
echo ""
echo "Verify:"
echo "  ${PREFIX}/bin/ior -V"
echo "  ${PREFIX}/bin/mdtest -V"

