#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

usage() {
  echo "usage: ./scripts/test.sh [rust|emacs]" >&2
  exit 64
}

run_rust() {
  rust_dive_prepare_repo
  cargo fmt --all --check --manifest-path "${WORKSPACE_MANIFEST}"
  cargo clippy --manifest-path "${WORKSPACE_MANIFEST}" \
    --workspace \
    --all-targets \
    -- -D warnings
  cargo test
}

run_emacs() {
  rust_dive_prepare_emacs
  "${EMACS_BIN}" -Q --batch \
    -l "${REPO_ROOT}/emacs/test-config/lint-init.el" \
    -L "${REPO_ROOT}/emacs" \
    -l rust-dive-magit-lint.el \
    -f rust-dive-magit-lint-batch-and-exit
  "${EMACS_BIN}" -Q --batch \
    -l "${REPO_ROOT}/emacs/test-config/init.el" \
    -L "${REPO_ROOT}/emacs" \
    -l rust-dive-magit-lint-tests.el \
    -l rust-dive-magit-tests.el \
    -f ert-run-tests-batch-and-exit
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
