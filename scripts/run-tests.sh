#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

"${SCRIPT_DIR}/run-rust-tests.sh"
"${SCRIPT_DIR}/run-emacs-tests.sh"
