# rust_dive

`rust_dive` is a Rust code-structure diff tool with:

- a CLI for listing entities and diffing snapshots
- an Emacs integration in [emacs/rust-dive-magit.el](/root/2026-04-21-diff/emacs/rust-dive-magit.el) that renders JSON output in a dedicated buffer

## Development

Run the project test entrypoints from the workspace root:

```bash
./scripts/run-rust-tests.sh
./scripts/run-emacs-tests.sh
./scripts/run-tests.sh
```

## Emacs Development Setup

The Emacs package still assumes there will eventually be a normal `rust_dive`
binary. For local development, override that from outside the package by
pointing `rust-dive-magit-executable` at the wrapper script in this repo.

Example Emacs config:

```elisp
(add-to-list 'load-path "/root/2026-04-21-diff/emacs")
(require 'rust-dive-magit)

(setq rust-dive-magit-executable
      "/scripts/rust_dive_dev")
```

That wrapper runs:

```bash
cargo run --release --manifest-path /root/2026-04-21-diff/Cargo.toml -- ...
```

After that, open a file inside a Git repo and run:

```elisp
M-x rust-dive-magit-diff
```

By default it compares `HEAD` to the current working tree and renders results in
the `*rust-dive*` buffer.
