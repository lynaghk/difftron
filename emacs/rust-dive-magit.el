;;; rust-dive-magit.el --- View rust_dive output in Magit -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit "4.0.0"))
;; Keywords: tools, vc
;; URL: https://github.com/openai/2026-04-21-diff

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Dedicated Emacs integration for the rust_dive CLI.  The main entrypoint is
;; `rust-dive-magit-diff', which shells out to `rust_dive diff --format json'
;; and renders the result in a foldable buffer.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'diff-mode)
(require 'json)
(require 'magit-git)
(require 'magit-mode)
(require 'magit-section)
(require 'seq)
(require 'subr-x)
(require 'transient)

(defgroup rust-dive-magit nil
  "Emacs integration for the rust_dive CLI."
  :group 'tools)

(defface rust-dive-magit-level-1-heading
  '((t :inherit magit-diff-file-heading))
  "Face for first nested heading level in Rust Dive buffers."
  :group 'rust-dive-magit)

(defface rust-dive-magit-level-2-heading
  '((t :inherit magit-diff-file-heading-selection))
  "Face for second nested heading level in Rust Dive buffers."
  :group 'rust-dive-magit)

(defcustom rust-dive-magit-executable "rust_dive"
  "Path to the rust_dive executable."
  :type 'file
  :group 'rust-dive-magit)

(defcustom rust-dive-magit-buffer-name "*rust-dive*"
  "Name of the rust_dive results buffer."
  :type 'string
  :group 'rust-dive-magit)

(defcustom rust-dive-magit-default-grouping 'file
  "Default top-level grouping for Rust Dive buffers."
  :type
  '
  (choice
    (const :tag "Entity then file" kind)
    (const :tag "File then entity" file))
  :group 'rust-dive-magit)

(defconst rust-dive-magit--magit-diff-suffix
  '("D" "Rust Dive" rust-dive-magit-diff-dwim))

(defvar rust-dive-magit-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "g") #'rust-dive-magit-refresh)
    (define-key map (kbd "f") #'rust-dive-magit-cycle-grouping)
    (define-key map (kbd "h") #'rust-dive-magit-dispatch)
    (define-key map (kbd "?") #'rust-dive-magit-dispatch)
    (define-key map (kbd "l") #'rust-dive-magit-select-left)
    (define-key
      map
      (kbd "m")
      #'rust-dive-magit-toggle-commit-messages)
    (define-key map (kbd "r") #'rust-dive-magit-select-right)
    (define-key map (kbd "N") #'rust-dive-magit-next-commit)
    (define-key map (kbd "P") #'rust-dive-magit-previous-commit)
    (define-key
      map
      (kbd "TAB")
      #'rust-dive-magit-toggle-section-or-message)
    (define-key map (kbd "RET") #'rust-dive-magit-visit-thing)
    map)
  "Keymap for `rust-dive-magit-mode'.")

(defvar-local rust-dive-magit--command-args nil)
(defvar-local rust-dive-magit--default-directory nil)
(defvar-local rust-dive-magit--payload nil)
(defvar-local rust-dive-magit--entity-kind-order nil)
(defvar-local rust-dive-magit--entity-kinds nil)
(defvar-local rust-dive-magit--grouping nil
  "Current grouping mode for the Rust Dive buffer.")
(defvar-local rust-dive-magit--commit-message-regions nil
  "Alist of expanded commit message regions by side.")

(define-derived-mode
  rust-dive-magit-mode
  magit-section-mode
  "Rust-Dive"
  "Major mode for rust_dive results."
  (setq-local truncate-lines t))

(transient-define-prefix
  rust-dive-magit-dispatch
  ()
  "Show commands for `rust-dive-magit-mode'."
  [
    ["Rust Dive"
      ("g" "Refresh" rust-dive-magit-refresh)
      ("f" "Cycle grouping" rust-dive-magit-cycle-grouping)
      ("l" "Select left" rust-dive-magit-select-left)
      ("m" "Toggle messages" rust-dive-magit-toggle-commit-messages)
      ("r" "Select right" rust-dive-magit-select-right)
      ("q" "Quit buffer" quit-window)
      ("TAB"
        "Toggle section/message"
        rust-dive-magit-toggle-section-or-message)
      ("RET" "Visit thing" rust-dive-magit-visit-thing)]
    ["Visibility"
      ("<backtab>" "Cycle all" magit-section-cycle-global)
      ("1" "Level 1" magit-section-show-level-1)
      ("2" "Level 2" magit-section-show-level-2)
      ("3" "Level 3" magit-section-show-level-3)
      ("4" "Level 4" magit-section-show-level-4)
      ("M-1" "All level 1" magit-section-show-level-1-all)
      ("M-2" "All level 2" magit-section-show-level-2-all)
      ("M-3" "All level 3" magit-section-show-level-3-all)
      ("M-4" "All level 4" magit-section-show-level-4-all)]
    ["Movement"
      ("N" "Next commit" rust-dive-magit-next-commit)
      ("P" "Previous commit" rust-dive-magit-previous-commit)
      ("n" "Next section" magit-section-forward)
      ("p" "Previous section" magit-section-backward)
      ("M-n" "Next sibling" magit-section-forward-sibling)
      ("M-p" "Previous sibling" magit-section-backward-sibling)]])

(defun rust-dive-magit-diff-dwim ()
  "Run `rust_dive diff' using the current Magit diff context."
  (interactive)
  (require 'magit-diff)
  (pcase-let*
    (
      (default-directory (rust-dive-magit--repo-root))
      (`(,_args ,paths) (magit-diff-arguments))
      (`(,lhs ,rhs)
        (rust-dive-magit--dwim-endpoints
          (ignore-errors
            (magit-diff--dwim))
          default-directory)))
    (rust-dive-magit-diff lhs rhs paths)))

(defun rust-dive-magit-diff (lhs rhs &optional paths)
  "Run `rust_dive diff' for LHS, RHS, and optional PATHS.
When called interactively, default to comparing `HEAD' against the current
working tree rooted at the current repository."
  (interactive
    (let*
      (
        (repo-root (rust-dive-magit--repo-root))
        (default-lhs "HEAD")
        (default-rhs repo-root)
        (lhs (read-string "Left snapshot/rev: " default-lhs))
        (rhs (read-string "Right snapshot/rev: " default-rhs))
        (path-input
          (read-string "Filter paths (comma-separated, optional): ")))
      (list lhs rhs (rust-dive-magit--split-paths path-input))))
  (let*
    (
      (default-directory (rust-dive-magit--repo-root))
      (args
        (append
          (list "diff" lhs rhs "--format" "json")
          (cl-mapcan (lambda (path) (list "--path" path)) paths)))
      (payload (rust-dive-magit--run-command default-directory args)))
    (rust-dive-magit--display-buffer default-directory args payload)))

(defun rust-dive-magit-refresh ()
  "Re-run the last rust_dive command in the current buffer."
  (interactive)
  (unless
    (and rust-dive-magit--command-args
      rust-dive-magit--default-directory)
    (user-error
      "No rust_dive command is associated with this buffer"))
  (magit-refresh-buffer))

(defun rust-dive-magit-cycle-grouping ()
  "Cycle the Rust Dive grouping mode for the current buffer."
  (interactive)
  (unless rust-dive-magit--payload
    (user-error
      "No rust_dive payload is associated with this buffer"))
  (setq rust-dive-magit-default-grouping
    (pcase rust-dive-magit--grouping
      ('kind 'file)
      (_ 'kind)))
  (setq rust-dive-magit--grouping rust-dive-magit-default-grouping)
  (rust-dive-magit--display-buffer
    rust-dive-magit--default-directory
    rust-dive-magit--command-args
    rust-dive-magit--payload)
  (with-current-buffer rust-dive-magit-buffer-name
    (magit-section-show-level-3)))

(defun rust-dive-magit-select-left ()
  "Select a new left-hand snapshot and refresh the diff."
  (interactive)
  (rust-dive-magit--select-side 'lhs))

(defun rust-dive-magit-select-right ()
  "Select a new right-hand snapshot and refresh the diff."
  (interactive)
  (rust-dive-magit--select-side 'rhs))

(defun rust-dive-magit--select-side (side)
  "Select a new snapshot for SIDE and refresh the current diff."
  (unless rust-dive-magit--payload
    (user-error
      "No rust_dive payload is associated with this buffer"))
  (unless rust-dive-magit--default-directory
    (user-error
      "No rust_dive command is associated with this buffer"))
  (let*
    (
      (lhs-snapshot (plist-get rust-dive-magit--payload :lhs))
      (rhs-snapshot (plist-get rust-dive-magit--payload :rhs))
      (new-arg
        (rust-dive-magit--read-snapshot-like
          side
          (pcase side
            ('lhs lhs-snapshot)
            (_ rhs-snapshot))))
      (lhs
        (if (eq side 'lhs)
          new-arg
          (rust-dive-magit--snapshot-arg lhs-snapshot)))
      (rhs
        (if (eq side 'rhs)
          new-arg
          (rust-dive-magit--snapshot-arg rhs-snapshot))))
    (rust-dive-magit--run-and-display-diff lhs rhs)))

(defun rust-dive-magit--read-snapshot-like (side snapshot)
  "Read a replacement for SNAPSHOT on SIDE."
  (let
    (
      (label (rust-dive-magit--side-label side))
      (root (plist-get snapshot :root)))
    (pcase (plist-get snapshot :kind)
      ("git_revision"
        (let
          (
            (default-directory (or root default-directory))
            (rev
              (or (plist-get snapshot :rev)
                (user-error
                  "Git revision snapshot has no revision"))))
          (magit-read-branch-or-commit (format "%s ref" label) rev)))
      ("directory"
        (file-name-as-directory
          (expand-file-name
            (read-directory-name (format "%s folder: " label)
              root
              root
              t))))
      ("file"
        (expand-file-name
          (read-file-name (format "%s file: " label)
            (and root (file-name-directory root))
            root
            t)))
      (_
        (user-error "Don't know how to select %s snapshots"
          (plist-get snapshot :kind))))))

(defun rust-dive-magit--snapshot-arg (snapshot)
  "Return the command argument for SNAPSHOT."
  (pcase (plist-get snapshot :kind)
    ("git_revision"
      (or (plist-get snapshot :rev)
        (user-error "Git revision snapshot has no revision")))
    ((or "directory" "file")
      (or (plist-get snapshot :root)
        (user-error "Filesystem snapshot has no path")))
    (_
      (user-error "Don't know how to use %s snapshots"
        (plist-get snapshot :kind)))))

(defun rust-dive-magit--side-label (side)
  "Return a prompt label for SIDE."
  (pcase side
    ('lhs "Left")
    (_ "Right")))

(defun rust-dive-magit-toggle-section-or-message ()
  "Toggle the commit message at point or the current Magit section."
  (interactive)
  (if-let ((side (rust-dive-magit--snapshot-side-at-point)))
    (rust-dive-magit--toggle-commit-message side)
    (magit-section-toggle (magit-current-section))))

(defun rust-dive-magit-toggle-commit-messages ()
  "Toggle commit messages for both Git revision snapshots."
  (interactive)
  (let ((sides (rust-dive-magit--commit-message-sides)))
    (unless sides
      (user-error "No Git revision snapshots in this buffer"))
    (if
      (seq-some
        (lambda (side)
          (not (rust-dive-magit--commit-message-expanded-p side)))
        sides)
      (dolist (side sides)
        (unless (rust-dive-magit--commit-message-expanded-p side)
          (rust-dive-magit--show-commit-message side)))
      (dolist (side sides)
        (rust-dive-magit--hide-commit-message side)))))

(defun rust-dive-magit--snapshot-side-at-point ()
  "Return the snapshot side at point, if point is on one."
  (or (get-text-property (point) 'rust-dive-magit-snapshot-side)
    (and (> (point) (point-min))
      (get-text-property (1- (point)) 'rust-dive-magit-snapshot-side))
    (get-text-property
      (line-beginning-position)
      'rust-dive-magit-snapshot-side)))

(defun rust-dive-magit--commit-message-sides ()
  "Return sides that currently show Git revisions."
  (seq-filter
    (lambda (side)
      (equal
        (plist-get (rust-dive-magit--snapshot-for-side side) :kind)
        "git_revision"))
    '(lhs rhs)))

(defun rust-dive-magit--snapshot-for-side (side)
  "Return the payload snapshot for SIDE."
  (or
    (and rust-dive-magit--payload
      (plist-get
        rust-dive-magit--payload
        (pcase side
          ('lhs :lhs)
          (_ :rhs))))
    (when-let
      (
        (pos
          (text-property-any
            (point-min)
            (point-max)
            'rust-dive-magit-snapshot-side
            side)))
      (get-text-property pos 'rust-dive-magit-snapshot))))

(defun rust-dive-magit--toggle-commit-message (side)
  "Toggle the commit message for SIDE."
  (if (rust-dive-magit--commit-message-expanded-p side)
    (rust-dive-magit--hide-commit-message side)
    (rust-dive-magit--show-commit-message side)))

(defun rust-dive-magit--commit-message-expanded-p (side)
  "Return non-nil if SIDE's commit message is expanded."
  (assq side rust-dive-magit--commit-message-regions))

(defun rust-dive-magit--show-commit-message (side)
  "Insert SIDE's commit message below its snapshot line."
  (let*
    (
      (snapshot (rust-dive-magit--snapshot-for-side side))
      (message (rust-dive-magit--commit-message snapshot))
      (insert-at (rust-dive-magit--snapshot-line-end side)))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char insert-at)
        (forward-line 1)
        (let ((start (point)))
          (insert (rust-dive-magit--format-commit-message message))
          (add-text-properties
            start (point)
            (list
              'rust-dive-magit-snapshot-side
              side
              'font-lock-face
              'magit-section-secondary-heading))
          (push
            (cons
              side
              (cons (copy-marker start) (copy-marker (point))))
            rust-dive-magit--commit-message-regions))))))

(defun rust-dive-magit--hide-commit-message (side)
  "Remove SIDE's expanded commit message."
  (when-let
    ((region (assq side rust-dive-magit--commit-message-regions)))
    (let
      (
        (start (cadr region))
        (end (cddr region))
        (inhibit-read-only t))
      (delete-region start end)
      (set-marker start nil)
      (set-marker end nil)
      (setq rust-dive-magit--commit-message-regions
        (assq-delete-all
          side
          rust-dive-magit--commit-message-regions)))))

(defun rust-dive-magit--snapshot-line-end (side)
  "Return the line end position for SIDE's snapshot line."
  (or
    (when-let
      (
        (pos
          (text-property-any
            (point-min)
            (point-max)
            'rust-dive-magit-snapshot-side
            side)))
      (save-excursion
        (goto-char pos)
        (line-end-position)))
    (user-error "No snapshot line for %s" side)))

(defun rust-dive-magit--commit-message (snapshot)
  "Return the full commit message for SNAPSHOT."
  (let
    (
      (rev
        (or (plist-get snapshot :rev)
          (user-error "Git revision snapshot has no revision")))
      (default-directory
        (or (plist-get snapshot :root) default-directory)))
    (or (magit-git-string "log" "-1" "--format=%B" rev) "")))

(defun rust-dive-magit--format-commit-message (message)
  "Format commit MESSAGE for display under a snapshot line."
  (let ((message (string-trim-right message)))
    (if (string-empty-p message)
      "  No commit message.\n"
      (mapconcat
        (lambda (line)
          (if (string-empty-p line)
            "\n"
            (format "  %s\n" line)))
        (split-string message "\n")
        ""))))

(defun rust-dive-magit-next-commit ()
  "Show the next commit on HEAD's first-parent history."
  (interactive)
  (rust-dive-magit--show-commit-diff
    (rust-dive-magit--next-commit
      (rust-dive-magit--current-rhs-revision))))

(defun rust-dive-magit-previous-commit ()
  "Show the first-parent commit before the current RHS commit."
  (interactive)
  (rust-dive-magit--show-commit-diff
    (or
      (rust-dive-magit--commit-parent
        (rust-dive-magit--current-rhs-revision))
      (user-error "No previous commit"))))

(defun rust-dive-magit--current-rhs-revision ()
  "Return the Git revision for the current diff RHS."
  (let ((rhs (plist-get rust-dive-magit--payload :rhs)))
    (unless (equal (plist-get rhs :kind) "git_revision")
      (user-error
        "Rust Dive buffer is not showing a Git revision diff"))
    (or (plist-get rhs :rev)
      (user-error "Rust Dive diff RHS has no Git revision"))))

(defun rust-dive-magit--next-commit (rev)
  "Return the next commit after REV on HEAD's first-parent history."
  (let
    (
      (default-directory
        (or rust-dive-magit--default-directory default-directory)))
    (or
      (car
        (magit-git-lines
          "rev-list"
          "--first-parent"
          "--reverse"
          (format "%s..HEAD" rev)))
      (user-error "No next commit on HEAD's first-parent history"))))

(defun rust-dive-magit--commit-parent (rev)
  "Return the first parent of REV, or nil for a root commit."
  (let*
    (
      (default-directory
        (or rust-dive-magit--default-directory default-directory))
      (line (car (magit-git-lines "rev-list" "-1" "--parents" rev)))
      (parts (and line (split-string line))))
    (cadr parts)))

(defun rust-dive-magit--show-commit-diff (rev)
  "Render the Rust Dive diff for commit REV."
  (let
    (
      (parent
        (or (rust-dive-magit--commit-parent rev)
          (user-error "Commit %s has no parent" rev))))
    (rust-dive-magit--run-and-display-diff parent rev)))

(defun rust-dive-magit--run-and-display-diff (lhs rhs)
  "Run and display a Rust Dive diff from LHS to RHS."
  (unless rust-dive-magit--default-directory
    (user-error
      "No rust_dive command is associated with this buffer"))
  (let*
    (
      (args
        (append
          (list "diff" lhs rhs "--format" "json")
          (rust-dive-magit--command-path-args
            rust-dive-magit--command-args)))
      (payload
        (rust-dive-magit--run-command
          rust-dive-magit--default-directory
          args)))
    (rust-dive-magit--display-buffer
      rust-dive-magit--default-directory
      args
      payload)))

(defun rust-dive-magit--command-path-args (args)
  "Return the --path arguments from rust_dive command ARGS."
  (let (paths)
    (while args
      (let ((arg (pop args)))
        (when (and (equal arg "--path") args)
          (push "--path" paths)
          (push (pop args) paths))))
    (nreverse paths)))

(defun rust-dive-magit-visit-thing ()
  "Visit the entity at point or activate a button."
  (interactive)
  (if-let*
    (
      (section (rust-dive-magit--entity-section-at-point))
      (entity (plist-get (oref section value) :entity)))
    (rust-dive-magit--visit-entity entity)
    (if-let ((button (rust-dive-magit--button-at-point)))
      (push-button (button-start button))
      (magit-section-toggle (magit-current-section)))))

(defun rust-dive-magit--button-at-point ()
  "Return the button at point, accepting point just after button text."
  (or (button-at (point))
    (and (> (point) (point-min)) (button-at (1- (point))))))

(defun rust-dive-magit--display-buffer
  (repo-default-directory args payload)
  "Render PAYLOAD in the dedicated buffer.
REPO-DEFAULT-DIRECTORY and ARGS are stored to support refresh."
  (let ((buffer (get-buffer-create rust-dive-magit-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (rust-dive-magit-mode)
        (setq rust-dive-magit--grouping
          rust-dive-magit-default-grouping)
        (setq rust-dive-magit--default-directory
          repo-default-directory)
        (setq rust-dive-magit--command-args args)
        (setq rust-dive-magit--payload payload)
        (erase-buffer)
        (rust-dive-magit--insert-payload payload)
        (magit-section-show-level-3)
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(defun rust-dive-magit-refresh-buffer ()
  "Refresh the current Rust Dive buffer using Magit's refresh machinery."
  (setq rust-dive-magit--payload
    (rust-dive-magit--run-command
      rust-dive-magit--default-directory
      rust-dive-magit--command-args))
  (rust-dive-magit--insert-payload rust-dive-magit--payload))

(defun rust-dive-magit--insert-payload (payload)
  "Insert PAYLOAD into the current buffer."
  (setq rust-dive-magit--commit-message-regions nil)
  (setq rust-dive-magit--entity-kind-order
    (plist-get payload :entity_kind_order))
  (setq rust-dive-magit--entity-kinds
    (plist-get payload :entity_kinds))
  (magit-insert-section
    (rust-dive-root)
    (pcase (plist-get payload :command)
      ("diff" (rust-dive-magit--insert-diff payload))
      ("list" (rust-dive-magit--insert-list payload))
      (_
        (insert
          (format "Unsupported rust_dive command: %S" payload))))))

(defun rust-dive-magit--insert-list (payload)
  "Insert a list-mode PAYLOAD into the current buffer."
  (rust-dive-magit--insert-title
    (format "rust_dive list %s"
      (plist-get (plist-get payload :snapshot) :label)))
  (rust-dive-magit--insert-items
    (mapcar
      #'rust-dive-magit--list-entity->item
      (plist-get payload :entities))))

(defun rust-dive-magit--insert-diff (payload)
  "Insert a diff PAYLOAD into the current buffer."
  (let
    (
      (lhs (plist-get payload :lhs))
      (rhs (plist-get payload :rhs)))
    (rust-dive-magit--insert-snapshot-line "lhs" lhs)
    (rust-dive-magit--insert-snapshot-line "rhs" rhs)
    (insert "\n")
    (rust-dive-magit--insert-items
      (rust-dive-magit--diff-items payload))))

(defun rust-dive-magit--insert-snapshot-line (name snapshot)
  "Insert one clickable diff endpoint NAME for SNAPSHOT."
  (let ((start (point)))
    (insert
      (propertize (format "%s: " name)
        'font-lock-face
        'magit-section-heading))
    (insert-text-button
      (rust-dive-magit--display-label (plist-get snapshot :label))
      'action
      (lambda (_button) (rust-dive-magit--visit-snapshot snapshot))
      'follow-link
      t
      'help-echo
      "RET visits snapshot"
      'font-lock-face
      'magit-section-heading)
    (when-let ((summary (plist-get snapshot :summary)))
      (unless (string-empty-p summary)
        (insert
          (propertize (format "  %s" summary)
            'font-lock-face
            'magit-section-secondary-heading))))
    (insert "\n")
    (when (equal (plist-get snapshot :kind) "git_revision")
      (add-text-properties
        start (point)
        (list
          'rust-dive-magit-snapshot-side
          (intern name)
          'rust-dive-magit-snapshot
          snapshot
          'mouse-face
          'highlight
          'help-echo
          "TAB toggles commit message, RET visits snapshot")))))

(defun rust-dive-magit--visit-snapshot (snapshot)
  "Visit SNAPSHOT using the best available Magit action."
  (pcase (plist-get snapshot :kind)
    ("git_revision"
      (let
        (
          (rev (plist-get snapshot :rev))
          (default-directory (plist-get snapshot :root)))
        (unless rev
          (user-error "Git revision snapshot has no revision"))
        (require 'magit-diff)
        (magit-show-commit rev)))
    (_
      (user-error "Don't know how to visit %s snapshots"
        (plist-get snapshot :kind)))))

(defun rust-dive-magit--display-label (label)
  "Return a compact display form for snapshot LABEL."
  (if (string-match "\\`\\(.+\\)@\\(.+\\)\\'" label)
    (let
      (
        (name (match-string 1 label))
        (rev (match-string 2 label)))
      (format "%s@%s"
        (if (string-match-p "/" name)
          (file-name-nondirectory name)
          name)
        rev))
    label))

(defun rust-dive-magit--insert-title (title)
  "Insert TITLE at the top of the current buffer."
  (insert (propertize title 'font-lock-face 'magit-section-heading))
  (insert "\n\n"))

(defun rust-dive-magit--insert-kind-groups (items)
  "Insert ITEMS grouped by entity kind."
  (let ((groups (rust-dive-magit--group-items-by-kind items)))
    (if groups
      (dolist (group groups)
        (rust-dive-magit--insert-kind-file-group
          (car group)
          (cdr group)
          0))
      (insert "No entities\n"))))

(defun rust-dive-magit--insert-file-groups (items)
  "Insert ITEMS grouped by file."
  (let ((groups (rust-dive-magit--group-items-by-file items)))
    (if groups
      (dolist (group groups)
        (rust-dive-magit--insert-file-kind-group
          (car group)
          (cdr group)
          0))
      (insert "No entities\n"))))

(defun rust-dive-magit--insert-kind-file-group (kind items depth)
  "Insert a kind heading for KIND and file groups for ITEMS at DEPTH."
  (magit-insert-section
    (rust-dive-kind kind t)
    (magit-insert-heading
      (rust-dive-magit--kind-heading kind items depth))
    (dolist (group (rust-dive-magit--group-items-by-file items))
      (rust-dive-magit--insert-file-entity-group
        (car group)
        (cdr group)
        (1+ depth)))
    (insert "\n")))

(defun rust-dive-magit--insert-file-kind-group (file items depth)
  "Insert a file heading for FILE and kind groups for ITEMS at DEPTH."
  (magit-insert-section
    (rust-dive-file file t)
    (magit-insert-heading
      (rust-dive-magit--file-heading file items depth))
    (dolist (group (rust-dive-magit--group-items-by-kind items))
      (rust-dive-magit--insert-kind-entity-group
        (car group)
        (cdr group)
        (1+ depth)))
    (insert "\n")))

(defun rust-dive-magit--insert-kind-entity-group (kind items depth)
  "Insert a kind heading for KIND and entity ITEMS at DEPTH."
  (magit-insert-section
    (rust-dive-kind kind t)
    (magit-insert-heading
      (rust-dive-magit--kind-heading kind items depth))
    (dolist (item items)
      (rust-dive-magit--insert-item item (1+ depth)))
    (insert "\n")))

(defun rust-dive-magit--insert-file-entity-group (file items depth)
  "Insert a file heading for FILE and entity ITEMS at DEPTH."
  (magit-insert-section
    (rust-dive-file file t)
    (magit-insert-heading
      (rust-dive-magit--file-heading file items depth))
    (dolist (item items)
      (rust-dive-magit--insert-item item (1+ depth)))
    (insert "\n")))

(defun rust-dive-magit--kind-heading (kind items depth)
  "Return the heading text for KIND containing ITEMS at DEPTH."
  (propertize
    (format "%s%s (%d)"
      (rust-dive-magit--indent depth)
      (rust-dive-magit--kind-label kind)
      (length items))
    'font-lock-face (rust-dive-magit--heading-face depth)))

(defun rust-dive-magit--file-heading (file items depth)
  "Return the heading text for FILE containing ITEMS at DEPTH."
  (propertize
    (format "%s%s (%d)"
      (rust-dive-magit--indent depth)
      file
      (length items))
    'font-lock-face (rust-dive-magit--heading-face depth)))

(defun rust-dive-magit--insert-item (item depth)
  "Insert ITEM as a foldable heading at DEPTH."
  (let ((entity (plist-get item :entity)))
    (magit-insert-section
      (rust-dive-entity item t)
      (magit-insert-heading
        (propertize
          (format "%s%s"
            (rust-dive-magit--indent depth)
            (plist-get item :summary))
          'font-lock-face (rust-dive-magit--heading-face depth)))
      (add-text-properties
        (oref magit-insert-section--current start)
        (oref magit-insert-section--current content)
        '
        (mouse-face
          highlight
          help-echo
          "RET visits source, TAB toggles section"))
      (pcase (plist-get item :status)
        ('modified
          (rust-dive-magit--insert-structured-diff
            (plist-get item :diff)))
        (_
          (when-let ((source (plist-get entity :source_text)))
            (rust-dive-magit--insert-diff-text
              source
              (rust-dive-magit--status-face (plist-get item :status)))
            (unless (string-suffix-p "\n" source)
              (insert "\n")))))
      (unless (eq (char-before) ?\n)
        (insert "\n"))
      (insert "\n"))))

(defun rust-dive-magit--insert-structured-diff (diff)
  "Insert structured DIFF rows using Emacs layout and faces."
  (let ((rows (plist-get diff :rows)))
    (if rows
      (let ((column-width (rust-dive-magit--modified-column-width)))
        (dolist (row rows)
          (rust-dive-magit--insert-structured-diff-row
            row
            column-width)))
      (insert "No diff output.\n"))))

(defun rust-dive-magit--insert-structured-diff-row (row column-width)
  "Insert one structured diff ROW using COLUMN-WIDTH per side."
  (rust-dive-magit--insert-structured-side
    (plist-get row :left)
    'left
    column-width)
  (insert " | ")
  (rust-dive-magit--insert-structured-side
    (plist-get row :right)
    'right
    column-width)
  (insert "\n"))

(defun rust-dive-magit--insert-structured-side
  (side side-name column-width)
  "Insert SIDE for SIDE-NAME truncated to COLUMN-WIDTH."
  (if side
    (let
      (
        (start (point))
        (face (rust-dive-magit--side-face side-name)))
      (rust-dive-magit--insert-structured-segments
        (plist-get side :segments)
        side-name
        face
        column-width)
      (when (eq side-name 'left)
        (rust-dive-magit--insert-diff-text
          (make-string (max 0 (- column-width (- (point) start))) ?\s)
          face)))
    (when (eq side-name 'left)
      (insert (make-string column-width ?\s)))))

(defun rust-dive-magit--insert-structured-segments
  (segments side-name face remaining-width)
  "Insert SEGMENTS for SIDE-NAME with FACE within REMAINING-WIDTH columns."
  (let ((remaining remaining-width))
    (dolist (segment segments)
      (when (> remaining 0)
        (let*
          (
            (text
              (truncate-string-to-width
                (or (plist-get segment :text) "")
                remaining
                0
                nil))
            (refine-face
              (rust-dive-magit--segment-refine-face
                side-name
                (plist-get segment :kind)))
            (start (point)))
          (unless (string-empty-p text)
            (rust-dive-magit--insert-diff-text text face)
            (when refine-face
              (rust-dive-magit--add-refine-overlay
                start
                (point)
                refine-face))
            (setq remaining (- remaining (string-width text)))))))))

(defun rust-dive-magit--insert-diff-text (text face)
  "Insert TEXT with optional diff FACE."
  (if face
    (insert (propertize text 'font-lock-face face))
    (insert text)))

(defun rust-dive-magit--side-face (side-name)
  "Return the base diff face for SIDE-NAME."
  (ignore side-name)
  'magit-diff-context)

(defun rust-dive-magit--segment-refine-face (side-name kind)
  "Return the refinement face for segment KIND on SIDE-NAME."
  (pcase kind
    ("novel"
      (pcase side-name
        ('left 'diff-refine-removed)
        (_ 'diff-refine-added)))
    (_ nil)))

(defun rust-dive-magit--add-refine-overlay (start end face)
  "Add a Magit-style fine diff overlay from START to END using FACE."
  (let ((overlay (make-overlay start end nil t)))
    (overlay-put overlay 'diff-mode 'fine)
    (overlay-put overlay 'evaporate t)
    (overlay-put overlay 'face face)
    overlay))

(defun rust-dive-magit--modified-column-width ()
  "Return the per-side width for structured modified diffs."
  (max 24 (/ (- (rust-dive-magit--current-display-width) 3) 2)))

(defun rust-dive-magit--visit-entity (entity)
  "Visit ENTITY in another buffer."
  (let
    (
      (file (plist-get entity :file_path))
      (line (plist-get entity :start_line))
      (column (plist-get entity :start_col)))
    (find-file-other-window file)
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column (max 0 (1- column)))))

(defun rust-dive-magit--diff-items (payload)
  "Flatten diff PAYLOAD into display items."
  (append
    (mapcar
      (lambda (entity)
        (rust-dive-magit--item-from-entity 'added entity))
      (plist-get payload :added))
    (mapcar
      (lambda (entity)
        (rust-dive-magit--item-from-entity 'deleted entity))
      (plist-get payload :deleted))
    (mapcan
      #'rust-dive-magit--items-from-move
      (plist-get payload :moved))
    (mapcar
      #'rust-dive-magit--item-from-change
      (plist-get payload :modified))))

(defun rust-dive-magit--item-from-change (change)
  "Build a display item from modified CHANGE."
  (let ((rhs (plist-get change :rhs)))
    (list
      :kind (plist-get rhs :kind)
      :status 'modified
      :entity rhs
      :summary (format "M %s" (plist-get rhs :name))
      :diff (plist-get change :diff))))

(defun rust-dive-magit--items-from-move (change)
  "Build source-side and destination-side display items from moved CHANGE."
  (let
    (
      (lhs (plist-get change :lhs))
      (rhs (plist-get change :rhs)))
    (list
      (list
        :kind (plist-get lhs :kind)
        :status 'moved-from
        :entity lhs
        :summary (format "Moved from here to %s" (plist-get rhs :name)))
      (list
        :kind (plist-get rhs :kind)
        :status 'moved-to
        :entity rhs
        :summary (format "Moved here from %s" (plist-get lhs :name))))))

(defun rust-dive-magit--item-from-entity (status entity)
  "Build a display item from ENTITY with STATUS."
  (list
    :kind (plist-get entity :kind)
    :status status
    :entity entity
    :summary
    (format "%s %s"
      (pcase status
        ('added "+")
        ('deleted "-")
        (_ " "))
      (plist-get entity :name))))

(defun rust-dive-magit--list-entity->item (entity)
  "Build a display item from a list-mode ENTITY."
  (list
    :kind (plist-get entity :kind)
    :status 'present
    :entity entity
    :summary (plist-get entity :name)))

(defun rust-dive-magit--group-items
  (items key-fn group-lessp &optional item-lessp)
  "Group ITEMS by KEY-FN, sorting groups with GROUP-LESSP.
When ITEM-LESSP is non-nil, sort items within each group using it."
  (let
    (
      (table (make-hash-table :test #'equal))
      keys)
    (dolist (item items)
      (let ((key (funcall key-fn item)))
        (unless (gethash key table)
          (push key keys)
          (puthash key nil table))
        (puthash key (cons item (gethash key table)) table)))
    (mapcar
      (lambda (key)
        (cons
          key
          (let ((group-items (nreverse (gethash key table))))
            (if item-lessp
              (sort group-items item-lessp)
              group-items))))
      (sort keys group-lessp))))

(defun rust-dive-magit--group-items-by-kind (items)
  "Group ITEMS by entity kind in display order."
  (rust-dive-magit--group-items
    items
    (lambda (item) (plist-get item :kind))
    #'rust-dive-magit--kind-lessp))

(defun rust-dive-magit--group-items-by-file (items)
  "Group ITEMS by relative path."
  (rust-dive-magit--group-items items
    (lambda (item)
      (plist-get (plist-get item :entity) :snapshot_path))
    #'string<
    #'rust-dive-magit--item-lessp))

(defun rust-dive-magit--item-lessp (lhs rhs)
  "Return non-nil when LHS should sort before RHS."
  (let
    (
      (lhs-rank
        (rust-dive-magit--status-rank (plist-get lhs :status)))
      (rhs-rank
        (rust-dive-magit--status-rank (plist-get rhs :status))))
    (if (/= lhs-rank rhs-rank)
      (< lhs-rank rhs-rank)
      (string< (plist-get lhs :summary) (plist-get rhs :summary)))))

(defun rust-dive-magit--kind-lessp (lhs rhs)
  "Return non-nil when kind LHS should sort before RHS."
  (let
    (
      (lhs-rank (rust-dive-magit--kind-rank lhs))
      (rhs-rank (rust-dive-magit--kind-rank rhs)))
    (if (= lhs-rank rhs-rank)
      (string< lhs rhs)
      (< lhs-rank rhs-rank))))

(defun rust-dive-magit--kind-rank (kind)
  "Return the display rank for KIND."
  (or
    (cl-position
      kind
      rust-dive-magit--entity-kind-order
      :test #'equal)
    (length rust-dive-magit--entity-kind-order)))

(defun rust-dive-magit--kind-label (kind)
  "Return the user-facing heading label for KIND."
  (or (plist-get (rust-dive-magit--kind-metadata kind) :group_label)
    kind))

(defun rust-dive-magit--kind-metadata (kind)
  "Return the metadata plist for KIND."
  (plist-get
    rust-dive-magit--entity-kinds
    (intern (concat ":" kind))))

(defun rust-dive-magit--status-rank (status)
  "Return the display rank for STATUS."
  (pcase status
    ('modified 0)
    ((or 'moved-from 'moved-to) 1)
    ('added 2)
    ('deleted 3)
    (_ 4)))

(defun rust-dive-magit--status-face (status)
  "Return the Magit face for STATUS."
  (pcase status
    ('added 'magit-diff-added)
    ('deleted 'magit-diff-removed)
    (_ nil)))

(defun rust-dive-magit--insert-items (items)
  "Insert ITEMS using the current grouping mode."
  (pcase rust-dive-magit--grouping
    ('file (rust-dive-magit--insert-file-groups items))
    (_ (rust-dive-magit--insert-kind-groups items))))

(defun rust-dive-magit--indent (depth)
  "Return indentation for section DEPTH."
  (make-string (* depth 2) ?\s))

(defun rust-dive-magit--heading-face (depth)
  "Return the heading face for section DEPTH."
  (pcase depth
    (0 'magit-section-heading)
    (1 'rust-dive-magit-level-1-heading)
    (_ 'rust-dive-magit-level-2-heading)))

(defun rust-dive-magit--split-paths (input)
  "Split comma-separated INPUT into normalized path filters."
  (if (string-empty-p input)
    nil
    (seq-filter
      (lambda (item) (not (string-empty-p item)))
      (mapcar #'string-trim (split-string input "," t)))))

(defun rust-dive-magit--current-display-width ()
  "Return the current window body width in character columns."
  (max 20
    (if-let ((window (selected-window)))
      (window-body-width window)
      (frame-width))))

(defun rust-dive-magit--run-command (repo-default-directory args)
  "Run rust_dive with ARGS from REPO-DEFAULT-DIRECTORY and parse JSON output."
  (with-temp-buffer
    (let
      (
        (default-directory repo-default-directory)
        (stderr-file (make-temp-file "rust-dive-stderr-")))
      (unwind-protect
        (let
          (
            (status
              (apply #'process-file
                rust-dive-magit-executable
                nil
                (list (current-buffer) stderr-file)
                nil
                args)))
          (unless (eq status 0)
            (error
              "Rust Dive failed: %s"
              (string-trim
                (with-temp-buffer
                  (insert-file-contents stderr-file)
                  (buffer-string)))))
          (goto-char (point-min))
          (json-parse-buffer :object-type 'plist :array-type 'list))
        (delete-file stderr-file)))))

(defun rust-dive-magit--repo-root ()
  "Return the repository root for the current buffer."
  (or
    (and (fboundp 'magit-toplevel)
      (ignore-errors
        (magit-toplevel)))
    (locate-dominating-file default-directory ".git")
    (user-error "Not inside a Git repository")))

(defun rust-dive-magit--dwim-endpoints (spec repo-root)
  "Return Rust Dive LHS and RHS endpoints from Magit SPEC in REPO-ROOT."
  (pcase spec
    ((or 'unstaged 'staged 'unmerged 'undefined)
      (list "HEAD" repo-root))
    (`(commit . ,rev) (list (format "%s^" rev) rev))
    (`(stash . ,rev) (list (format "%s^" rev) rev))
    ((pred stringp)
      (or (rust-dive-magit--range-endpoints spec)
        (list spec repo-root)))
    (_ (list "HEAD" repo-root))))

(defun rust-dive-magit--range-endpoints (range)
  "Return LHS and RHS endpoints for Git diff RANGE, or nil."
  (cond
    ((string-match "\\`\\(.+\\)\\.\\.\\.\\(.+\\)\\'" range)
      (list (match-string 1 range) (match-string 2 range)))
    ((string-match "\\`\\(.+\\)\\.\\.\\(.+\\)\\'" range)
      (list (match-string 1 range) (match-string 2 range)))))

(defun rust-dive-magit--entity-section-at-point ()
  "Return the nearest entity section at point, if any."
  (let ((section (magit-current-section)))
    (while
      (and section (not (eq (oref section type) 'rust-dive-entity)))
      (setq section (oref section parent)))
    section))

(defun rust-dive-magit-register-magit-diff-suffix ()
  "Register Rust Dive in the `magit-diff' transient."
  (when
    (and (featurep 'magit-diff)
      (not
        (ignore-errors
          (transient-get-suffix 'magit-diff "D"))))
    (transient-append-suffix
      'magit-diff
      "d"
      rust-dive-magit--magit-diff-suffix)))

(defun rust-dive-magit-unregister-magit-diff-suffix ()
  "Remove Rust Dive from the `magit-diff' transient."
  (when
    (and (featurep 'magit-diff)
      (ignore-errors
        (transient-get-suffix 'magit-diff "D")))
    (transient-remove-suffix 'magit-diff "D")))

(defun rust-dive-magit--maybe-register-magit-diff-suffix
  (&optional file)
  "Register Rust Dive bindings when `magit-diff' becomes available.
When FILE is non-nil, it is the path passed by `after-load-functions'."
  (when
    (and rust-dive-magit-bindings-mode
      (or (null file) (string= (file-name-base file) "magit-diff")))
    (remove-hook
      'after-load-functions
      #'rust-dive-magit--maybe-register-magit-diff-suffix)
    (rust-dive-magit-register-magit-diff-suffix)))

;;;###autoload
(define-minor-mode rust-dive-magit-bindings-mode
  "Toggle Rust Dive bindings in Magit transients."
  :global t
  :group 'rust-dive-magit
  :require
  'rust-dive-magit
  (if rust-dive-magit-bindings-mode
    (if (featurep 'magit-diff)
      (rust-dive-magit--maybe-register-magit-diff-suffix)
      (add-hook
        'after-load-functions
        #'rust-dive-magit--maybe-register-magit-diff-suffix))
    (remove-hook
      'after-load-functions
      #'rust-dive-magit--maybe-register-magit-diff-suffix)
    (rust-dive-magit-unregister-magit-diff-suffix)))

(provide 'rust-dive-magit)

;;; rust-dive-magit.el ends here
