# rust_dive

`rust_dive` is a Rust code-structure diff tool with:

- a CLI for listing entities and diffing snapshots
- an Emacs integration in [emacs/rust-dive-magit.el](/root/2026-04-21-diff/emacs/rust-dive-magit.el) that renders JSON output in a dedicated buffer

## Development

Run the project test entrypoints from the workspace root:

```bash
./scripts/format.sh
./scripts/format.sh rust
./scripts/format.sh emacs
./scripts/test.sh
./scripts/test.sh rust
./scripts/test.sh emacs
```

To install the pre-commit hook in your Git checkout:

```bash
ln -sf ../../scripts/pre-commit.sh .git/hooks/pre-commit
```

## Emacs Usage

The Emacs package assumes a normal `rust_dive` binary by default.

For local development from this workspace, override that from outside the
package by pointing `rust-dive-magit-executable` at the wrapper script in this
repo. If you also want Rust Dive to appear in Magit's diff transient as `D`,
enable `rust-dive-magit-bindings-mode`.

Example Emacs config:

```elisp
(add-to-list 'load-path "/path/to/rust_dive/emacs")
(require 'rust-dive-magit)

(setq rust-dive-magit-executable
      "/path/to/rust_dive/scripts/rust_dive_dev")

(rust-dive-magit-bindings-mode 1)
```

Example with `use-package`:

```elisp
(use-package rust-dive-magit
  :load-path "/path/to/rust_dive/emacs"
  :commands (rust-dive-magit-diff)
  :init
  (setq rust-dive-magit-executable
        "/path/to/rust_dive/scripts/rust_dive_dev")
  :config
  (rust-dive-magit-bindings-mode 1))
```

That wrapper runs:

```bash
cargo run --release --manifest-path /path/to/rust_dive/Cargo.toml -- ...
```

After that:

- `M-x rust-dive-magit-diff` opens a Rust Dive diff buffer
- in Magit's diff popup, `D` runs Rust Dive using Magit's current diff context

`rust-dive-magit-diff` compares `HEAD` to the current working tree by default
and renders results in the `*rust-dive*` buffer.
