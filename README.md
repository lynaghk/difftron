# difftron

`difftron` is a Rust code-structure diff tool with:

- a CLI for listing entities and diffing snapshots
- an Emacs integration in [emacs/difftron-magit.el](/root/2026-04-21-diff/emacs/difftron-magit.el) that renders JSON output in a dedicated buffer

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

## Emacs Usage

The Emacs package assumes a normal `difftron` binary by default.

For local development from this workspace, override that from outside the
package by pointing `difftron-magit-executable` at the wrapper script in this
repo. If you also want difftron to appear in Magit's diff transient as `D`,
enable `difftron-magit-bindings-mode`.

Example Emacs config:

```elisp
(add-to-list 'load-path "/path/to/difftron/emacs")
(require 'difftron-magit)

(setq difftron-magit-executable
      "/path/to/difftron/script/difftron_dev")

(difftron-magit-bindings-mode 1)
```

Example with `use-package`:

```elisp
(use-package difftron-magit
  :load-path "/path/to/difftron/emacs"
  :commands (difftron-magit-diff)
  :init
  (setq difftron-magit-executable
        "/path/to/difftron/script/difftron_dev")
  :config
  (difftron-magit-bindings-mode 1))
```

That wrapper runs:

```bash
cargo run --release --manifest-path /path/to/difftron/Cargo.toml -- ...
```

After that:

- `M-x difftron-magit-diff` opens a difftron diff buffer
- in Magit's diff popup, `D` runs difftron using Magit's current diff context

`difftron-magit-diff` compares `HEAD` to the current working tree by default
and renders results in the `*difftron*` buffer.
