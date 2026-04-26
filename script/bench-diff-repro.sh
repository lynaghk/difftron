#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

RUNS=${RUNS:-5}
WARMUP=${WARMUP:-1}

normalize_snapshot_arg() {
  local arg=$1
  local prefix="${REPO_ROOT}@"
  if [[ "${arg}" == "${prefix}"* ]]; then
    printf '%s\n' "${arg#${prefix}}"
  else
    printf '%s\n' "${arg}"
  fi
}

LHS=$(normalize_snapshot_arg "${1:-${REPO_ROOT}@89e41ef}")
RHS=$(normalize_snapshot_arg "${2:-${REPO_ROOT}@d1818bf}")

COMMAND=("${SCRIPT_DIR}/rust_dive_dev" "diff" "${LHS}" "${RHS}")

cd "${REPO_ROOT}"

echo "Benchmarking: ${COMMAND[*]}"
echo "Warmup runs: ${WARMUP}"
TIMEFORMAT='real %R\nuser %U\nsys %S'

for run in $(seq 1 "${WARMUP}"); do
  echo "Warmup ${run}/${WARMUP}"
  "${COMMAND[@]}" >/dev/null
done

for run in $(seq 1 "${RUNS}"); do
  echo "Run ${run}/${RUNS}"
  time "${COMMAND[@]}" >/dev/null
done
