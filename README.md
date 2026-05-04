# Difftron

Difftron is a code diff tool that matches semantic entities (structs, functions, etc.) before doing a line-based diff.
See [this newsletter](https://kevinlynagh.com/newsletter/2026_04_overthinking/#structural-diffing) for motivation and a survey of prior art.

Difftron has CLI for listing entities and diffing snapshots, but the primary UI is an Emacs [Magit](https://magit.vc/)-style interface:

![](TODO screenshot)

Difftron diffs "snapshots", which can be refs in a git repository, folders, or individual files.

So far everything has been vibe-coded --- currently I'm more interested in exploring the UI and overall design space than I am in writing idiomatic/concise Rust or Emacs lisp.


## Language support

Currently supports the languages I use: Rust, Clojure, and TypeScript.


## Usage

While this project is in experimental phase, a rust toolchain is required to build binaries locally and a "formal" Emacs package won't be published.
This is the function I use to (re)load the package:

```
(defun difftron-reload ()
  (interactive)
  (let ((base-path "/where-you-put-difftron-project-folder"))
    (when (featurep 'difftron)
      (unload-feature 'difftron t))
    (load (concat base-path "/emacs/difftron.el"))
    (difftron-bindings-mode)
    (setq difftron-executable (concat base-path "/script/difftron_dev"))))
```

You can run `M-x difftron-diff` to diff two snapshots, but I tend to use it from within Magit's diff popup (press `d` for Magit's popup, then `D` for Difftron).
Doing this from a Magit diff will jump to the corresponding entity in Difftron.


## Development

Run the project test entrypoints from the workspace root:

```bash
./script/format.sh [rust | emacs]
./script/test.sh [rust | emacs]
```

To install the pre-commit hook in your Git checkout:

```bash
cat <<'EOF' > .git/hooks/pre-commit
#!/usr/bin/env bash
set -euo pipefail
"$(git rev-parse --show-toplevel)/script/pre-commit.sh"
EOF
chmod +x .git/hooks/pre-commit
```


## TODO / ideas

- Instead of jumping to file from diff, jump to full git worktree (so LSP, etc. works)
