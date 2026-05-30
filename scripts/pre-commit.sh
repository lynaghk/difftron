#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/_common.sh"

"$SCRIPT_DIR/format.sh"
"$SCRIPT_DIR/test.sh"
