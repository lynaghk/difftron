#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

usage() {
  echo "usage: ./scripts/format.sh [rust|emacs]" >&2
  exit 64
}

run_rust() {
  rust_dive_prepare_repo
  cargo fmt --all --manifest-path "${WORKSPACE_MANIFEST}"
}

run_emacs() {
  rust_dive_prepare_emacs
  "${EMACS_BIN}" -Q --batch \
    -l "${REPO_ROOT}/emacs/test-config/lint-init.el" \
    -L "${REPO_ROOT}/emacs" \
    -l rust-dive-magit-lint.el \
    -f rust-dive-magit-format-batch-and-exit
}

if [[ $# -gt 1 ]]; then
  usage
fi

case "${1:-all}" in
  all)
    run_rust
    run_emacs
    ;;
  rust)
    run_rust
    ;;
  emacs)
    run_emacs
    ;;
  *)
    usage
    ;;
esac
