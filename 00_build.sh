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
# openmpi/gcc/64/4.1.6 (the module-tree build) is confirmed broken as of
# 2026-08: its lib/ has no libpmix.so at all, so mpirun fails at orte_init
# for any job, even -np 1, on both log002 and compute nodes (not a
# log002-specific issue -- LD_LIBRARY_PATH points at shared /fs_1m storage,
# same broken lib dir everywhere). Flagged to Glen/Joe separately.
#
# /usr/mpi/gcc/openmpi-4.1.7a1 is a working alternative confirmed present
# in the identical location on both log002 and a compute node (cpu009),
# with a real libpmix.so.2 bundled. This is very likely a vendor/OFED-
# provided install (the /usr/mpi/... layout is a common Mellanox/NVIDIA
# pattern) rather than anything RTS built, and it isn't exposed via Lmod --
# so we point PATH/LD_LIBRARY_PATH at it directly instead of using
# `module load`.
VENDOR_MPI_PREFIX="/usr/mpi/gcc/openmpi-4.1.7a1"

if [ -x "${VENDOR_MPI_PREFIX}/bin/mpicc" ]; then
  export PATH="${VENDOR_MPI_PREFIX}/bin:${PATH}"
  export LD_LIBRARY_PATH="${VENDOR_MPI_PREFIX}/lib64:${LD_LIBRARY_PATH:-}"
  echo "Using vendor OpenMPI at ${VENDOR_MPI_PREFIX} (bundled PMIx, confirmed working)."
else
  echo "Vendor OpenMPI not found at ${VENDOR_MPI_PREFIX}; falling back to module." >&2
  if ! declare -F module >/dev/null 2>&1 && ! command -v module >/dev/null 2>&1; then
    if [ -f /etc/profile.d/lmod.sh ]; then
      # shellcheck disable=SC1091
      source /etc/profile.d/lmod.sh
    elif [ -f /usr/share/lmod/lmod/init/bash ]; then
      # shellcheck disable=SC1091
      source /usr/share/lmod/lmod/init/bash
    fi
  fi
  if declare -F module >/dev/null 2>&1 || command -v module >/dev/null 2>&1; then
    echo "WARNING: openmpi/gcc/64/4.1.6 is confirmed missing libpmix.so --" >&2
    echo "mpirun will likely fail at orte_init even if this module loads" >&2
    echo "cleanly. Loading it anyway since no vendor MPI was found." >&2
    module load openmpi/gcc/64/4.1.6
  else
    echo "WARNING: 'module' command not available in this shell context" >&2
    echo "and no vendor MPI found either. Set up an MPI toolchain manually" >&2
    echo "before re-running." >&2
  fi
fi
# -----------------------------------

if ! command -v mpicc >/dev/null 2>&1; then
  echo "mpicc not found on PATH. Load your MPI module first (see comment" >&2
  echo "at the top of this script), then re-run." >&2
  exit 1
fi

mkdir -p "${SRC_DIR}"
cd "${SRC_DIR}"

# Prefer an official release tarball: it ships a pre-generated ./configure,
# so no autoreconf/autoconf version dependency at all. This sidesteps a
# real, seen-in-practice failure mode where the repo's ./bootstrap requires
# autoconf >= 2.71 and the system autoconf (commonly 2.69 on Rocky Linux)
# is older.
IOR_VERSION="4.0.0"
TARBALL="ior-${IOR_VERSION}.tar.gz"
TARBALL_URL="https://github.com/hpc/ior/releases/download/${IOR_VERSION}/${TARBALL}"
EXTRACTED_DIR="ior-${IOR_VERSION}"

if [ -d "${EXTRACTED_DIR}" ]; then
  echo "Found existing ${EXTRACTED_DIR}, reusing it."
else
  echo "Downloading IOR ${IOR_VERSION} release tarball (includes pre-generated configure)..."
  if command -v curl >/dev/null 2>&1; then
    curl -fL -o "${TARBALL}" "${TARBALL_URL}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${TARBALL}" "${TARBALL_URL}"
  else
    echo "Neither curl nor wget found; cannot download the release tarball." >&2
    exit 1
  fi
  tar -xzf "${TARBALL}"
fi

cd "${EXTRACTED_DIR}"

if [ ! -x ./configure ]; then
  echo "" >&2
  echo "Release tarball did not include a pre-generated ./configure as" >&2
  echo "expected. Falling back to git clone + bootstrap, which requires" >&2
  echo "autoconf >= 2.71." >&2
  cd "${SRC_DIR}"
  if [ ! -d ior ]; then
    git clone https://github.com/hpc/ior.git
  fi
  cd ior
  git pull --ff-only || true

  AUTOCONF_OK=0
  if command -v autoconf >/dev/null 2>&1; then
    AC_VER=$(autoconf --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    AC_MAJOR=$(echo "${AC_VER}" | cut -d. -f1)
    AC_MINOR=$(echo "${AC_VER}" | cut -d. -f2)
    if [ "${AC_MAJOR}" -gt 2 ] || { [ "${AC_MAJOR}" -eq 2 ] && [ "${AC_MINOR}" -ge 71 ]; }; then
      AUTOCONF_OK=1
    fi
  fi
  if [ "${AUTOCONF_OK}" -eq 0 ]; then
    echo "" >&2
    echo "System autoconf is older than 2.71 and the release tarball path" >&2
    echo "failed. Options:" >&2
    echo "  1. module spider autoconf   (check for a newer version)" >&2
    echo "  2. pixi global install autoconf   (or conda install -c conda-forge autoconf)" >&2
    exit 1
  fi
  ./bootstrap
fi

./configure --prefix="${PREFIX}"
make -j"$(nproc)"
make install

echo ""
echo "Built. IOR and mdtest installed to ${PREFIX}/bin"
echo "Add to PATH for this session:"
echo "  export PATH=\"${PREFIX}/bin:\${PATH}\""
echo ""
echo "Verify (note: -V is not a valid flag for this build, and running"
echo "these bare/outside mpirun will fail MPI singleton-init on this"
echo "cluster's OpenMPI/PMIx setup -- always launch via mpirun, even for"
echo "a 1-process sanity check):"
echo "  mpirun -np 1 ${PREFIX}/bin/ior --help"
echo "  mpirun -np 1 ${PREFIX}/bin/mdtest --help"

