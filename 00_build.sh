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
# `module` is a shell function, normally set up by sourcing an init script
# (e.g. /etc/profile.d/lmod.sh) into an interactive login shell. Running
# this script non-interactively (e.g. via `bash 00_build.sh` from a shell
# that never sourced that init script, or via Slurm) can leave `module`
# undefined even though it works fine when you type commands by hand.
# Guard for that rather than failing on a confusing "module: command not
# found" partway through.
if ! declare -F module >/dev/null 2>&1 && ! command -v module >/dev/null 2>&1; then
  # Try the common Lmod init location before giving up.
  if [ -f /etc/profile.d/lmod.sh ]; then
    # shellcheck disable=SC1091
    source /etc/profile.d/lmod.sh
  elif [ -f /usr/share/lmod/lmod/init/bash ]; then
    # shellcheck disable=SC1091
    source /usr/share/lmod/lmod/init/bash
  fi
fi

if declare -F module >/dev/null 2>&1 || command -v module >/dev/null 2>&1; then
  module load openmpi/gcc/64/4.1.6
else
  echo "WARNING: 'module' command not available in this shell context." >&2
  echo "Run 'module load openmpi/gcc/64/4.1.6' yourself first, then re-run" >&2
  echo "this script (or run: bash -lc './00_build.sh' so a login shell" >&2
  echo "sources the module init files)." >&2
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
echo "Verify:"
echo "  ${PREFIX}/bin/ior -V"
echo "  ${PREFIX}/bin/mdtest -V"

