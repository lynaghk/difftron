;;; difftron.el --- View difftron output in Magit -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit "4.0.0"))
;; Keywords: tools, vc
;; URL: https://github.com/openai/2026-04-21-diff

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Dedicated Emacs integration for the difftron CLI.  The main entrypoint is
;; `difftron-diff', which shells out to `difftron diff --format json'
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

(defvar magit-revision-headers-format)

(defgroup difftron nil
  "Emacs integration for the difftron CLI."
  :group 'tools)

(defface difftron-level-1-heading
  '((t :inherit magit-diff-file-heading))
  "Face for first nested heading level in difftron buffers."
  :group 'difftron)

(defface difftron-level-2-heading
  '((t :inherit magit-diff-file-heading-selection))
  "Face for second nested heading level in difftron buffers."
  :group 'difftron)

(defcustom difftron-executable "difftron"
  "Path to the difftron executable."
  :type 'file
  :group 'difftron)

(defcustom difftron-buffer-name "*difftron*"
  "Name of the difftron results buffer."
  :type 'string
  :group 'difftron)

(defcustom difftron-default-grouping 'file
  "Default top-level grouping for difftron buffers."
  :type
  '
  (choice
   (const :tag "Entity then file" kind)
   (const :tag "File then entity" file))
  :group 'difftron)

(defcustom difftron-use-magit-paths t
  "Whether Difftron commands launched from Magit use Magit's path filters."
  :type 'boolean
  :group 'difftron)

(defcustom difftron-snapshot-commit-limit 100
  "Maximum number of recent commits to offer in snapshot prompts."
  :type 'integer
  :group 'difftron)

(defconst difftron--magit-diff-suffix
  '("D" "Difftron" difftron-diff-dwim))

(defconst difftron--browse-path-choice "Browse path...")

(defvar difftron--snapshot-history nil
  "Minibuffer history for Difftron snapshot prompts.")

(defvar difftron-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "g") #'difftron-refresh)
    (define-key map (kbd "f") #'difftron-cycle-grouping)
    (define-key map (kbd "h") #'difftron-dispatch)
    (define-key map (kbd "?") #'difftron-dispatch)
    (define-key map (kbd "l") #'difftron-select-left)
    (define-key
     map
     (kbd "m")
     #'difftron-toggle-commit-messages)
    (define-key map (kbd "r") #'difftron-select-right)
    (define-key map (kbd "N") #'difftron-next-commit)
    (define-key map (kbd "P") #'difftron-previous-commit)
    (define-key
     map
     (kbd "TAB")
     #'difftron-toggle-section-or-message)
    (define-key map (kbd "RET") #'difftron-visit-thing)
    map)
  "Keymap for `difftron-mode'.")

(defvar-local difftron--command-args nil)
(defvar-local difftron--default-directory nil)
(defvar-local difftron--payload nil)
(defvar-local difftron--entity-kind-order nil)
(defvar-local difftron--entity-kinds nil)
(defvar-local difftron--grouping nil
  "Current grouping mode for the difftron buffer.")

(define-derived-mode
  difftron-mode
  magit-section-mode
  "difftron"
  "Major mode for difftron results."
  (setq-local truncate-lines t))

(transient-define-prefix
  difftron-dispatch
  ()
  "Show commands for `difftron-mode'."
  [
   ["difftron"
    ("g" "Refresh" difftron-refresh)
    ("f" "Cycle grouping" difftron-cycle-grouping)
    ("l" "Select left" difftron-select-left)
    ("m" "Toggle details" difftron-toggle-commit-messages)
    ("r" "Select right" difftron-select-right)
    ("q" "Quit buffer" quit-window)
    ("TAB"
     "Toggle section/details"
     difftron-toggle-section-or-message)
    ("RET" "Visit thing" difftron-visit-thing)]
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
    ("N" "Next commit" difftron-next-commit)
    ("P" "Previous commit" difftron-previous-commit)
    ("n" "Next section" magit-section-forward)
    ("p" "Previous section" magit-section-backward)
    ("M-n" "Next sibling" magit-section-forward-sibling)
    ("M-p" "Previous sibling" magit-section-backward-sibling)]])

(defun difftron-diff-dwim ()
  "Run `difftron diff' using the current Magit diff context."
  (interactive)
  (require 'magit-diff)
  (pcase-let*
      (
       (default-directory (difftron--repo-root))
       (`(,_args ,paths) (magit-diff-arguments))
       (`(,lhs ,rhs)
        (difftron--dwim-endpoints
         (ignore-errors
           (magit-diff--dwim))
         default-directory)))
    (difftron-diff
     lhs
     rhs
     (and difftron-use-magit-paths paths))))

(defun difftron-diff-at-point ()
  "Run difftron for the current Magit diff and entity at point."
  (interactive)
  (require 'magit-diff)
  (pcase-let*
      (
       (default-directory (difftron--repo-root))
       (path (difftron--magit-diff-path-at-point))
       (line (difftron--magit-diff-line-at-point))
       (`(,_args ,paths) (magit-diff-arguments))
       (`(,lhs ,rhs)
        (difftron--dwim-endpoints
         (ignore-errors
           (magit-diff--dwim))
         default-directory))
       (selected-paths
        (and difftron-use-magit-paths
             (or (and path (list path)) paths)))
       (args
        (append
         (list "diff" lhs rhs "--format" "json")
         (cl-mapcan
          (lambda (selected-path) (list "--path" selected-path))
          selected-paths)))
       (payload (difftron--run-command default-directory args)))
    (difftron--display-buffer default-directory args payload)
    (when path
      (with-current-buffer difftron-buffer-name
        (difftron--goto-entity-for-source path line)))))

(defun difftron-diff (lhs rhs &optional paths)
  "Run `difftron diff' for LHS, RHS, and optional PATHS.
When called interactively, default to comparing `HEAD' against the current
working tree rooted at the current repository."
  (interactive
   (let*
       (
        (repo-root (difftron--repo-root))
        (default-lhs "HEAD")
        (default-rhs repo-root)
        (lhs
         (difftron--read-snapshot-arg
          'lhs
          repo-root
          default-lhs))
        (rhs
         (difftron--read-snapshot-arg
          'rhs
          repo-root
          default-rhs)))
     (list lhs rhs)))
  (let*
      (
       (default-directory (difftron--repo-root))
       (args
        (append
         (list "diff" lhs rhs "--format" "json")
         (cl-mapcan (lambda (path) (list "--path" path)) paths)))
       (payload (difftron--run-command default-directory args)))
    (difftron--display-buffer default-directory args payload)))

(defun difftron-refresh ()
  "Re-run the last difftron command in the current buffer."
  (interactive)
  (unless
      (and difftron--command-args
           difftron--default-directory)
    (user-error
     "No difftron command is associated with this buffer"))
  (magit-refresh-buffer))

(defun difftron-cycle-grouping ()
  "Cycle the difftron grouping mode for the current buffer."
  (interactive)
  (unless difftron--payload
    (user-error
     "No difftron payload is associated with this buffer"))
  (setq difftron-default-grouping
        (pcase difftron--grouping
          ('kind 'file)
          (_ 'kind)))
  (setq difftron--grouping difftron-default-grouping)
  (difftron--display-buffer
   difftron--default-directory
   difftron--command-args
   difftron--payload)
  (with-current-buffer difftron-buffer-name
    (difftron--show-entity-tree-level-3)))

(defun difftron-select-left ()
  "Select a new left-hand snapshot and refresh the diff."
  (interactive)
  (difftron--select-side 'lhs))

(defun difftron-select-right ()
  "Select a new right-hand snapshot and refresh the diff."
  (interactive)
  (difftron--select-side 'rhs))

(defun difftron--select-side (side)
  "Select a new snapshot for SIDE and refresh the current diff."
  (unless difftron--payload
    (user-error
     "No difftron payload is associated with this buffer"))
  (unless difftron--default-directory
    (user-error
     "No difftron command is associated with this buffer"))
  (let*
      (
       (lhs-snapshot (plist-get difftron--payload :lhs))
       (rhs-snapshot (plist-get difftron--payload :rhs))
       (new-arg
        (difftron--read-snapshot-arg
         side
         difftron--default-directory
         (difftron--snapshot-arg
          (pcase side
            ('lhs lhs-snapshot)
            (_ rhs-snapshot)))))
       (lhs
        (if (eq side 'lhs)
            new-arg
          (difftron--snapshot-arg lhs-snapshot)))
       (rhs
        (if (eq side 'rhs)
            new-arg
          (difftron--snapshot-arg rhs-snapshot))))
    (difftron--run-and-display-diff lhs rhs)))

(defun difftron--read-snapshot-arg
    (side repo-root &optional default-arg)
  "Read a snapshot argument for SIDE in REPO-ROOT.
DEFAULT-ARG is used when the minibuffer input is empty."
  (let*
      (
       (repo-root (file-name-as-directory (expand-file-name repo-root)))
       (default-directory repo-root)
       (candidates (difftron--snapshot-candidates repo-root))
       (completion-table
        (difftron--snapshot-completion-table candidates))
       (input
        (completing-read
         (format "%s snapshot: " (difftron--side-label side))
         completion-table
         nil
         nil
         nil
         'difftron--snapshot-history
         default-arg))
       (input
        (if (and (string-empty-p input) default-arg)
            default-arg
          input))
       (candidate
        (difftron--snapshot-candidate-by-label
         input
         candidates)))
    (cond
     ((equal (plist-get candidate :value) 'browse-path)
      (difftron--read-snapshot-path side repo-root default-arg))
     (candidate (plist-get candidate :value))
     ((difftron--snapshot-existing-path input repo-root))
     (t input))))

(defun difftron--snapshot-candidates (repo-root)
  "Return snapshot completion candidates rooted at REPO-ROOT."
  (difftron--uniquify-snapshot-candidate-labels
   (append
    (difftron--snapshot-branch-candidates)
    (difftron--snapshot-commit-candidates)
    (difftron--snapshot-path-candidates repo-root)
    (list
     (list
      :label difftron--browse-path-choice
      :value 'browse-path
      :group "Repo Paths"
      :kind 'browse)))))

(defun difftron--snapshot-branch-candidates ()
  "Return branch candidates for snapshot completion."
  (mapcar
   (lambda (branch)
     (list
      :label branch
      :value branch
      :group "Branches"
      :kind 'branch))
   (delete-dups
    (seq-filter
     #'stringp
     (append '("HEAD") (or (magit-list-branch-names) nil))))))

(defun difftron--snapshot-commit-candidates ()
  "Return recent commit candidates for snapshot completion."
  (seq-keep
   (lambda (line)
     (when
         (string-match
          "^\\([^\t]+\\)\t\\([^\t]+\\)\t\\([^\t]*\\)\t\\([^\t]*\\)\t\\(.*\\)$"
          line)
       (let
           (
            (short (match-string 1 line))
            (full (match-string 2 line))
            (author (match-string 3 line))
            (date (match-string 4 line))
            (subject (match-string 5 line)))
         (list
          :label (format "%s %s" short subject)
          :value full
          :group "Current Branch Commits"
          :author author
          :date date
          :kind 'commit))))
   (magit-git-lines
    "log"
    (format "--max-count=%d" difftron-snapshot-commit-limit)
    "--date=short"
    "--format=%h%x09%H%x09%an%x09%ad%x09%s")))

(defun difftron--snapshot-commit-annotation
    (author date column)
  "Return aligned completion metadata for commit AUTHOR and DATE at COLUMN."
  (concat
   (propertize
    " "
    'display
    `(space :align-to ,column))
   (format "%-24s %s" author date)))

(defun difftron--snapshot-path-candidates (repo-root)
  "Return tracked path candidates rooted at REPO-ROOT."
  (mapcar
   (lambda (path)
     (list
      :label path
      :value
      (difftron--format-snapshot-path
       (expand-file-name path repo-root))
      :group "Repo Paths"
      :kind 'path))
   (difftron--snapshot-repo-paths)))

(defun difftron--snapshot-repo-paths ()
  "Return tracked file and directory paths in the current repository."
  (let (paths)
    (dolist (file (magit-git-lines "ls-files"))
      (when (and (stringp file) (not (string-empty-p file)))
        (push file paths)
        (let ((dir (file-name-directory file)))
          (while (and dir (not (string-empty-p dir)))
            (push (file-name-as-directory dir) paths)
            (setq dir
                  (file-name-directory
                   (directory-file-name dir)))))))
    (sort (delete-dups paths) #'string<)))

(defun difftron--uniquify-snapshot-candidate-labels
    (candidates)
  "Return CANDIDATES with duplicate labels disambiguated."
  (let
      (
       (seen (make-hash-table :test #'equal))
       unique)
    (dolist (candidate candidates (nreverse unique))
      (let ((label (plist-get candidate :label)))
        (if (gethash label seen)
            (push
             (plist-put
              (copy-sequence candidate)
              :label
              (format
               "%s  [%s]"
               label
               (plist-get candidate :kind)))
             unique)
          (puthash label t seen)
          (push candidate unique))))))

(defun difftron--snapshot-completion-table
    (candidates)
  "Return a completion table for snapshot CANDIDATES."
  (let*
      (
       (labels (mapcar
                (lambda (candidate)
                  (plist-get candidate :label))
                candidates))
       (annotation-column
        (difftron--snapshot-annotation-column labels)))
    (lambda (string pred action)
      (if (eq action 'metadata)
          `(metadata
            (category . difftron-snapshot)
            (group-function
             .
             ,(lambda (candidate &optional transform)
                (if transform
                    candidate
                  (or
                   (plist-get
                    (difftron--snapshot-candidate-by-label
                     candidate
                     candidates)
                    :group)
                   ""))))
            (affixation-function
             .
             ,(lambda (strings)
                (mapcar
                 (lambda (candidate)
                   (list
                    candidate
                    ""
                    (let
                        (
                         (snapshot-candidate
                          (difftron--snapshot-candidate-by-label
                           candidate
                           candidates)))
                      (if (eq
                           (plist-get snapshot-candidate :kind)
                           'commit)
                          (difftron--snapshot-commit-annotation
                           (plist-get snapshot-candidate :author)
                           (plist-get snapshot-candidate :date)
                           annotation-column)
                        ""))))
                 strings)))
            (display-sort-function . identity)
            (cycle-sort-function . identity))
	(complete-with-action action labels string pred)))))

(defun difftron--snapshot-annotation-column (labels)
  "Return the metadata column for completion LABELS."
  (+ 2 (apply #'max 0 (mapcar #'length labels))))

(defun difftron--snapshot-candidate-by-label
    (label candidates)
  "Return the candidate with LABEL from CANDIDATES."
  (seq-find
   (lambda (candidate)
     (equal (plist-get candidate :label) label))
   candidates))

(defun difftron--read-snapshot-path
    (side repo-root default-arg)
  "Read a filesystem snapshot path for SIDE in REPO-ROOT.
DEFAULT-ARG provides the initial path when it names a path."
  (difftron--format-snapshot-path
   (read-file-name
    (format "%s path: " (difftron--side-label side))
    repo-root
    (difftron--snapshot-path-default default-arg repo-root)
    t)))

(defun difftron--snapshot-path-default
    (default-arg repo-root)
  "Return a path default from DEFAULT-ARG rooted at REPO-ROOT."
  (cond
   ((not default-arg) repo-root)
   ((file-name-absolute-p default-arg) default-arg)
   (t
    (let ((path (expand-file-name default-arg repo-root)))
      (if (file-exists-p path)
          path
        repo-root)))))

(defun difftron--snapshot-existing-path
    (input repo-root)
  "Return normalized INPUT as a path under REPO-ROOT if it exists."
  (let ((path (expand-file-name input repo-root)))
    (and (file-exists-p path)
         (difftron--format-snapshot-path path))))

(defun difftron--format-snapshot-path (path)
  "Normalize PATH as a Difftron snapshot argument."
  (let ((path (expand-file-name path)))
    (if (file-directory-p path)
        (file-name-as-directory path)
      path)))

(defun difftron--snapshot-arg (snapshot)
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

(defun difftron--side-label (side)
  "Return a prompt label for SIDE."
  (pcase side
    ('lhs "Left")
    (_ "Right")))

(defun difftron-toggle-section-or-message ()
  "Toggle revision details at point or the current Magit section."
  (interactive)
  (magit-section-toggle
   (or (difftron--snapshot-section-at-point)
       (magit-current-section))))

(defun difftron-toggle-commit-messages ()
  "Toggle revision details for both Git revision snapshots."
  (interactive)
  (let ((sections (difftron--snapshot-sections)))
    (unless sections
      (user-error "No expandable Git revision snapshots in this buffer"))
    (if
        (seq-some
         (lambda (section)
           (oref section hidden))
         sections)
        (dolist (section sections)
          (when (oref section hidden)
            (magit-section-show section)))
      (dolist (section sections)
        (magit-section-hide section)))))

(defun difftron--snapshot-section-at-point ()
  "Return the snapshot section at point, if point is inside one."
  (let ((section (magit-current-section)))
    (while
        (and section (not (eq (oref section type) 'difftron-snapshot)))
      (setq section (oref section parent)))
    section))

(defun difftron--snapshot-sections ()
  "Return expandable Git snapshot sections in the current buffer."
  (and
   magit-root-section
   (seq-filter
    (lambda (section)
      (eq (oref section type) 'difftron-snapshot))
    (oref magit-root-section children))))

(defun difftron--show-entity-tree-level-3 ()
  "Show the entity tree to level 3 while leaving snapshots collapsed."
  (when-let ((section (difftron--first-entity-tree-section)))
    (goto-char (oref section start))
    (magit-section-show-level-3))
  (difftron--hide-snapshot-sections))

(defun difftron--first-entity-tree-section ()
  "Return the first root child that belongs to the entity tree."
  (seq-find
   (lambda (section)
     (not (eq (oref section type) 'difftron-snapshot)))
   (oref magit-root-section children)))

(defun difftron--hide-snapshot-sections ()
  "Collapse all expandable Git snapshot sections."
  (dolist (section (difftron--snapshot-sections))
    (if (oref section hidden)
        (magit-section-maybe-update-visibility-indicator section)
      (magit-section-hide section))))

(defun difftron--paint-section-visibility ()
  "Apply Magit's visibility overlays from the root section."
  (when magit-root-section
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))))

(defun difftron-next-commit ()
  "Show the next commit on HEAD's first-parent history."
  (interactive)
  (difftron--show-commit-diff
   (difftron--next-commit
    (difftron--current-rhs-revision))))

(defun difftron-previous-commit ()
  "Show the first-parent commit before the current RHS commit."
  (interactive)
  (difftron--show-commit-diff
   (or
    (difftron--commit-parent
     (difftron--current-rhs-revision))
    (user-error "No previous commit"))))

(defun difftron--current-rhs-revision ()
  "Return the Git revision for the current diff RHS."
  (let ((rhs (plist-get difftron--payload :rhs)))
    (unless (equal (plist-get rhs :kind) "git_revision")
      (user-error
       "Difftron buffer is not showing a Git revision diff"))
    (or (plist-get rhs :rev)
        (user-error "Difftron diff RHS has no Git revision"))))

(defun difftron--next-commit (rev)
  "Return the next commit after REV on HEAD's first-parent history."
  (let
      (
       (default-directory
        (or difftron--default-directory default-directory)))
    (or
     (car
      (magit-git-lines
       "rev-list"
       "--first-parent"
       "--reverse"
       (format "%s..HEAD" rev)))
     (user-error "No next commit on HEAD's first-parent history"))))

(defun difftron--commit-parent (rev)
  "Return the first parent of REV, or nil for a root commit."
  (let*
      (
       (default-directory
        (or difftron--default-directory default-directory))
       (line (car (magit-git-lines "rev-list" "-1" "--parents" rev)))
       (parts (and line (split-string line))))
    (cadr parts)))

(defun difftron--show-commit-diff (rev)
  "Render the difftron diff for commit REV."
  (let
      (
       (parent
        (or (difftron--commit-parent rev)
            (user-error "Commit %s has no parent" rev))))
    (difftron--run-and-display-diff parent rev)))

(defun difftron--run-and-display-diff (lhs rhs)
  "Run and display a difftron diff from LHS to RHS."
  (unless difftron--default-directory
    (user-error
     "No difftron command is associated with this buffer"))
  (let*
      (
       (args
        (append
         (list "diff" lhs rhs "--format" "json")
         (difftron--command-path-args
          difftron--command-args)))
       (payload
        (difftron--run-command
         difftron--default-directory
         args)))
    (difftron--display-buffer
     difftron--default-directory
     args
     payload)))

(defun difftron--command-path-args (args)
  "Return the --path arguments from difftron command ARGS."
  (let (paths)
    (while args
      (let ((arg (pop args)))
        (when (and (equal arg "--path") args)
          (push "--path" paths)
          (push (pop args) paths))))
    (nreverse paths)))

(defun difftron-visit-thing ()
  "Visit the entity at point or activate a button."
  (interactive)
  (if-let*
      (
       (section (difftron--entity-section-at-point))
       (entity (plist-get (oref section value) :entity)))
      (difftron--visit-entity entity)
    (if-let ((button (difftron--button-at-point)))
        (push-button (button-start button))
      (magit-section-toggle (magit-current-section)))))

(defun difftron--button-at-point ()
  "Return the button at point, accepting point just after button text."
  (or (button-at (point))
      (and (> (point) (point-min)) (button-at (1- (point))))))

(defun difftron--display-buffer
    (repo-default-directory args payload)
  "Render PAYLOAD in the dedicated buffer.
REPO-DEFAULT-DIRECTORY and ARGS are stored to support refresh."
  (let ((buffer (get-buffer-create difftron-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (difftron-mode)
        (setq difftron--grouping
              difftron-default-grouping)
        (setq difftron--default-directory
              repo-default-directory)
        (setq difftron--command-args args)
        (setq difftron--payload payload)
        (erase-buffer)
        (difftron--insert-payload payload)
        (difftron--show-entity-tree-level-3)
        (difftron--paint-section-visibility)
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(defun difftron-refresh-buffer ()
  "Refresh the current difftron buffer using Magit's refresh machinery."
  (setq difftron--payload
        (difftron--run-command
         difftron--default-directory
         difftron--command-args))
  (difftron--insert-payload difftron--payload))

(defun difftron--insert-payload (payload)
  "Insert PAYLOAD into the current buffer."
  (setq difftron--entity-kind-order
        (plist-get payload :entity_kind_order))
  (setq difftron--entity-kinds
        (plist-get payload :entity_kinds))
  (magit-insert-section
      (difftron-root)
    (pcase (plist-get payload :command)
      ("diff" (difftron--insert-diff payload))
      ("list" (difftron--insert-list payload))
      (_
       (insert
        (format "Unsupported difftron command: %S" payload))))))

(defun difftron--insert-list (payload)
  "Insert a list-mode PAYLOAD into the current buffer."
  (difftron--insert-title
   (format "difftron list %s"
           (plist-get (plist-get payload :snapshot) :label)))
  (difftron--insert-items
   (mapcar
    #'difftron--list-entity->item
    (plist-get payload :entities))))

(defun difftron--insert-diff (payload)
  "Insert a diff PAYLOAD into the current buffer."
  (let
      (
       (lhs (plist-get payload :lhs))
       (rhs (plist-get payload :rhs)))
    (difftron--insert-snapshot-line "lhs" lhs)
    (difftron--insert-snapshot-line "rhs" rhs)
    (insert "\n")
    (difftron--insert-items
     (difftron--diff-items payload))))

(defun difftron--insert-snapshot-line (name snapshot)
  "Insert one clickable diff endpoint NAME for SNAPSHOT."
  (if (equal (plist-get snapshot :kind) "git_revision")
      (let ((side (intern name)))
        (magit-insert-section
            (difftron-snapshot side t)
          (difftron--insert-snapshot-heading name snapshot)
          (magit-insert-heading)
          (difftron--add-snapshot-heading-properties
           side
           snapshot
           (oref magit-insert-section--current start)
           (oref magit-insert-section--current content))
          (magit-insert-section-body
            (difftron--insert-revision-details snapshot))))
    (difftron--insert-snapshot-heading name snapshot)
    (insert "\n")))

(defun difftron--insert-snapshot-heading (name snapshot)
  "Insert the snapshot heading for endpoint NAME and SNAPSHOT."
  (insert
   (propertize (format "%s: " name)
               'font-lock-face
               'magit-section-heading))
  (insert-text-button
   (difftron--display-label (plist-get snapshot :label))
   'action
   (lambda (_button) (difftron--visit-snapshot snapshot))
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
                   'magit-section-secondary-heading)))))

(defun difftron--add-snapshot-heading-properties
    (side snapshot start end)
  "Mark the Git snapshot heading from START to END for SIDE and SNAPSHOT."
  (add-text-properties
   start end
   (list
    'difftron-snapshot-side
    side
    'difftron-snapshot
    snapshot
    'mouse-face
    'highlight
    'help-echo
    "TAB toggles revision details, RET visits snapshot")))

(defun difftron--insert-revision-details (snapshot)
  "Insert Magit-style revision details for SNAPSHOT."
  (condition-case err
      (let
          (
           (rev
            (or (plist-get snapshot :rev)
                (user-error "Git revision snapshot has no revision")))
           (default-directory
            (or (plist-get snapshot :root) default-directory)))
        (require 'magit-log)
        (require 'magit-diff)
        (let ((magit-buffer-revision rev))
          (magit-insert-revision-headers)
          (magit-insert-revision-message)))
    (error
     (insert
      (propertize
       (format
        "Revision details unavailable: %s\n"
        (error-message-string err))
       'font-lock-face
       'magit-section-secondary-heading)))))

(defun difftron--visit-snapshot (snapshot)
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

(defun difftron--display-label (label)
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

(defun difftron--insert-title (title)
  "Insert TITLE at the top of the current buffer."
  (insert (propertize title 'font-lock-face 'magit-section-heading))
  (insert "\n\n"))

(defun difftron--insert-kind-groups (items)
  "Insert ITEMS grouped by entity kind."
  (let ((groups (difftron--group-items-by-kind items)))
    (if groups
        (dolist (group groups)
          (difftron--insert-kind-file-group
           (car group)
           (cdr group)
           0))
      (insert "No entities\n"))))

(defun difftron--insert-file-groups (items)
  "Insert ITEMS grouped by file."
  (let ((groups (difftron--group-items-by-file items)))
    (if groups
        (dolist (group groups)
          (difftron--insert-file-kind-group
           (car group)
           (cdr group)
           0))
      (insert "No entities\n"))))

(defun difftron--insert-kind-file-group (kind items depth)
  "Insert a kind heading for KIND and file groups for ITEMS at DEPTH."
  (magit-insert-section
      (difftron-kind kind t)
    (magit-insert-heading
      (difftron--kind-heading kind items depth))
    (dolist (group (difftron--group-items-by-file items))
      (difftron--insert-file-entity-group
       (car group)
       (cdr group)
       (1+ depth)))
    (insert "\n")))

(defun difftron--insert-file-kind-group (file items depth)
  "Insert a file heading for FILE and kind groups for ITEMS at DEPTH."
  (magit-insert-section
      (difftron-file file t)
    (magit-insert-heading
      (difftron--file-heading file items depth))
    (dolist (group (difftron--group-items-by-kind items))
      (difftron--insert-kind-entity-group
       (car group)
       (cdr group)
       (1+ depth)))
    (insert "\n")))

(defun difftron--insert-kind-entity-group (kind items depth)
  "Insert a kind heading for KIND and entity ITEMS at DEPTH."
  (magit-insert-section
      (difftron-kind kind t)
    (magit-insert-heading
      (difftron--kind-heading kind items depth))
    (dolist (item items)
      (difftron--insert-item item (1+ depth)))
    (insert "\n")))

(defun difftron--insert-file-entity-group (file items depth)
  "Insert a file heading for FILE and entity ITEMS at DEPTH."
  (magit-insert-section
      (difftron-file file t)
    (magit-insert-heading
      (difftron--file-heading file items depth))
    (dolist (item items)
      (difftron--insert-item item (1+ depth)))
    (insert "\n")))

(defun difftron--kind-heading (kind items depth)
  "Return the heading text for KIND containing ITEMS at DEPTH."
  (propertize
   (format "%s%s (%d)"
           (difftron--indent depth)
           (difftron--kind-label kind)
           (length items))
   'font-lock-face (difftron--heading-face depth)))

(defun difftron--file-heading (file items depth)
  "Return the heading text for FILE containing ITEMS at DEPTH."
  (propertize
   (format "%s%s (%d)"
           (difftron--indent depth)
           file
           (length items))
   'font-lock-face (difftron--heading-face depth)))

(defun difftron--insert-item (item depth)
  "Insert ITEM as a foldable heading at DEPTH."
  (let ((entity (plist-get item :entity)))
    (magit-insert-section
        (difftron-entity item t)
      (magit-insert-heading
        (propertize
         (format "%s%s"
                 (difftron--indent depth)
                 (plist-get item :summary))
         'font-lock-face (difftron--heading-face depth)))
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
         (difftron--insert-structured-diff
          (plist-get item :diff)))
        (_
         (when-let ((source (plist-get entity :source_text)))
           (difftron--insert-diff-text
            source
            (difftron--status-face (plist-get item :status)))
           (unless (string-suffix-p "\n" source)
             (insert "\n")))))
      (unless (eq (char-before) ?\n)
        (insert "\n"))
      (insert "\n"))))

(defun difftron--insert-structured-diff (diff)
  "Insert structured DIFF rows using Emacs layout and faces."
  (let ((rows (plist-get diff :rows)))
    (if rows
        (let ((column-width (difftron--modified-column-width)))
          (dolist (row rows)
            (difftron--insert-structured-diff-row
             row
             column-width)))
      (insert "No diff output.\n"))))

(defun difftron--insert-structured-diff-row (row column-width)
  "Insert one structured diff ROW using COLUMN-WIDTH per side."
  (difftron--insert-structured-side
   (plist-get row :left)
   'left
   column-width)
  (insert " | ")
  (difftron--insert-structured-side
   (plist-get row :right)
   'right
   column-width)
  (insert "\n"))

(defun difftron--insert-structured-side
    (side side-name column-width)
  "Insert SIDE for SIDE-NAME truncated to COLUMN-WIDTH."
  (if side
      (let
          (
           (start (point))
           (face (difftron--side-face side-name)))
        (difftron--insert-structured-segments
         (plist-get side :segments)
         side-name
         face
         column-width)
        (when (eq side-name 'left)
          (difftron--insert-diff-text
           (make-string (max 0 (- column-width (- (point) start))) ?\s)
           face)))
    (when (eq side-name 'left)
      (insert (make-string column-width ?\s)))))

(defun difftron--insert-structured-segments
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
              (difftron--segment-refine-face
               side-name
               (plist-get segment :kind)))
             (start (point)))
          (unless (string-empty-p text)
            (difftron--insert-diff-text text face)
            (when refine-face
              (difftron--add-refine-overlay
               start
               (point)
               refine-face))
            (setq remaining (- remaining (string-width text)))))))))

(defun difftron--insert-diff-text (text face)
  "Insert TEXT with optional diff FACE."
  (if face
      (insert (propertize text 'font-lock-face face))
    (insert text)))

(defun difftron--side-face (side-name)
  "Return the base diff face for SIDE-NAME."
  (ignore side-name)
  'magit-diff-context)

(defun difftron--segment-refine-face (side-name kind)
  "Return the refinement face for segment KIND on SIDE-NAME."
  (pcase kind
    ("novel"
     (pcase side-name
       ('left 'diff-refine-removed)
       (_ 'diff-refine-added)))
    (_ nil)))

(defun difftron--add-refine-overlay (start end face)
  "Add a Magit-style fine diff overlay from START to END using FACE."
  (let ((overlay (make-overlay start end nil t)))
    (overlay-put overlay 'diff-mode 'fine)
    (overlay-put overlay 'evaporate t)
    (overlay-put overlay 'face face)
    overlay))

(defun difftron--modified-column-width ()
  "Return the per-side width for structured modified diffs."
  (max 24 (/ (- (difftron--current-display-width) 3) 2)))

(defun difftron--visit-entity (entity)
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

(defun difftron--diff-items (payload)
  "Flatten diff PAYLOAD into display items."
  (append
   (mapcar
    (lambda (entity)
      (difftron--item-from-entity 'added entity))
    (plist-get payload :added))
   (mapcar
    (lambda (entity)
      (difftron--item-from-entity 'deleted entity))
    (plist-get payload :deleted))
   (mapcan
    #'difftron--items-from-move
    (plist-get payload :moved))
   (mapcan
    #'difftron--items-from-moved-modified
    (plist-get payload :moved_modified))
   (mapcar
    #'difftron--item-from-change
    (plist-get payload :modified))))

(defun difftron--item-from-change (change)
  "Build a display item from modified CHANGE."
  (let ((rhs (plist-get change :rhs)))
    (list
     :kind (plist-get rhs :kind)
     :status 'modified
     :entity rhs
     :summary (format "M %s" (plist-get rhs :name))
     :diff (plist-get change :diff))))

(defun difftron--items-from-move (change)
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

(defun difftron--items-from-moved-modified (change)
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

(defun difftron--item-from-entity (status entity)
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

(defun difftron--list-entity->item (entity)
  "Build a display item from a list-mode ENTITY."
  (list
   :kind (plist-get entity :kind)
   :status 'present
   :entity entity
   :summary (plist-get entity :name)))

(defun difftron--group-items
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

(defun difftron--group-items-by-kind (items)
  "Group ITEMS by entity kind in display order."
  (difftron--group-items
   items
   (lambda (item) (plist-get item :kind))
   #'difftron--kind-lessp))

(defun difftron--group-items-by-file (items)
  "Group ITEMS by relative path."
  (difftron--group-items items
                         (lambda (item)
                           (plist-get (plist-get item :entity) :snapshot_path))
                         #'string<
                         #'difftron--item-lessp))

(defun difftron--item-lessp (lhs rhs)
  "Return non-nil when LHS should sort before RHS."
  (let
      (
       (lhs-rank
        (difftron--status-rank (plist-get lhs :status)))
       (rhs-rank
        (difftron--status-rank (plist-get rhs :status))))
    (if (/= lhs-rank rhs-rank)
        (< lhs-rank rhs-rank)
      (string< (plist-get lhs :summary) (plist-get rhs :summary)))))

(defun difftron--kind-lessp (lhs rhs)
  "Return non-nil when kind LHS should sort before RHS."
  (let
      (
       (lhs-rank (difftron--kind-rank lhs))
       (rhs-rank (difftron--kind-rank rhs)))
    (if (= lhs-rank rhs-rank)
        (string< lhs rhs)
      (< lhs-rank rhs-rank))))

(defun difftron--kind-rank (kind)
  "Return the display rank for KIND."
  (or
   (cl-position
    kind
    difftron--entity-kind-order
    :test #'equal)
   (length difftron--entity-kind-order)))

(defun difftron--kind-label (kind)
  "Return the user-facing heading label for KIND."
  (or (plist-get (difftron--kind-metadata kind) :group_label)
      kind))

(defun difftron--kind-metadata (kind)
  "Return the metadata plist for KIND."
  (plist-get
   difftron--entity-kinds
   (intern (concat ":" kind))))

(defun difftron--status-rank (status)
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

(defun difftron--status-face (status)
  "Return the Magit face for STATUS."
  (pcase status
    ('added 'magit-diff-added)
    ('deleted 'magit-diff-removed)
    (_ nil)))

(defun difftron--insert-items (items)
  "Insert ITEMS using the current grouping mode."
  (pcase difftron--grouping
    ('file (difftron--insert-file-groups items))
    (_ (difftron--insert-kind-groups items))))

(defun difftron--indent (depth)
  "Return indentation for section DEPTH."
  (make-string (* depth 2) ?\s))

(defun difftron--heading-face (depth)
  "Return the heading face for section DEPTH."
  (pcase depth
    (0 'magit-section-heading)
    (1 'difftron-level-1-heading)
    (_ 'difftron-level-2-heading)))

(defun difftron--current-display-width ()
  "Return the current window body width in character columns."
  (max 20
       (if-let ((window (selected-window)))
           (window-body-width window)
         (frame-width))))

(defun difftron--run-command (repo-default-directory args)
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
                       difftron-executable
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

(defun difftron--repo-root ()
  "Return the repository root for the current buffer."
  (or
   (and (fboundp 'magit-toplevel)
        (ignore-errors
          (magit-toplevel)))
   (locate-dominating-file default-directory ".git")
   (user-error "Not inside a Git repository")))

(defun difftron--dwim-endpoints (spec repo-root)
  "Return difftron LHS and RHS endpoints from Magit SPEC in REPO-ROOT."
  (pcase spec
    ((or 'unstaged 'staged 'unmerged 'undefined)
     (list "HEAD" repo-root))
    (`(commit . ,rev) (list (format "%s^" rev) rev))
    (`(stash . ,rev) (list (format "%s^" rev) rev))
    ((pred stringp)
     (or (difftron--range-endpoints spec)
         (list spec repo-root)))
    (_ (list "HEAD" repo-root))))

(defun difftron--range-endpoints (range)
  "Return LHS and RHS endpoints for Git diff RANGE, or nil."
  (cond
   ((string-match "\\`\\(.+\\)\\.\\.\\.\\(.+\\)\\'" range)
    (list (match-string 1 range) (match-string 2 range)))
   ((string-match "\\`\\(.+\\)\\.\\.\\(.+\\)\\'" range)
    (list (match-string 1 range) (match-string 2 range)))))

(defun difftron--magit-diff-path-at-point ()
  "Return the relative Magit diff file path at point, if any."
  (when-let ((section (magit-diff--file-section)))
    (or
     (and (difftron--magit-diff-removed-line-p)
          (oref section source))
     (oref section value)
     (oref section source))))

(defun difftron--magit-diff-line-at-point ()
  "Return the Magit diff hunk line at point, if any."
  (when-let ((section (magit-diff--hunk-section)))
    (magit-diff-hunk-line
     section
     (difftron--magit-diff-removed-line-p))))

(defun difftron--magit-diff-removed-line-p ()
  "Return non-nil if point is on a removed Magit diff line."
  (and (fboundp 'magit-diff-on-removed-line-p)
       (magit-diff-on-removed-line-p)))

(defun difftron--goto-entity-for-source (path line)
  "Move point to the difftron entity for PATH and optional LINE."
  (when-let
      (
       (section
        (or (difftron--find-entity-section path line)
            (difftron--find-entity-section path nil))))
    (difftron--show-section-and-ancestors section)
    (goto-char (oref section start))))

(defun difftron--find-entity-section (path line)
  "Return the entity section matching PATH and LINE."
  (seq-find
   (lambda (section)
     (difftron--entity-section-matches-p section path line))
   (difftron--entity-sections magit-root-section)))

(defun difftron--entity-sections (section)
  "Return entity sections below SECTION."
  (append
   (and (eq (oref section type) 'difftron-entity) (list section))
   (mapcan
    #'difftron--entity-sections
    (oref section children))))

(defun difftron--entity-section-matches-p (section path line)
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

(defun difftron--show-section-and-ancestors (section)
  "Show SECTION and its ancestors."
  (let ((current section))
    (while current
      (magit-section-show current)
      (setq current (oref current parent)))))

(defun difftron--entity-section-at-point ()
  "Return the nearest entity section at point, if any."
  (let ((section (magit-current-section)))
    (while
        (and section (not (eq (oref section type) 'difftron-entity)))
      (setq section (oref section parent)))
    section))

(defun difftron-register-magit-diff-suffix ()
  "Register difftron in the `magit-diff' transient."
  (when (featurep 'magit-diff)
    (unless (difftron--magit-diff-suffix-p "D")
      (transient-append-suffix
        'magit-diff
        "d"
        difftron--magit-diff-suffix))))

(defun difftron--magit-diff-suffix-p (key)
  "Return non-nil if KEY is registered in the `magit-diff' transient."
  (ignore-errors
    (transient-get-suffix 'magit-diff key)))

(defun difftron-register-magit-diff-bindings ()
  "Register difftron bindings in Magit diff buffers."
  (when (featurep 'magit-diff)
    (difftron-register-magit-diff-suffix)
    (define-key
     magit-diff-mode-map
     (kbd "D")
     #'difftron-diff-at-point)
    (define-key
     magit-diff-section-map
     (kbd "D")
     #'difftron-diff-at-point)))

(defun difftron-unregister-magit-diff-suffix ()
  "Remove difftron from the `magit-diff' transient."
  (when (featurep 'magit-diff)
    (when (difftron--magit-diff-suffix-p "D")
      (transient-remove-suffix 'magit-diff "D"))))

(defun difftron-unregister-magit-diff-bindings ()
  "Remove difftron bindings from Magit diff buffers."
  (when (featurep 'magit-diff)
    (difftron-unregister-magit-diff-suffix)
    (define-key magit-diff-mode-map (kbd "D") nil)
    (define-key magit-diff-section-map (kbd "D") nil)))

(defun difftron--maybe-register-magit-diff-suffix
    (&optional file)
  "Register difftron bindings when `magit-diff' becomes available.
When FILE is non-nil, it is the path passed by `after-load-functions'."
  (when
      (and difftron-bindings-mode
           (or (null file) (string= (file-name-base file) "magit-diff")))
    (remove-hook
     'after-load-functions
     #'difftron--maybe-register-magit-diff-suffix)
    (difftron-register-magit-diff-bindings)))

;;;###autoload
(define-minor-mode difftron-bindings-mode
  "Toggle difftron bindings in Magit transients."
  :global t
  :group 'difftron
  :require
  'difftron
  (if difftron-bindings-mode
      (if (featurep 'magit-diff)
          (difftron--maybe-register-magit-diff-suffix)
        (add-hook
         'after-load-functions
         #'difftron--maybe-register-magit-diff-suffix))
    (remove-hook
     'after-load-functions
     #'difftron--maybe-register-magit-diff-suffix)
    (difftron-unregister-magit-diff-bindings)))

(provide 'difftron)

;;; difftron.el ends here
