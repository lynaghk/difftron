# Difftron

Difftron is a code diff tool that matches semantic entities (structs, functions, etc.) before doing a line-based diff.
See [this newsletter](https://kevinlynagh.com/newsletter/2026_04_overthinking/#structural-diffing) for motivation and a survey of prior art.

While there is a CLI for listing entities and diffing snapshots, the primary user interface an Emacs [Magit](https://magit.vc/)-style interface:

<a href="https://kevinlynagh.com/misc/2026_05_04_difftron_demo.mp4">
<img src="https://kevinlynagh.com/newsletter/2026_05_difftron/difftron.png" alt="The Difftron UI in Emacs, showing changes in a file > entity type hierarchy with one function change expanded to show a side-by-side diff with highlighting"/>
</a>

[Check out the demo video](https://kevinlynagh.com/misc/2026_05_04_difftron_demo.mp4) for more details.


## Status

I use Difftron regularly to review Rust and Clojure code.

I've vibe-coded everything with Codex/GPT 5.5.
While I'm open to suggestions about architectural or code improvements, my primary interests are:

- exploring the overall problem/design space
- using the tool to support my other work


## Usage

Checkout this repository somewhere on your computer, then run:

    (load "wherever-you-checked-out-difftron-repo/emacs/difftron.el")
    (setq difftron-executable "wherever-you-checked-out-difftron-repo/scripts/difftron_dev")
    (difftron-bindings-mode)

You will need a Rust toolchain on your `PATH`.

Then you can run `M-x difftron-diff` to diff two snapshots.

I tend to use Difftron from within Magit's diff popup (press `d` for Magit's popup, then `D` for Difftron).
Doing this from a Magit diff will jump to the corresponding entity in Difftron.

When I'm working on difftron itself, I use a little reload function so I can unload/reload the elisp:


    (defun difftron-reload ()
      (interactive)
      (let ((base-path "/Users/dev/work/difftron"))
        (when (featurep 'difftron)
          (unload-feature 'difftron t))
        (load (concat base-path "/emacs/difftron.el"))

        (setq difftron-executable (concat base-path "/scripts/difftron_dev"))))

    (difftron-reload)


## Conceptual model

Difftron diffs "snapshots", which can be refs in a git repository, folders, or individual files.


## Language support

Currently supports the languages I use: Rust, Clojure, and TypeScript.


## Development

Please format and test every commit:

    ./scripts/format.sh
    ./scripts/test.sh



## TODO / ideas

- Instead of jumping to file from diff, jump to full git worktree (so LSP, etc. works)
