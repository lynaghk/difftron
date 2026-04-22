#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

"${SCRIPT_DIR}/setup-test-deps.sh"

if command -v emacs >/dev/null 2>&1; then
  EMACS_BIN=$(command -v emacs)
elif command -v emacs-nox >/dev/null 2>&1; then
  EMACS_BIN=$(command -v emacs-nox)
else
  echo "error: could not find emacs or emacs-nox in PATH" >&2
  exit 127
fi

cd "${REPO_ROOT}"
"${EMACS_BIN}" -Q --batch \
  -l "${REPO_ROOT}/emacs/test-config/init.el" \
  -L "${REPO_ROOT}/emacs" \
  -l rust-dive-magit-tests.el \
  -f ert-run-tests-batch-and-exit
