# Contributing

Thanks for helping with Difftron.

This project is experimental, so small, focused changes are easiest to review.

## Setup

Install the project tools from the workspace root.

    mise install

Use the checked-in scripts for formatting and testing.

    ./scripts/format.sh
    ./scripts/test.sh

The scripts accept an optional target when you only need one part of the project.

    ./scripts/format.sh rust
    ./scripts/format.sh emacs
    ./scripts/format.sh shell
    ./scripts/test.sh rust
    ./scripts/test.sh emacs
    ./scripts/test.sh shell

## Before Committing

Every commit should be formatted and should pass the full test suite.

Run the formatter before staging files.

    ./scripts/format.sh

Then run the checks.

    ./scripts/test.sh

The test script also checks formatting, so it is the command to trust before committing.

## Pre-Commit Hook

You can install the local pre-commit hook from the workspace root.

    cat <<'EOF' > .git/hooks/pre-commit
    #!/usr/bin/env bash
    set -euo pipefail
    "$(git rev-parse --show-toplevel)/scripts/pre-commit.sh"
    EOF
    chmod +x .git/hooks/pre-commit

The hook runs `./scripts/test.sh`.

It does not run `./scripts/format.sh`, because a commit hook should not rewrite files after you have staged them.

If the hook reports formatting failures, run `./scripts/format.sh`, review the changes, stage them, and commit again.

## Development Workflow

For code changes, prefer a red-green workflow.

Start by adding or updating a test that fails for the behavior you want to change.

Then make the smallest implementation change that passes the test.

Finish by running the relevant formatter and test target, or the full scripts when the change crosses Rust, Emacs Lisp, and shell code.

Do not add tests only for script or configuration changes.

## Pull Requests

Keep pull requests focused on one behavior or cleanup.

Describe what changed, why it changed, and which commands you ran.

Include any limitations or follow-up work that reviewers should know about.
