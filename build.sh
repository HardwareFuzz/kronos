#!/usr/bin/env bash
set -euo pipefail

# Build a Verilator-based simulation binary that accepts an ELF path
# and place it in build_result/{name}_{isa}
#
# Output binary name is "kronos_rv32" (ISA is RV32) or "kronos_rv32_cov"
# when building with coverage enabled.
#
# Requirements (expected to be available in PATH):
#   - cmake >= 3.10
#   - verilator
#   - riscv toolchain (CMake's FindRISCV is required by this repo)
#
# Usage:
#   ./build.sh [--coverage] [--no-coverage] [--clean]
#
# After building, run:
#   ./build_result/kronos_rv32 <program.elf> [--vcd out.vcd] [--max-cycles N] [--mem-kb KB]
#   ./build_result/kronos_rv32_cov <program.elf> [--covfile logs/coverage.dat] [...]
#
# Pass --covfile <path> to choose the coverage .dat output (default logs/coverage.dat).
# When both --covfile and +covfile= are present, --covfile wins (see kronos_elfsim.cpp).

usage() {
  cat <<'EOF'
Usage: ./build.sh [--isa ISA] [--coverage|--coverage-light|--no-coverage] [--cores N] [--clean] [--help]

Build the Verilator ELF simulator (kronos).
  --isa ISA            ISA tag used for output naming (default: rv32). Kronos is RV32-only.
  --cores N            Set core count tag used for output naming (default: 1)
  --coverage           Build full coverage-enabled binary
  --coverage-light     Build light coverage binary (line/user coverage only)
  --no-coverage        Build the standard binary (default)
  --clean              Remove the selected build/output before building
  --help               Show this message

Output binary:
  build_result/kronos_<isa>_<N>c[_cov|_cov_light]

At runtime, pass --covfile <path> to the simulator to choose the coverage
.dat output path (coverage builds only). Default is logs/coverage.dat; if
both --covfile and +covfile= are given, --covfile takes precedence.
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_NAME="kronos_elfsim"
RESULT_DIR="${ROOT_DIR}/build_result"
ISA="${ISA:-rv32}"
COVERAGE_MODE="${COVERAGE_MODE:-none}" # none|full|light
CORES="${CORES:-1}"
CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --coverage|-c) COVERAGE_MODE="full" ;;
    --coverage-light) COVERAGE_MODE="light" ;;
    --no-coverage|-n) COVERAGE_MODE="none" ;;
    --isa)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --isa requires a value" >&2
        usage
        exit 1
      fi
      ISA="$2"
      shift 2
      continue
      ;;
    --isa=*) ISA="${1#*=}" ;;
    --cores)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --cores requires a value" >&2
        usage
        exit 1
      fi
      CORES="$2"
      shift 2
      continue
      ;;
    --cores=*) CORES="${1#*=}" ;;
    --clean) CLEAN=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift || true
done

if [[ "$ISA" != rv32* ]]; then
  echo "ERROR: Kronos is RV32-only; refusing ISA '$ISA'" >&2
  exit 1
fi

if ! [[ "$CORES" =~ ^[0-9]+$ ]] || (( CORES < 1 )); then
  echo "ERROR: --cores must be a positive integer (got '$CORES')" >&2
  exit 1
fi

if (( CORES != 1 )); then
  echo "ERROR: log branch is single-core only; use --cores 1 (got '$CORES')" >&2
  exit 1
fi

case "$COVERAGE_MODE" in
  full)
    BUILD_DIR="${ROOT_DIR}/build_cov"
    COV_SUFFIX="_cov"
    ;;
  light)
    BUILD_DIR="${ROOT_DIR}/build_cov_light"
    COV_SUFFIX="_cov_light"
    ;;
  none)
    BUILD_DIR="${ROOT_DIR}/build"
    COV_SUFFIX=""
    ;;
  *)
    echo "ERROR: Unknown coverage mode: $COVERAGE_MODE" >&2
    exit 1
    ;;
esac

OUT_NAME="kronos_${ISA}_${CORES}c${COV_SUFFIX}"

if (( CLEAN )); then
  rm -rf "${BUILD_DIR}"
  rm -f "${RESULT_DIR}/${OUT_NAME}"
fi

# Create a local RISCV toolchain shim if only riscv64 toolchain exists
TOOLSHIM="${BUILD_DIR}/toolshim"
mkdir -p "${TOOLSHIM}/bin"
if command -v riscv32-unknown-elf-gcc >/dev/null 2>&1; then
  export RISCV_TOOLCHAIN_DIR="$(dirname "$(dirname "$(command -v riscv32-unknown-elf-gcc)")")"
else
  if command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
    ln -sf "$(command -v riscv64-unknown-elf-gcc)" "${TOOLSHIM}/bin/riscv32-unknown-elf-gcc"
    ln -sf "$(command -v riscv64-unknown-elf-objdump)" "${TOOLSHIM}/bin/riscv32-unknown-elf-objdump"
    ln -sf "$(command -v riscv64-unknown-elf-objcopy)" "${TOOLSHIM}/bin/riscv32-unknown-elf-objcopy"
    export RISCV_TOOLCHAIN_DIR="${TOOLSHIM}"
  fi
fi

mkdir -p "${BUILD_DIR}"
cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release -DVERILATOR_COVERAGE_MODE="${COVERAGE_MODE}"
cmake --build "${BUILD_DIR}" --target ${BIN_NAME} -j

mkdir -p "${RESULT_DIR}"
cp -f "${BUILD_DIR}/output/bin/${BIN_NAME}" "${RESULT_DIR}/${OUT_NAME}"

if [[ "$COVERAGE_MODE" == "full" || "$COVERAGE_MODE" == "light" ]]; then
  echo "Built coverage binary: ${RESULT_DIR}/${OUT_NAME}"
  echo "Run with +covfile=<path> to choose the coverage output .dat file (default: logs/coverage.dat)."
else
  echo "Built ${RESULT_DIR}/${OUT_NAME}"
fi
