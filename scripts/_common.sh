#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

cd "${REPO_ROOT}"

difftron_shell_scripts() {
  shfmt --find "${SCRIPT_DIR}"
}

difftron_prepare_emacs() {
  if ! command -v emacs >/dev/null 2>&1 &&
    ! command -v emacs-nox >/dev/null 2>&1; then
    apt-get update >/dev/null
    apt-get install -y emacs-nox >/dev/null
  fi

  if command -v emacs >/dev/null 2>&1; then
    EMACS_BIN=$(command -v emacs)
  elif command -v emacs-nox >/dev/null 2>&1; then
    EMACS_BIN=$(command -v emacs-nox)
  else
    echo "error: could not find emacs or emacs-nox in PATH" >&2
    return 127
  fi

  export EMACS_BIN
}
