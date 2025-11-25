#!/usr/bin/env bash
set -euo pipefail

# Build a Verilator-based simulation binary that accepts an ELF path
# and place it in build_result/{name}_{isa}
#
# Output binary name is "kronos_rv32" (ISA is RV32).
#
# Requirements (expected to be available in PATH):
#   - cmake >= 3.10
#   - verilator
#   - riscv toolchain (CMake's FindRISCV is required by this repo)
#
# Usage:
#   ./build.sh
#
# After building, run:
#   ./build_result/kronos_rv32 <program.elf> [--vcd out.vcd] [--max-cycles N] [--mem-kb KB]

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
BIN_NAME="kronos_elfsim"
OUT_NAME="kronos_rv32"
RESULT_DIR="${ROOT_DIR}/build_result"

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
cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release
cmake --build "${BUILD_DIR}" --target ${BIN_NAME} -j

mkdir -p "${RESULT_DIR}"
cp -f "${BUILD_DIR}/output/bin/${BIN_NAME}" "${RESULT_DIR}/${OUT_NAME}"

echo "Built ${RESULT_DIR}/${OUT_NAME}"
