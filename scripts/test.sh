#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/_common.sh"

usage() {
  echo "usage: ./script/test.sh [rust|emacs|shell]" >&2
  exit 64
}

run_rust() {
  cargo fmt --check
  cargo clippy -- --deny warnings
  cargo test
}

run_shell() {
  mapfile -t shell_scripts < <(difftron_shell_scripts)
  shellcheck_exclusions=(
    # SC2164: rely on set -e to stop scripts when cd fails.
    SC2164
  )
  shfmt --indent 2 --diff "${shell_scripts[@]}"
  shellcheck --exclude "$(
    IFS=,
    echo "${shellcheck_exclusions[*]}"
  )" --severity warning "${shell_scripts[@]}"
}

run_emacs() {
  difftron_prepare_emacs
  "$EMACS_BIN" --quick --batch \
    --load "$REPO_ROOT/emacs/test-config/lint-init.el" \
    --directory "$REPO_ROOT/emacs" \
    --load difftron-lint.el \
    --funcall difftron-lint-batch-and-exit
  "$EMACS_BIN" --quick --batch \
    --load "$REPO_ROOT/emacs/test-config/init.el" \
    --directory "$REPO_ROOT/emacs" \
    --load difftron-lint-tests.el \
    --load difftron-tests.el \
    --funcall ert-run-tests-batch-and-exit
}

if [[ $# -gt 1 ]]; then
  usage
fi

case "${1:-all}" in
all)
  run_rust
  run_shell
  run_emacs
  ;;
rust)
  run_rust
  ;;
shell)
  run_shell
  ;;
emacs)
  run_emacs
  ;;
*)
  usage
  ;;
esac
