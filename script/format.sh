#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/_common.sh"

usage() {
  echo "usage: ./script/format.sh [rust|emacs|shell]" >&2
  exit 64
}

run_rust() {
  cargo fmt
}

run_shell() {
  mapfile -t shell_scripts < <(difftron_shell_scripts)
  shfmt --indent 2 --write "${shell_scripts[@]}"
}

run_emacs() {
  difftron_prepare_emacs
  "${EMACS_BIN}" --quick --batch \
    --load "${REPO_ROOT}/emacs/test-config/lint-init.el" \
    --directory "${REPO_ROOT}/emacs" \
    --load difftron-lint.el \
    --funcall difftron-format-batch-and-exit
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
