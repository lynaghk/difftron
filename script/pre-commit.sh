#!/usr/bin/env bash
set -euo pipefail

SCRIPT_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${SCRIPT_SOURCE}" ]]; do
  SCRIPT_DIR=$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)
  SCRIPT_SOURCE=$(readlink "${SCRIPT_SOURCE}")
  [[ "${SCRIPT_SOURCE}" != /* ]] && SCRIPT_SOURCE="${SCRIPT_DIR}/${SCRIPT_SOURCE}"
done

SCRIPT_DIR=$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)

"${SCRIPT_DIR}/format.sh"
"${SCRIPT_DIR}/test.sh"
