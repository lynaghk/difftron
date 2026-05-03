;;; difftron-magit.el --- View difftron output in Magit -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit "4.0.0"))
;; Keywords: tools, vc
;; URL: https://github.com/openai/2026-04-21-diff

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Dedicated Emacs integration for the difftron CLI.  The main entrypoint is
;; `difftron-magit-diff', which shells out to `difftron diff --format json'
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

(defgroup difftron-magit nil
  "Emacs integration for the difftron CLI."
  :group 'tools)

(defface difftron-magit-level-1-heading
  '((t :inherit magit-diff-file-heading))
  "Face for first nested heading level in difftron buffers."
  :group 'difftron-magit)

(defface difftron-magit-level-2-heading
  '((t :inherit magit-diff-file-heading-selection))
  "Face for second nested heading level in difftron buffers."
  :group 'difftron-magit)

(defcustom difftron-magit-executable "difftron"
  "Path to the difftron executable."
  :type 'file
  :group 'difftron-magit)

(defcustom difftron-magit-buffer-name "*difftron*"
  "Name of the difftron results buffer."
  :type 'string
  :group 'difftron-magit)

(defcustom difftron-magit-default-grouping 'file
  "Default top-level grouping for difftron buffers."
  :type
  '
  (choice
   (const :tag "Entity then file" kind)
   (const :tag "File then entity" file))
  :group 'difftron-magit)

(defconst difftron-magit--magit-diff-suffix
  '("D" "Difftron" difftron-magit-diff-dwim))

(defvar difftron-magit-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "g") #'difftron-magit-refresh)
    (define-key map (kbd "f") #'difftron-magit-cycle-grouping)
    (define-key map (kbd "h") #'difftron-magit-dispatch)
    (define-key map (kbd "?") #'difftron-magit-dispatch)
    (define-key map (kbd "l") #'difftron-magit-select-left)
    (define-key
     map
     (kbd "m")
     #'difftron-magit-toggle-commit-messages)
    (define-key map (kbd "r") #'difftron-magit-select-right)
    (define-key map (kbd "N") #'difftron-magit-next-commit)
    (define-key map (kbd "P") #'difftron-magit-previous-commit)
    (define-key
     map
     (kbd "TAB")
     #'difftron-magit-toggle-section-or-message)
    (define-key map (kbd "RET") #'difftron-magit-visit-thing)
    map)
  "Keymap for `difftron-magit-mode'.")

(defvar-local difftron-magit--command-args nil)
(defvar-local difftron-magit--default-directory nil)
(defvar-local difftron-magit--payload nil)
(defvar-local difftron-magit--entity-kind-order nil)
(defvar-local difftron-magit--entity-kinds nil)
(defvar-local difftron-magit--grouping nil
  "Current grouping mode for the difftron buffer.")
(defvar-local difftron-magit--commit-message-regions nil
  "Alist of expanded commit message regions by side.")

(define-derived-mode
  difftron-magit-mode
  magit-section-mode
  "difftron"
  "Major mode for difftron results."
  (setq-local truncate-lines t))

(transient-define-prefix
  difftron-magit-dispatch
  ()
  "Show commands for `difftron-magit-mode'."
  [
   ["difftron"
    ("g" "Refresh" difftron-magit-refresh)
    ("f" "Cycle grouping" difftron-magit-cycle-grouping)
    ("l" "Select left" difftron-magit-select-left)
    ("m" "Toggle messages" difftron-magit-toggle-commit-messages)
    ("r" "Select right" difftron-magit-select-right)
    ("q" "Quit buffer" quit-window)
    ("TAB"
     "Toggle section/message"
     difftron-magit-toggle-section-or-message)
    ("RET" "Visit thing" difftron-magit-visit-thing)]
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
    ("N" "Next commit" difftron-magit-next-commit)
    ("P" "Previous commit" difftron-magit-previous-commit)
    ("n" "Next section" magit-section-forward)
    ("p" "Previous section" magit-section-backward)
    ("M-n" "Next sibling" magit-section-forward-sibling)
    ("M-p" "Previous sibling" magit-section-backward-sibling)]])

(defun difftron-magit-diff-dwim ()
  "Run `difftron diff' using the current Magit diff context."
  (interactive)
  (require 'magit-diff)
  (pcase-let*
      (
       (default-directory (difftron-magit--repo-root))
       (`(,_args ,paths) (magit-diff-arguments))
       (`(,lhs ,rhs)
        (difftron-magit--dwim-endpoints
         (ignore-errors
           (magit-diff--dwim))
         default-directory)))
    (difftron-magit-diff lhs rhs paths)))

(defun difftron-magit-diff-at-point ()
  "Run difftron for the current Magit diff and entity at point."
  (interactive)
  (require 'magit-diff)
  (pcase-let*
      (
       (default-directory (difftron-magit--repo-root))
       (path (difftron-magit--magit-diff-path-at-point))
       (line (difftron-magit--magit-diff-line-at-point))
       (`(,_args ,paths) (magit-diff-arguments))
       (`(,lhs ,rhs)
        (difftron-magit--dwim-endpoints
         (ignore-errors
           (magit-diff--dwim))
         default-directory))
       (selected-paths (or (and path (list path)) paths))
       (args
        (append
         (list "diff" lhs rhs "--format" "json")
         (cl-mapcan
          (lambda (selected-path) (list "--path" selected-path))
          selected-paths)))
       (payload (difftron-magit--run-command default-directory args)))
    (difftron-magit--display-buffer default-directory args payload)
    (when path
      (with-current-buffer difftron-magit-buffer-name
        (difftron-magit--goto-entity-for-source path line)))))

(defun difftron-magit-diff (lhs rhs &optional paths)
  "Run `difftron diff' for LHS, RHS, and optional PATHS.
When called interactively, default to comparing `HEAD' against the current
working tree rooted at the current repository."
  (interactive
   (let*
       (
        (repo-root (difftron-magit--repo-root))
        (default-lhs "HEAD")
        (default-rhs repo-root)
        (lhs (read-string "Left snapshot/rev: " default-lhs))
        (rhs (read-string "Right snapshot/rev: " default-rhs))
        (path-input
         (read-string "Filter paths (comma-separated, optional): ")))
     (list lhs rhs (difftron-magit--split-paths path-input))))
  (let*
      (
       (default-directory (difftron-magit--repo-root))
       (args
        (append
         (list "diff" lhs rhs "--format" "json")
         (cl-mapcan (lambda (path) (list "--path" path)) paths)))
       (payload (difftron-magit--run-command default-directory args)))
    (difftron-magit--display-buffer default-directory args payload)))

(defun difftron-magit-refresh ()
  "Re-run the last difftron command in the current buffer."
  (interactive)
  (unless
      (and difftron-magit--command-args
           difftron-magit--default-directory)
    (user-error
     "No difftron command is associated with this buffer"))
  (magit-refresh-buffer))

(defun difftron-magit-cycle-grouping ()
  "Cycle the difftron grouping mode for the current buffer."
  (interactive)
  (unless difftron-magit--payload
    (user-error
     "No difftron payload is associated with this buffer"))
  (setq difftron-magit-default-grouping
        (pcase difftron-magit--grouping
          ('kind 'file)
          (_ 'kind)))
  (setq difftron-magit--grouping difftron-magit-default-grouping)
  (difftron-magit--display-buffer
   difftron-magit--default-directory
   difftron-magit--command-args
   difftron-magit--payload)
  (with-current-buffer difftron-magit-buffer-name
    (magit-section-show-level-3)))

(defun difftron-magit-select-left ()
  "Select a new left-hand snapshot and refresh the diff."
  (interactive)
  (difftron-magit--select-side 'lhs))

(defun difftron-magit-select-right ()
  "Select a new right-hand snapshot and refresh the diff."
  (interactive)
  (difftron-magit--select-side 'rhs))

(defun difftron-magit--select-side (side)
  "Select a new snapshot for SIDE and refresh the current diff."
  (unless difftron-magit--payload
    (user-error
     "No difftron payload is associated with this buffer"))
  (unless difftron-magit--default-directory
    (user-error
     "No difftron command is associated with this buffer"))
  (let*
      (
       (lhs-snapshot (plist-get difftron-magit--payload :lhs))
       (rhs-snapshot (plist-get difftron-magit--payload :rhs))
       (new-arg
        (difftron-magit--read-snapshot-like
         side
         (pcase side
           ('lhs lhs-snapshot)
           (_ rhs-snapshot))))
       (lhs
        (if (eq side 'lhs)
            new-arg
          (difftron-magit--snapshot-arg lhs-snapshot)))
       (rhs
        (if (eq side 'rhs)
            new-arg
          (difftron-magit--snapshot-arg rhs-snapshot))))
    (difftron-magit--run-and-display-diff lhs rhs)))

(defun difftron-magit--read-snapshot-like (side snapshot)
  "Read a replacement for SNAPSHOT on SIDE."
  (let
      (
       (label (difftron-magit--side-label side))
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

(defun difftron-magit--snapshot-arg (snapshot)
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

(defun difftron-magit--side-label (side)
  "Return a prompt label for SIDE."
  (pcase side
    ('lhs "Left")
    (_ "Right")))

(defun difftron-magit-toggle-section-or-message ()
  "Toggle the commit message at point or the current Magit section."
  (interactive)
  (if-let ((side (difftron-magit--snapshot-side-at-point)))
      (difftron-magit--toggle-commit-message side)
    (magit-section-toggle (magit-current-section))))

(defun difftron-magit-toggle-commit-messages ()
  "Toggle commit messages for both Git revision snapshots."
  (interactive)
  (let ((sides (difftron-magit--commit-message-sides)))
    (unless sides
      (user-error "No Git revision snapshots in this buffer"))
    (if
        (seq-some
         (lambda (side)
           (not (difftron-magit--commit-message-expanded-p side)))
         sides)
        (dolist (side sides)
          (unless (difftron-magit--commit-message-expanded-p side)
            (difftron-magit--show-commit-message side)))
      (dolist (side sides)
        (difftron-magit--hide-commit-message side)))))

(defun difftron-magit--snapshot-side-at-point ()
  "Return the snapshot side at point, if point is on one."
  (or (get-text-property (point) 'difftron-magit-snapshot-side)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) 'difftron-magit-snapshot-side))
      (get-text-property
       (line-beginning-position)
       'difftron-magit-snapshot-side)))

(defun difftron-magit--commit-message-sides ()
  "Return sides that currently show Git revisions."
  (seq-filter
   (lambda (side)
     (equal
      (plist-get (difftron-magit--snapshot-for-side side) :kind)
      "git_revision"))
   '(lhs rhs)))

(defun difftron-magit--snapshot-for-side (side)
  "Return the payload snapshot for SIDE."
  (or
   (and difftron-magit--payload
        (plist-get
         difftron-magit--payload
         (pcase side
           ('lhs :lhs)
           (_ :rhs))))
   (when-let
       (
        (pos
         (text-property-any
          (point-min)
          (point-max)
          'difftron-magit-snapshot-side
          side)))
     (get-text-property pos 'difftron-magit-snapshot))))

(defun difftron-magit--toggle-commit-message (side)
  "Toggle the commit message for SIDE."
  (if (difftron-magit--commit-message-expanded-p side)
      (difftron-magit--hide-commit-message side)
    (difftron-magit--show-commit-message side)))

(defun difftron-magit--commit-message-expanded-p (side)
  "Return non-nil if SIDE's commit message is expanded."
  (assq side difftron-magit--commit-message-regions))

(defun difftron-magit--show-commit-message (side)
  "Insert SIDE's commit message below its snapshot line."
  (let*
      (
       (snapshot (difftron-magit--snapshot-for-side side))
       (message (difftron-magit--commit-message snapshot))
       (insert-at (difftron-magit--snapshot-line-end side)))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char insert-at)
        (forward-line 1)
        (let ((start (point)))
          (insert (difftron-magit--format-commit-message message))
          (add-text-properties
           start (point)
           (list
            'difftron-magit-snapshot-side
            side
            'font-lock-face
            'magit-section-secondary-heading))
          (push
           (cons
            side
            (cons (copy-marker start) (copy-marker (point))))
           difftron-magit--commit-message-regions))))))

(defun difftron-magit--hide-commit-message (side)
  "Remove SIDE's expanded commit message."
  (when-let
      ((region (assq side difftron-magit--commit-message-regions)))
    (let
        (
         (start (cadr region))
         (end (cddr region))
         (inhibit-read-only t))
      (delete-region start end)
      (set-marker start nil)
      (set-marker end nil)
      (setq difftron-magit--commit-message-regions
            (assq-delete-all
             side
             difftron-magit--commit-message-regions)))))

(defun difftron-magit--snapshot-line-end (side)
  "Return the line end position for SIDE's snapshot line."
  (or
   (when-let
       (
        (pos
         (text-property-any
          (point-min)
          (point-max)
          'difftron-magit-snapshot-side
          side)))
     (save-excursion
       (goto-char pos)
       (line-end-position)))
   (user-error "No snapshot line for %s" side)))

(defun difftron-magit--commit-message (snapshot)
  "Return the full commit message for SNAPSHOT."
  (let
      (
       (rev
        (or (plist-get snapshot :rev)
            (user-error "Git revision snapshot has no revision")))
       (default-directory
        (or (plist-get snapshot :root) default-directory)))
    (or (magit-git-string "log" "-1" "--format=%B" rev) "")))

(defun difftron-magit--format-commit-message (message)
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

(defun difftron-magit-next-commit ()
  "Show the next commit on HEAD's first-parent history."
  (interactive)
  (difftron-magit--show-commit-diff
   (difftron-magit--next-commit
    (difftron-magit--current-rhs-revision))))

(defun difftron-magit-previous-commit ()
  "Show the first-parent commit before the current RHS commit."
  (interactive)
  (difftron-magit--show-commit-diff
   (or
    (difftron-magit--commit-parent
     (difftron-magit--current-rhs-revision))
    (user-error "No previous commit"))))

(defun difftron-magit--current-rhs-revision ()
  "Return the Git revision for the current diff RHS."
  (let ((rhs (plist-get difftron-magit--payload :rhs)))
    (unless (equal (plist-get rhs :kind) "git_revision")
      (user-error
       "Difftron buffer is not showing a Git revision diff"))
    (or (plist-get rhs :rev)
        (user-error "Difftron diff RHS has no Git revision"))))

(defun difftron-magit--next-commit (rev)
  "Return the next commit after REV on HEAD's first-parent history."
  (let
      (
       (default-directory
        (or difftron-magit--default-directory default-directory)))
    (or
     (car
      (magit-git-lines
       "rev-list"
       "--first-parent"
       "--reverse"
       (format "%s..HEAD" rev)))
     (user-error "No next commit on HEAD's first-parent history"))))

(defun difftron-magit--commit-parent (rev)
  "Return the first parent of REV, or nil for a root commit."
  (let*
      (
       (default-directory
        (or difftron-magit--default-directory default-directory))
       (line (car (magit-git-lines "rev-list" "-1" "--parents" rev)))
       (parts (and line (split-string line))))
    (cadr parts)))

(defun difftron-magit--show-commit-diff (rev)
  "Render the difftron diff for commit REV."
  (let
      (
       (parent
        (or (difftron-magit--commit-parent rev)
            (user-error "Commit %s has no parent" rev))))
    (difftron-magit--run-and-display-diff parent rev)))

(defun difftron-magit--run-and-display-diff (lhs rhs)
  "Run and display a difftron diff from LHS to RHS."
  (unless difftron-magit--default-directory
    (user-error
     "No difftron command is associated with this buffer"))
  (let*
      (
       (args
        (append
         (list "diff" lhs rhs "--format" "json")
         (difftron-magit--command-path-args
          difftron-magit--command-args)))
       (payload
        (difftron-magit--run-command
         difftron-magit--default-directory
         args)))
    (difftron-magit--display-buffer
     difftron-magit--default-directory
     args
     payload)))

(defun difftron-magit--command-path-args (args)
  "Return the --path arguments from difftron command ARGS."
  (let (paths)
    (while args
      (let ((arg (pop args)))
        (when (and (equal arg "--path") args)
          (push "--path" paths)
          (push (pop args) paths))))
    (nreverse paths)))

(defun difftron-magit-visit-thing ()
  "Visit the entity at point or activate a button."
  (interactive)
  (if-let*
      (
       (section (difftron-magit--entity-section-at-point))
       (entity (plist-get (oref section value) :entity)))
      (difftron-magit--visit-entity entity)
    (if-let ((button (difftron-magit--button-at-point)))
        (push-button (button-start button))
      (magit-section-toggle (magit-current-section)))))

(defun difftron-magit--button-at-point ()
  "Return the button at point, accepting point just after button text."
  (or (button-at (point))
      (and (> (point) (point-min)) (button-at (1- (point))))))

(defun difftron-magit--display-buffer
    (repo-default-directory args payload)
  "Render PAYLOAD in the dedicated buffer.
REPO-DEFAULT-DIRECTORY and ARGS are stored to support refresh."
  (let ((buffer (get-buffer-create difftron-magit-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (difftron-magit-mode)
        (setq difftron-magit--grouping
              difftron-magit-default-grouping)
        (setq difftron-magit--default-directory
              repo-default-directory)
        (setq difftron-magit--command-args args)
        (setq difftron-magit--payload payload)
        (erase-buffer)
        (difftron-magit--insert-payload payload)
        (magit-section-show-level-3)
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(defun difftron-magit-refresh-buffer ()
  "Refresh the current difftron buffer using Magit's refresh machinery."
  (setq difftron-magit--payload
        (difftron-magit--run-command
         difftron-magit--default-directory
         difftron-magit--command-args))
  (difftron-magit--insert-payload difftron-magit--payload))

(defun difftron-magit--insert-payload (payload)
  "Insert PAYLOAD into the current buffer."
  (setq difftron-magit--commit-message-regions nil)
  (setq difftron-magit--entity-kind-order
        (plist-get payload :entity_kind_order))
  (setq difftron-magit--entity-kinds
        (plist-get payload :entity_kinds))
  (magit-insert-section
      (difftron-root)
    (pcase (plist-get payload :command)
      ("diff" (difftron-magit--insert-diff payload))
      ("list" (difftron-magit--insert-list payload))
      (_
       (insert
        (format "Unsupported difftron command: %S" payload))))))

(defun difftron-magit--insert-list (payload)
  "Insert a list-mode PAYLOAD into the current buffer."
  (difftron-magit--insert-title
   (format "difftron list %s"
           (plist-get (plist-get payload :snapshot) :label)))
  (difftron-magit--insert-items
   (mapcar
    #'difftron-magit--list-entity->item
    (plist-get payload :entities))))

(defun difftron-magit--insert-diff (payload)
  "Insert a diff PAYLOAD into the current buffer."
  (let
      (
       (lhs (plist-get payload :lhs))
       (rhs (plist-get payload :rhs)))
    (difftron-magit--insert-snapshot-line "lhs" lhs)
    (difftron-magit--insert-snapshot-line "rhs" rhs)
    (insert "\n")
    (difftron-magit--insert-items
     (difftron-magit--diff-items payload))))

(defun difftron-magit--insert-snapshot-line (name snapshot)
  "Insert one clickable diff endpoint NAME for SNAPSHOT."
  (let ((start (point)))
    (insert
     (propertize (format "%s: " name)
                 'font-lock-face
                 'magit-section-heading))
    (insert-text-button
     (difftron-magit--display-label (plist-get snapshot :label))
     'action
     (lambda (_button) (difftron-magit--visit-snapshot snapshot))
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
        'difftron-magit-snapshot-side
        (intern name)
        'difftron-magit-snapshot
        snapshot
        'mouse-face
        'highlight
        'help-echo
        "TAB toggles commit message, RET visits snapshot")))))

(defun difftron-magit--visit-snapshot (snapshot)
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

(defun difftron-magit--display-label (label)
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

(defun difftron-magit--insert-title (title)
  "Insert TITLE at the top of the current buffer."
  (insert (propertize title 'font-lock-face 'magit-section-heading))
  (insert "\n\n"))

(defun difftron-magit--insert-kind-groups (items)
  "Insert ITEMS grouped by entity kind."
  (let ((groups (difftron-magit--group-items-by-kind items)))
    (if groups
        (dolist (group groups)
          (difftron-magit--insert-kind-file-group
           (car group)
           (cdr group)
           0))
      (insert "No entities\n"))))

(defun difftron-magit--insert-file-groups (items)
  "Insert ITEMS grouped by file."
  (let ((groups (difftron-magit--group-items-by-file items)))
    (if groups
        (dolist (group groups)
          (difftron-magit--insert-file-kind-group
           (car group)
           (cdr group)
           0))
      (insert "No entities\n"))))

(defun difftron-magit--insert-kind-file-group (kind items depth)
  "Insert a kind heading for KIND and file groups for ITEMS at DEPTH."
  (magit-insert-section
      (difftron-kind kind t)
    (magit-insert-heading
      (difftron-magit--kind-heading kind items depth))
    (dolist (group (difftron-magit--group-items-by-file items))
      (difftron-magit--insert-file-entity-group
       (car group)
       (cdr group)
       (1+ depth)))
    (insert "\n")))

(defun difftron-magit--insert-file-kind-group (file items depth)
  "Insert a file heading for FILE and kind groups for ITEMS at DEPTH."
  (magit-insert-section
      (difftron-file file t)
    (magit-insert-heading
      (difftron-magit--file-heading file items depth))
    (dolist (group (difftron-magit--group-items-by-kind items))
      (difftron-magit--insert-kind-entity-group
       (car group)
       (cdr group)
       (1+ depth)))
    (insert "\n")))

(defun difftron-magit--insert-kind-entity-group (kind items depth)
  "Insert a kind heading for KIND and entity ITEMS at DEPTH."
  (magit-insert-section
      (difftron-kind kind t)
    (magit-insert-heading
      (difftron-magit--kind-heading kind items depth))
    (dolist (item items)
      (difftron-magit--insert-item item (1+ depth)))
    (insert "\n")))

(defun difftron-magit--insert-file-entity-group (file items depth)
  "Insert a file heading for FILE and entity ITEMS at DEPTH."
  (magit-insert-section
      (difftron-file file t)
    (magit-insert-heading
      (difftron-magit--file-heading file items depth))
    (dolist (item items)
      (difftron-magit--insert-item item (1+ depth)))
    (insert "\n")))

(defun difftron-magit--kind-heading (kind items depth)
  "Return the heading text for KIND containing ITEMS at DEPTH."
  (propertize
   (format "%s%s (%d)"
           (difftron-magit--indent depth)
           (difftron-magit--kind-label kind)
           (length items))
   'font-lock-face (difftron-magit--heading-face depth)))

(defun difftron-magit--file-heading (file items depth)
  "Return the heading text for FILE containing ITEMS at DEPTH."
  (propertize
   (format "%s%s (%d)"
           (difftron-magit--indent depth)
           file
           (length items))
   'font-lock-face (difftron-magit--heading-face depth)))

(defun difftron-magit--insert-item (item depth)
  "Insert ITEM as a foldable heading at DEPTH."
  (let ((entity (plist-get item :entity)))
    (magit-insert-section
        (difftron-entity item t)
      (magit-insert-heading
        (propertize
         (format "%s%s"
                 (difftron-magit--indent depth)
                 (plist-get item :summary))
         'font-lock-face (difftron-magit--heading-face depth)))
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
         (difftron-magit--insert-structured-diff
          (plist-get item :diff)))
        (_
         (when-let ((source (plist-get entity :source_text)))
           (difftron-magit--insert-diff-text
            source
            (difftron-magit--status-face (plist-get item :status)))
           (unless (string-suffix-p "\n" source)
             (insert "\n")))))
      (unless (eq (char-before) ?\n)
        (insert "\n"))
      (insert "\n"))))

(defun difftron-magit--insert-structured-diff (diff)
  "Insert structured DIFF rows using Emacs layout and faces."
  (let ((rows (plist-get diff :rows)))
    (if rows
        (let ((column-width (difftron-magit--modified-column-width)))
          (dolist (row rows)
            (difftron-magit--insert-structured-diff-row
             row
             column-width)))
      (insert "No diff output.\n"))))

(defun difftron-magit--insert-structured-diff-row (row column-width)
  "Insert one structured diff ROW using COLUMN-WIDTH per side."
  (difftron-magit--insert-structured-side
   (plist-get row :left)
   'left
   column-width)
  (insert " | ")
  (difftron-magit--insert-structured-side
   (plist-get row :right)
   'right
   column-width)
  (insert "\n"))

(defun difftron-magit--insert-structured-side
    (side side-name column-width)
  "Insert SIDE for SIDE-NAME truncated to COLUMN-WIDTH."
  (if side
      (let
          (
           (start (point))
           (face (difftron-magit--side-face side-name)))
        (difftron-magit--insert-structured-segments
         (plist-get side :segments)
         side-name
         face
         column-width)
        (when (eq side-name 'left)
          (difftron-magit--insert-diff-text
           (make-string (max 0 (- column-width (- (point) start))) ?\s)
           face)))
    (when (eq side-name 'left)
      (insert (make-string column-width ?\s)))))

(defun difftron-magit--insert-structured-segments
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
              (difftron-magit--segment-refine-face
               side-name
               (plist-get segment :kind)))
             (start (point)))
          (unless (string-empty-p text)
            (difftron-magit--insert-diff-text text face)
            (when refine-face
              (difftron-magit--add-refine-overlay
               start
               (point)
               refine-face))
            (setq remaining (- remaining (string-width text)))))))))

(defun difftron-magit--insert-diff-text (text face)
  "Insert TEXT with optional diff FACE."
  (if face
      (insert (propertize text 'font-lock-face face))
    (insert text)))

(defun difftron-magit--side-face (side-name)
  "Return the base diff face for SIDE-NAME."
  (ignore side-name)
  'magit-diff-context)

(defun difftron-magit--segment-refine-face (side-name kind)
  "Return the refinement face for segment KIND on SIDE-NAME."
  (pcase kind
    ("novel"
     (pcase side-name
       ('left 'diff-refine-removed)
       (_ 'diff-refine-added)))
    (_ nil)))

(defun difftron-magit--add-refine-overlay (start end face)
  "Add a Magit-style fine diff overlay from START to END using FACE."
  (let ((overlay (make-overlay start end nil t)))
    (overlay-put overlay 'diff-mode 'fine)
    (overlay-put overlay 'evaporate t)
    (overlay-put overlay 'face face)
    overlay))

(defun difftron-magit--modified-column-width ()
  "Return the per-side width for structured modified diffs."
  (max 24 (/ (- (difftron-magit--current-display-width) 3) 2)))

(defun difftron-magit--visit-entity (entity)
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

(defun difftron-magit--diff-items (payload)
  "Flatten diff PAYLOAD into display items."
  (append
   (mapcar
    (lambda (entity)
      (difftron-magit--item-from-entity 'added entity))
    (plist-get payload :added))
   (mapcar
    (lambda (entity)
      (difftron-magit--item-from-entity 'deleted entity))
    (plist-get payload :deleted))
   (mapcan
    #'difftron-magit--items-from-move
    (plist-get payload :moved))
   (mapcan
    #'difftron-magit--items-from-moved-modified
    (plist-get payload :moved_modified))
   (mapcar
    #'difftron-magit--item-from-change
    (plist-get payload :modified))))

(defun difftron-magit--item-from-change (change)
  "Build a display item from modified CHANGE."
  (let ((rhs (plist-get change :rhs)))
    (list
     :kind (plist-get rhs :kind)
     :status 'modified
     :entity rhs
     :summary (format "M %s" (plist-get rhs :name))
     :diff (plist-get change :diff))))

(defun difftron-magit--items-from-move (change)
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

(defun difftron-magit--items-from-moved-modified (change)
  "Build source-side and destination-side items from moved-modified CHANGE."
  (let
      (
       (lhs (plist-get change :lhs))
       (rhs (plist-get change :rhs)))
    (list
     (list
      :kind (plist-get lhs :kind)
      :status 'moved-modified-from
      :entity lhs
      :summary
      (format "Moved from here to %s, with changes"
              (plist-get rhs :name)))
     (list
      :kind (plist-get rhs :kind)
      :status 'moved-modified-to
      :entity rhs
      :summary
      (format "Moved here from %s, with changes"
              (plist-get lhs :name))))))

(defun difftron-magit--item-from-entity (status entity)
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

(defun difftron-magit--list-entity->item (entity)
  "Build a display item from a list-mode ENTITY."
  (list
   :kind (plist-get entity :kind)
   :status 'present
   :entity entity
   :summary (plist-get entity :name)))

(defun difftron-magit--group-items
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

(defun difftron-magit--group-items-by-kind (items)
  "Group ITEMS by entity kind in display order."
  (difftron-magit--group-items
   items
   (lambda (item) (plist-get item :kind))
   #'difftron-magit--kind-lessp))

(defun difftron-magit--group-items-by-file (items)
  "Group ITEMS by relative path."
  (difftron-magit--group-items items
                               (lambda (item)
                                 (plist-get (plist-get item :entity) :snapshot_path))
                               #'string<
                               #'difftron-magit--item-lessp))

(defun difftron-magit--item-lessp (lhs rhs)
  "Return non-nil when LHS should sort before RHS."
  (let
      (
       (lhs-rank
        (difftron-magit--status-rank (plist-get lhs :status)))
       (rhs-rank
        (difftron-magit--status-rank (plist-get rhs :status))))
    (if (/= lhs-rank rhs-rank)
        (< lhs-rank rhs-rank)
      (string< (plist-get lhs :summary) (plist-get rhs :summary)))))

(defun difftron-magit--kind-lessp (lhs rhs)
  "Return non-nil when kind LHS should sort before RHS."
  (let
      (
       (lhs-rank (difftron-magit--kind-rank lhs))
       (rhs-rank (difftron-magit--kind-rank rhs)))
    (if (= lhs-rank rhs-rank)
        (string< lhs rhs)
      (< lhs-rank rhs-rank))))

(defun difftron-magit--kind-rank (kind)
  "Return the display rank for KIND."
  (or
   (cl-position
    kind
    difftron-magit--entity-kind-order
    :test #'equal)
   (length difftron-magit--entity-kind-order)))

(defun difftron-magit--kind-label (kind)
  "Return the user-facing heading label for KIND."
  (or (plist-get (difftron-magit--kind-metadata kind) :group_label)
      kind))

(defun difftron-magit--kind-metadata (kind)
  "Return the metadata plist for KIND."
  (plist-get
   difftron-magit--entity-kinds
   (intern (concat ":" kind))))

(defun difftron-magit--status-rank (status)
  "Return the display rank for STATUS."
  (pcase status
    ('modified 0)
    (
     (or 'moved-from
         'moved-to
         'moved-modified-from
         'moved-modified-to)
     1)
    ('added 2)
    ('deleted 3)
    (_ 4)))

(defun difftron-magit--status-face (status)
  "Return the Magit face for STATUS."
  (pcase status
    ('added 'magit-diff-added)
    ('deleted 'magit-diff-removed)
    (_ nil)))

(defun difftron-magit--insert-items (items)
  "Insert ITEMS using the current grouping mode."
  (pcase difftron-magit--grouping
    ('file (difftron-magit--insert-file-groups items))
    (_ (difftron-magit--insert-kind-groups items))))

(defun difftron-magit--indent (depth)
  "Return indentation for section DEPTH."
  (make-string (* depth 2) ?\s))

(defun difftron-magit--heading-face (depth)
  "Return the heading face for section DEPTH."
  (pcase depth
    (0 'magit-section-heading)
    (1 'difftron-magit-level-1-heading)
    (_ 'difftron-magit-level-2-heading)))

(defun difftron-magit--split-paths (input)
  "Split comma-separated INPUT into normalized path filters."
  (if (string-empty-p input)
      nil
    (seq-filter
     (lambda (item) (not (string-empty-p item)))
     (mapcar #'string-trim (split-string input "," t)))))

(defun difftron-magit--current-display-width ()
  "Return the current window body width in character columns."
  (max 20
       (if-let ((window (selected-window)))
           (window-body-width window)
         (frame-width))))

(defun difftron-magit--run-command (repo-default-directory args)
  "Run difftron with ARGS from REPO-DEFAULT-DIRECTORY and parse JSON output."
  (with-temp-buffer
    (let
        (
         (default-directory repo-default-directory)
         (stderr-file (make-temp-file "difftron-stderr-")))
      (unwind-protect
          (let
              (
               (status
                (apply #'process-file
                       difftron-magit-executable
                       nil
                       (list (current-buffer) stderr-file)
                       nil
                       args)))
            (unless (eq status 0)
              (error
               "Difftron failed: %s"
               (string-trim
                (with-temp-buffer
                  (insert-file-contents stderr-file)
                  (buffer-string)))))
            (goto-char (point-min))
            (json-parse-buffer :object-type 'plist :array-type 'list))
        (delete-file stderr-file)))))

(defun difftron-magit--repo-root ()
  "Return the repository root for the current buffer."
  (or
   (and (fboundp 'magit-toplevel)
        (ignore-errors
          (magit-toplevel)))
   (locate-dominating-file default-directory ".git")
   (user-error "Not inside a Git repository")))

(defun difftron-magit--dwim-endpoints (spec repo-root)
  "Return difftron LHS and RHS endpoints from Magit SPEC in REPO-ROOT."
  (pcase spec
    ((or 'unstaged 'staged 'unmerged 'undefined)
     (list "HEAD" repo-root))
    (`(commit . ,rev) (list (format "%s^" rev) rev))
    (`(stash . ,rev) (list (format "%s^" rev) rev))
    ((pred stringp)
     (or (difftron-magit--range-endpoints spec)
         (list spec repo-root)))
    (_ (list "HEAD" repo-root))))

(defun difftron-magit--range-endpoints (range)
  "Return LHS and RHS endpoints for Git diff RANGE, or nil."
  (cond
   ((string-match "\\`\\(.+\\)\\.\\.\\.\\(.+\\)\\'" range)
    (list (match-string 1 range) (match-string 2 range)))
   ((string-match "\\`\\(.+\\)\\.\\.\\(.+\\)\\'" range)
    (list (match-string 1 range) (match-string 2 range)))))

(defun difftron-magit--magit-diff-path-at-point ()
  "Return the relative Magit diff file path at point, if any."
  (when-let ((section (magit-diff--file-section)))
    (or
     (and (difftron-magit--magit-diff-removed-line-p)
          (oref section source))
     (oref section value)
     (oref section source))))

(defun difftron-magit--magit-diff-line-at-point ()
  "Return the Magit diff hunk line at point, if any."
  (when-let ((section (magit-diff--hunk-section)))
    (magit-diff-hunk-line
     section
     (difftron-magit--magit-diff-removed-line-p))))

(defun difftron-magit--magit-diff-removed-line-p ()
  "Return non-nil if point is on a removed Magit diff line."
  (and (fboundp 'magit-diff-on-removed-line-p)
       (magit-diff-on-removed-line-p)))

(defun difftron-magit--goto-entity-for-source (path line)
  "Move point to the difftron entity for PATH and optional LINE."
  (when-let
      (
       (section
        (or (difftron-magit--find-entity-section path line)
            (difftron-magit--find-entity-section path nil))))
    (difftron-magit--show-section-and-ancestors section)
    (goto-char (oref section start))))

(defun difftron-magit--find-entity-section (path line)
  "Return the entity section matching PATH and LINE."
  (seq-find
   (lambda (section)
     (difftron-magit--entity-section-matches-p section path line))
   (difftron-magit--entity-sections magit-root-section)))

(defun difftron-magit--entity-sections (section)
  "Return entity sections below SECTION."
  (append
   (and (eq (oref section type) 'difftron-entity) (list section))
   (mapcan
    #'difftron-magit--entity-sections
    (oref section children))))

(defun difftron-magit--entity-section-matches-p (section path line)
  "Return non-nil when SECTION has PATH and optional LINE."
  (let*
      (
       (entity (plist-get (oref section value) :entity))
       (entity-path (plist-get entity :snapshot_path))
       (start-line (plist-get entity :start_line))
       (end-line (plist-get entity :end_line)))
    (and (equal entity-path path)
         (or (null line)
             (and start-line
                  end-line
                  (<= start-line line)
                  (<= line end-line))))))

(defun difftron-magit--show-section-and-ancestors (section)
  "Show SECTION and its ancestors."
  (let ((current section))
    (while current
      (magit-section-show current)
      (setq current (oref current parent)))))

(defun difftron-magit--entity-section-at-point ()
  "Return the nearest entity section at point, if any."
  (let ((section (magit-current-section)))
    (while
        (and section (not (eq (oref section type) 'difftron-entity)))
      (setq section (oref section parent)))
    section))

(defun difftron-magit-register-magit-diff-suffix ()
  "Register difftron in the `magit-diff' transient."
  (when
      (and (featurep 'magit-diff)
           (not
            (ignore-errors
              (transient-get-suffix 'magit-diff "D"))))
    (transient-append-suffix
      'magit-diff
      "d"
      difftron-magit--magit-diff-suffix)))

(defun difftron-magit-register-magit-diff-bindings ()
  "Register difftron bindings in Magit diff buffers."
  (when (featurep 'magit-diff)
    (difftron-magit-register-magit-diff-suffix)
    (define-key
     magit-diff-mode-map
     (kbd "D")
     #'difftron-magit-diff-at-point)
    (define-key
     magit-diff-section-map
     (kbd "D")
     #'difftron-magit-diff-at-point)))

(defun difftron-magit-unregister-magit-diff-suffix ()
  "Remove difftron from the `magit-diff' transient."
  (when
      (and (featurep 'magit-diff)
           (ignore-errors
             (transient-get-suffix 'magit-diff "D")))
    (transient-remove-suffix 'magit-diff "D")))

(defun difftron-magit-unregister-magit-diff-bindings ()
  "Remove difftron bindings from Magit diff buffers."
  (when (featurep 'magit-diff)
    (difftron-magit-unregister-magit-diff-suffix)
    (define-key magit-diff-mode-map (kbd "D") nil)
    (define-key magit-diff-section-map (kbd "D") nil)))

(defun difftron-magit--maybe-register-magit-diff-suffix
    (&optional file)
  "Register difftron bindings when `magit-diff' becomes available.
When FILE is non-nil, it is the path passed by `after-load-functions'."
  (when
      (and difftron-magit-bindings-mode
           (or (null file) (string= (file-name-base file) "magit-diff")))
    (remove-hook
     'after-load-functions
     #'difftron-magit--maybe-register-magit-diff-suffix)
    (difftron-magit-register-magit-diff-bindings)))

;;;###autoload
(define-minor-mode difftron-magit-bindings-mode
  "Toggle difftron bindings in Magit transients."
  :global t
  :group 'difftron-magit
  :require
  'difftron-magit
  (if difftron-magit-bindings-mode
      (if (featurep 'magit-diff)
          (difftron-magit--maybe-register-magit-diff-suffix)
        (add-hook
         'after-load-functions
         #'difftron-magit--maybe-register-magit-diff-suffix))
    (remove-hook
     'after-load-functions
     #'difftron-magit--maybe-register-magit-diff-suffix)
    (difftron-magit-unregister-magit-diff-bindings)))

(provide 'difftron-magit)

;;; difftron-magit.el ends here
