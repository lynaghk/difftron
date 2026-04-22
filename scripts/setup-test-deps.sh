#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

cd "${REPO_ROOT}"

if [[ -f .mise.toml ]] && command -v mise >/dev/null 2>&1; then
  mise trust -y .mise.toml >/dev/null
  mise install >/dev/null
fi

if ! command -v emacs >/dev/null 2>&1 && ! command -v emacs-nox >/dev/null 2>&1; then
  apt-get update >/dev/null
  apt-get install -y emacs-nox >/dev/null
fi
