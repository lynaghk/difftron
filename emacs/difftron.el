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

(defcustom difftron-default-hierarchy '(file)
  "Default hierarchy grouping for difftron buffers."
  :type
  '
  (choice
   (const :tag "File" (file))
   (const :tag "Type" (kind))
   (const :tag "File then type" (file kind))
   (const :tag "Type then file" (kind file)))
  :group 'difftron)

(defcustom difftron-use-magit-paths t
  "Whether Difftron commands launched from Magit use Magit's path filters."
  :type 'boolean
  :group 'difftron)

(defcustom difftron-scroll-section-after-navigation t
  "Whether Difftron section navigation scrolls the destination to the top."
  :type 'boolean
  :group 'difftron)

(defcustom difftron-fill-multiline-change-whitespace t
  "Whether multiline structured diff blocks fill trailing whitespace."
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
    (define-key map (kbd "h") #'difftron-dispatch)
    (define-key map (kbd "?") #'difftron-dispatch)
    (define-key map (kbd "l") #'difftron-select-left)
    (define-key
     map
     (kbd "m")
     #'difftron-toggle-commit-messages)
    (define-key map (kbd "r") #'difftron-select-right)
    (define-key map (kbd "s") #'difftron-swap-sides)
    (define-key map (kbd "y") #'difftron-cycle-hierarchy)
    (define-key map (kbd "n") #'difftron-next-section)
    (define-key map (kbd "p") #'difftron-previous-section)
    (define-key map (kbd "N") #'difftron-next-commit)
    (define-key map (kbd "P") #'difftron-previous-commit)
    (define-key
     map
     (kbd "TAB")
     #'difftron-toggle-section-or-message)
    (define-key map (kbd "RET") #'difftron-visit-thing)
    (define-key
     map
     (kbd "C-<return>")
     #'difftron-visit-thing-in-checkout)
    (define-key map (kbd "C-j") #'difftron-visit-thing-in-checkout)
    map)
  "Keymap for `difftron-mode'.")

(defvar-local difftron--command-args nil)
(defvar-local difftron--default-directory nil)
(defvar-local difftron--payload nil)
(defvar-local difftron--entity-kind-order nil)
(defvar-local difftron--entity-kinds nil)
(defvar-local difftron--hierarchy nil
  "Current hierarchy grouping for the difftron buffer.")
(defvar-local difftron--temporary-expanded-entity nil
  "Temporarily expanded entity section and its previous visibility state.")

(defconst difftron--hierarchy-choices
  '((file) (kind) (file kind) (kind file)))

(defclass difftron--hierarchy-infix (transient-lisp-variable)
  ()
  "Transient infix for cycling the Difftron hierarchy.")

(cl-defmethod transient-infix-read ((obj difftron--hierarchy-infix))
  "Return the next valid hierarchy value for OBJ."
  (difftron--next-hierarchy))

(cl-defmethod transient-infix-set
  ((obj difftron--hierarchy-infix) value)
  "Set OBJ's hierarchy to VALUE."
  (difftron--set-hierarchy value)
  (oset obj value value))

(cl-defmethod transient-format-value ((obj difftron--hierarchy-infix))
  "Format OBJ's hierarchy choices."
  (let*
      (
       (value difftron--hierarchy))
    (format
     (propertize "(%s)" 'face 'transient-delimiter)
     (mapconcat
      (lambda (choice)
        (propertize
         (difftron--hierarchy-label choice)
         'face
         (if (equal choice value)
             'transient-value
           'transient-inactive-value)))
      difftron--hierarchy-choices
      (propertize " | " 'face 'transient-delimiter)))))

(transient-define-infix difftron--hierarchy-choice-infix ()
  "Cycle Difftron hierarchy."
  :class 'difftron--hierarchy-infix
  :variable 'difftron--hierarchy
  :format " %k %d %v"
  :key "y"
  :description "Cycle hierarchy")

(define-derived-mode
  difftron-mode
  magit-section-mode
  "difftron"
  "Major mode for difftron results."
  (setq-local truncate-lines t)
  (setq-local difftron--hierarchy
              difftron-default-hierarchy))

(transient-define-prefix
  difftron-dispatch
  ()
  "Show commands for `difftron-mode'."
  [
   ["Difftron"
    ("g" "Refresh" difftron-refresh)
    ("m" "Toggle commit messages" difftron-toggle-commit-messages)
    ("l" "Select left" difftron-select-left)
    ("r" "Select right" difftron-select-right)
    ("s" "Swap sides" difftron-swap-sides)
    ("w" "Toggle block fill" difftron-toggle-multiline-change-whitespace)
    ("q" "Quit buffer" quit-window)
    ("TAB" "Toggle section/details" difftron-toggle-section-or-message)
    ("RET" "Visit thing" difftron-visit-thing)
    ("C-<return>" "Visit checkout" difftron-visit-thing-in-checkout)]
   
   ["Visibility"
    (difftron--hierarchy-choice-infix)
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
    ("n" "Next section" difftron-next-section)
    ("p" "Previous section" difftron-previous-section)
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

(defun difftron-cycle-hierarchy ()
  "Cycle the difftron hierarchy grouping."
  (interactive)
  (unless difftron--payload
    (user-error
     "No difftron payload is associated with this buffer"))
  (difftron--set-hierarchy (difftron--next-hierarchy)))

(defun difftron-toggle-multiline-change-whitespace ()
  "Toggle multiline structured diff trailing whitespace fill."
  (interactive)
  (setq difftron-fill-multiline-change-whitespace
        (not difftron-fill-multiline-change-whitespace))
  (when difftron--payload
    (difftron--display-buffer
     difftron--default-directory
     difftron--command-args
     difftron--payload)
    (with-current-buffer difftron-buffer-name
      (difftron--show-entity-tree-level-3))))

(defun difftron--set-hierarchy (hierarchy)
  "Set HIERARCHY and redraw the current difftron buffer."
  (setq difftron-default-hierarchy hierarchy)
  (setq difftron--hierarchy hierarchy)
  (when difftron--payload
    (difftron--display-buffer
     difftron--default-directory
     difftron--command-args
     difftron--payload)
    (with-current-buffer difftron-buffer-name
      (difftron--show-entity-tree-level-3))))

(defun difftron--next-hierarchy ()
  "Return the next hierarchy choice."
  (let*
      (
       (index
        (cl-position
         difftron--hierarchy
         difftron--hierarchy-choices
         :test #'equal)))
    (nth
     (mod
      (1+ (or index -1))
      (length difftron--hierarchy-choices))
     difftron--hierarchy-choices)))

(defun difftron--hierarchy-label (hierarchy)
  "Return the transient display label for HIERARCHY."
  (mapconcat
   (lambda (grouping)
     (pcase grouping
       ('file "file")
       ('kind "type")))
   hierarchy
   " > "))

(defun difftron-select-left ()
  "Select a new left-hand snapshot and refresh the diff."
  (interactive)
  (difftron--select-side 'lhs))

(defun difftron-select-right ()
  "Select a new right-hand snapshot and refresh the diff."
  (interactive)
  (difftron--select-side 'rhs))

(defun difftron-swap-sides ()
  "Swap the left- and right-hand snapshots and refresh the diff."
  (interactive)
  (unless difftron--payload
    (user-error
     "No difftron payload is associated with this buffer"))
  (let
      (
       (lhs
        (difftron--snapshot-arg
         (plist-get difftron--payload :lhs)))
       (rhs
        (difftron--snapshot-arg
         (plist-get difftron--payload :rhs))))
    (difftron--run-and-display-diff rhs lhs)))

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
  "Show grouping levels while leaving snapshots and entity bodies collapsed."
  (when-let ((section (difftron--first-entity-tree-section)))
    (goto-char (oref section start))
    (magit-section-show-level
     (- (1+ (length (difftron--effective-hierarchy))))))
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

(defun difftron-next-section ()
  "Move to the beginning of the next visible section."
  (interactive)
  (magit-section-forward)
  (difftron--temporarily-unfold-entity-at-point)
  (difftron--scroll-navigation-destination))

(defun difftron-previous-section ()
  "Move to the beginning of the current or previous visible section."
  (interactive)
  (magit-section-backward)
  (difftron--temporarily-unfold-entity-at-point)
  (difftron--scroll-navigation-destination))

(defun difftron--scroll-navigation-destination ()
  "Scroll the selected window after section navigation, if configured."
  (when difftron-scroll-section-after-navigation
    (recenter 0)))

(defun difftron--temporarily-unfold-entity-at-point ()
  "Fully show the entity at point while preserving temporary visibility."
  (let ((entity (difftron--entity-section-at-point)))
    (difftron--restore-temporary-expanded-entity entity)
    (when
        (and entity
             (not
              (and difftron--temporary-expanded-entity
                   (eq
                    (car difftron--temporary-expanded-entity)
                    entity)))
             (difftron--section-tree-hidden-p entity))
      (setq difftron--temporary-expanded-entity
            (cons
             entity
             (difftron--section-visibility-state entity)))
      (magit-section-show-children entity))))

(defun difftron--restore-temporary-expanded-entity (current-entity)
  "Restore temporary entity visibility unless it is CURRENT-ENTITY."
  (when
      (and difftron--temporary-expanded-entity
           (not
            (eq
             (car difftron--temporary-expanded-entity)
             current-entity)))
    (difftron--restore-section-visibility-state
     (cdr difftron--temporary-expanded-entity))
    (setq difftron--temporary-expanded-entity nil)))

(defun difftron--section-tree-hidden-p (section)
  "Return non-nil when SECTION or any descendant section is hidden."
  (or
   (oref section hidden)
   (seq-some
    #'difftron--section-tree-hidden-p
    (oref section children))))

(defun difftron--section-visibility-state (section)
  "Return SECTION and descendants paired with their hidden state."
  (cons
   (cons section (oref section hidden))
   (mapcan
    #'difftron--section-visibility-state
    (oref section children))))

(defun difftron--restore-section-visibility-state (state)
  "Restore section visibility from STATE."
  (dolist (entry state)
    (oset (car entry) hidden (cdr entry)))
  (let ((section (caar state)))
    (if (oref section hidden)
        (magit-section-hide section)
      (magit-section-show section))))

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
  (if-let ((button (difftron--button-at-point)))
      (push-button (button-start button))
    (if-let ((source (difftron--source-location-at-point)))
        (difftron--visit-source-location source)
      (if-let*
	  (
	   (section (difftron--entity-section-at-point))
	   (item (oref section value)))
          (difftron--visit-item item)
        (magit-section-toggle (magit-current-section))))))

(defun difftron-visit-thing-in-checkout ()
  "Visit the entity at point in the current checkout."
  (interactive)
  (if-let ((context (difftron--checkout-context-at-point)))
      (difftron--visit-checkout-context context)
    (user-error
     "No Difftron entity at point to visit in current checkout")))

(defun difftron--checkout-context-at-point ()
  "Return checkout visit context for point, if any."
  (or
   (difftron--checkout-context-for-source-at-point)
   (difftron--checkout-context-for-section-at-point)))

(defun difftron--checkout-context-for-source-at-point ()
  "Return checkout context for source text at point, if any."
  (when-let
      (
       (source (difftron--source-location-at-point))
       (snapshot (plist-get source :snapshot))
       (entity (plist-get source :entity))
       (line (plist-get source :line)))
    (list
     :snapshot snapshot
     :entity entity
     :line line
     :column (plist-get source :column)
     :row (difftron--entity-relative-row entity line))))

(defun difftron--checkout-context-for-section-at-point ()
  "Return checkout context for the entity section at point, if any."
  (when-let*
      (
       (section (difftron--entity-section-at-point))
       (item (oref section value))
       (side (difftron--default-side-for-item item))
       (entity (difftron--entity-for-item-side item side))
       (snapshot (difftron--snapshot-for-side side)))
    (let
        (
         (line (or (plist-get entity :start_line) 1))
         (column (max 0 (1- (or (plist-get entity :start_col) 1)))))
      (list
       :snapshot snapshot
       :entity entity
       :line line
       :column column
       :row 1))))

(defun difftron--entity-relative-row (entity line)
  "Return LINE as a one-based row relative to ENTITY."
  (max 1
       (1+
        (- line
           (or (plist-get entity :start_line) 1)))))

(defun difftron--visit-checkout-context (context)
  "Visit CONTEXT in the current checkout."
  (pcase-let*
      (
       (`(,entity ,line ,column)
        (difftron--checkout-target context))
       (buffer (find-file-noselect (plist-get entity :file_path)))
       (pos (difftron--buffer-position buffer line column)))
    (pop-to-buffer-same-window buffer)
    (with-current-buffer buffer
      (goto-char pos))
    buffer))

(defun difftron--checkout-target (context)
  "Return checkout entity, line, and column for CONTEXT."
  (let*
      (
       (snapshot (plist-get context :snapshot))
       (entity (plist-get context :entity))
       (payload
        (difftron--checkout-diff-payload snapshot))
       (target
        (or
         (difftron--checkout-target-from-diff context payload)
         (difftron--checkout-target-from-list context))))
    (unless target
      (user-error
       "Entity is not available or cannot be found in the current checkout"))
    (when (eq (plist-get target :status) 'deleted)
      (user-error
       "Entity is not available in the current checkout"))
    (let*
        (
         (checkout-entity (plist-get target :entity))
         (row
          (or
           (plist-get target :row)
           (plist-get context :row)
           1))
         (line
          (+ (or (plist-get checkout-entity :start_line) 1)
             row
             -1))
         (column
          (or (plist-get context :column)
              (max 0
                   (1-
                    (or (plist-get checkout-entity :start_col) 1))))))
      (list checkout-entity line column))))

(defun difftron--checkout-diff-payload (snapshot)
  "Return a diff payload from SNAPSHOT to the current checkout."
  (difftron--run-command
   (or difftron--default-directory default-directory)
   (list
    "diff"
    (difftron--snapshot-arg snapshot)
    "."
    "--format"
    "json")))

(defun difftron--checkout-list-payload ()
  "Return a list payload for the current checkout."
  (difftron--run-command
   (or difftron--default-directory default-directory)
   '("list" "." "--format" "json")))

(defun difftron--checkout-target-from-diff (context payload)
  "Return a checkout target for CONTEXT from diff PAYLOAD."
  (let ((source (plist-get context :entity)))
    (or
     (difftron--checkout-target-from-changes
      context
      (plist-get payload :modified))
     (difftron--checkout-target-from-changes
      context
      (plist-get payload :moved_modified))
     (difftron--checkout-target-from-moves
      source
      (plist-get payload :moved))
     (difftron--checkout-deleted-target
      source
      (plist-get payload :deleted)))))

(defun difftron--checkout-target-from-changes (context change-list)
  "Use CHANGE-LIST to find checkout target for CONTEXT."
  (let ((source (plist-get context :entity)))
    (seq-some
     (lambda (change)
       (when (difftron--same-entity-p
              source
              (plist-get change :lhs))
         (list
          :status 'present
          :entity (plist-get change :rhs)
          :row
          (difftron--checkout-row-for-change
           change
           (plist-get context :row)))))
     change-list)))

(defun difftron--checkout-target-from-moves (source move-list)
  "Use MOVE-LIST to find checkout target for SOURCE."
  (seq-some
   (lambda (change)
     (when (difftron--same-entity-p
            source
            (plist-get change :lhs))
       (list
        :status 'present
        :entity (plist-get change :rhs))))
   move-list))

(defun difftron--checkout-deleted-target (source deleted-list)
  "Use DELETED-LIST to find deleted checkout target for SOURCE."
  (seq-some
   (lambda (entity)
     (when (difftron--same-entity-p source entity)
       (list :status 'deleted)))
   deleted-list))

(defun difftron--checkout-target-from-list (context)
  "Return a checkout target for CONTEXT from `difftron list'."
  (when-let
      (
       (entity
        (difftron--unique-checkout-list-entity
         (plist-get context :entity)
         (plist-get
          (difftron--checkout-list-payload)
          :entities))))
    (list
     :status 'present
     :entity entity
     :row (plist-get context :row))))

(defun difftron--unique-checkout-list-entity (source entities)
  "Return the unique checkout entity matching SOURCE from ENTITIES."
  (let*
      (
       (by-identity
        (seq-filter
         (lambda (entity)
           (difftron--same-entity-identity-p source entity))
         entities))
       (by-source
        (seq-filter
         (lambda (entity)
           (equal
            (plist-get source :source_text)
            (plist-get entity :source_text)))
         by-identity))
       (by-path
        (seq-filter
         (lambda (entity)
           (equal
            (plist-get source :snapshot_path)
            (plist-get entity :snapshot_path)))
         by-identity)))
    (or
     (difftron--only by-source)
     (difftron--only by-path)
     (difftron--only by-identity))))

(defun difftron--checkout-row-for-change (change source-row)
  "Return the checkout row in CHANGE closest to SOURCE-ROW."
  (or
   (difftron--checkout-row-exact change source-row)
   (difftron--checkout-row-nearest change source-row)
   source-row))

(defun difftron--checkout-row-exact (change source-row)
  "Return the exact checkout row in CHANGE for SOURCE-ROW."
  (seq-some
   (lambda (row)
     (let
         (
          (left (plist-get row :left))
          (right (plist-get row :right)))
       (and
        right
        left
        (equal (plist-get left :line_number) source-row)
        (plist-get right :line_number))))
   (plist-get (plist-get change :diff) :rows)))

(defun difftron--checkout-row-nearest (change source-row)
  "Return the nearest checkout row in CHANGE for SOURCE-ROW."
  (let
      (
       best-distance
       best-row)
    (dolist (row (plist-get (plist-get change :diff) :rows))
      (let
          (
           (left (plist-get row :left))
           (right (plist-get row :right)))
        (when (and left right)
          (let
              (
               (row-distance
                (abs
                 (- (plist-get left :line_number)
                    source-row))))
            (when (or (null best-distance)
                      (< row-distance best-distance))
              (setq best-distance row-distance)
              (setq best-row (plist-get right :line_number)))))))
    best-row))

(defun difftron--same-entity-p (lhs rhs)
  "Return non-nil when LHS and RHS describe the same source entity."
  (and
   (difftron--same-entity-identity-p lhs rhs)
   (or
    (equal (plist-get lhs :source_text)
           (plist-get rhs :source_text))
    (equal (plist-get lhs :snapshot_path)
           (plist-get rhs :snapshot_path)))))

(defun difftron--same-entity-identity-p (lhs rhs)
  "Return non-nil when LHS and RHS share name and kind."
  (and
   lhs
   rhs
   (equal (plist-get lhs :name)
          (plist-get rhs :name))
   (equal (plist-get lhs :kind)
          (plist-get rhs :kind))))

(defun difftron--only (items)
  "Return the only item in ITEMS, or nil."
  (and
   (consp items)
   (null (cdr items))
   (car items)))

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
        (setq difftron--hierarchy
              difftron-default-hierarchy)
        (setq difftron--default-directory
              repo-default-directory)
        (setq difftron--command-args args)
        (setq difftron--payload payload)
        (setq magit-section-visibility-cache nil)
        (setq difftron--temporary-expanded-entity nil)
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
  (setq difftron--payload payload)
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
          (save-restriction
            ;; Magit's revision message inserter moves to `point-max';
            ;; during lazy section washing that must mean the end of this
            ;; insertion, not the end of the Difftron buffer.
            (narrow-to-region (point-min) (point))
            (magit-insert-revision-headers)
            (magit-insert-revision-message))))
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

(defun difftron--insert-kind-group
    (kind items depth remaining-hierarchy)
  "Insert a kind heading for KIND and ITEMS at DEPTH.
REMAINING-HIERARCHY describes nested grouping below this section."
  (magit-insert-section
      (difftron-kind kind t)
    (magit-insert-heading
      (difftron--kind-heading kind items depth))
    (difftron--insert-hierarchy
     items
     remaining-hierarchy
     (1+ depth))
    (insert "\n")))

(defun difftron--insert-file-group
    (file items depth remaining-hierarchy)
  "Insert a file heading for FILE and ITEMS at DEPTH.
REMAINING-HIERARCHY describes nested grouping below this section."
  (magit-insert-section
      (difftron-file file t)
    (magit-insert-heading
      (difftron--file-heading file items depth))
    (difftron--insert-hierarchy
     items
     remaining-hierarchy
     (1+ depth))
    (insert "\n")))

(defun difftron--insert-hierarchy
    (items hierarchy depth)
  "Insert ITEMS under HIERARCHY starting at DEPTH."
  (pcase (car hierarchy)
    ('file
     (dolist (group (difftron--group-items-by-file items))
       (difftron--insert-file-group
        (car group)
        (cdr group)
        depth
        (cdr hierarchy))))
    ('kind
     (dolist (group (difftron--group-items-by-kind items))
       (difftron--insert-kind-group
        (car group)
        (cdr group)
        depth
        (cdr hierarchy))))
    (_
     (dolist (item items)
       (difftron--insert-item item depth)))))

(defun difftron--effective-hierarchy ()
  "Return the active hierarchy."
  difftron--hierarchy)

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
         (difftron--insert-structured-diff item))
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

(defun difftron--insert-structured-diff (item)
  "Insert structured diff for ITEM using Emacs layout and faces."
  (let ((rows (plist-get (plist-get item :diff) :rows)))
    (if rows
        (let
            (
             (column-width (difftron--modified-column-width))
             (fill-flags (difftron--structured-fill-flags rows)))
          (cl-mapc
           (lambda (row fill)
             (difftron--insert-structured-diff-row
              item
              row
              column-width
              fill))
           rows
           fill-flags))
      (insert "No diff output.\n"))))

(defun difftron--insert-structured-diff-row
    (item row column-width fill)
  "Insert one structured diff ROW for ITEM using COLUMN-WIDTH per side."
  (difftron--insert-structured-side
   (plist-get row :left)
   'left
   column-width
   (difftron--structured-side-source item 'lhs)
   (plist-get fill :left))
  (insert " | ")
  (difftron--insert-structured-side
   (plist-get row :right)
   'right
   column-width
   (difftron--structured-side-source item 'rhs)
   (plist-get fill :right))
  (insert "\n"))

(defun difftron--insert-structured-side
    (side side-name column-width source fill)
  "Insert SIDE for SIDE-NAME using SOURCE, truncated to COLUMN-WIDTH.
FILL controls whether optional trailing padding uses the side's refine face."
  (if side
      (let*
          (
           (side-column (current-column))
           (face (difftron--side-face side-name))
           (side-source
            (plist-put
             (copy-sequence source)
             :row-line
             (plist-get side :line_number))))
        (difftron--insert-structured-segments
         (plist-get side :segments)
         side-name
         face
         column-width
         side-source
         side-column)
        (when
            (or (eq side-name 'left)
                fill)
          (difftron--insert-structured-padding
           (max
            0
            (- column-width
               (- (current-column) side-column)))
           face
           (and fill
                (difftron--side-refine-face side-name))
           side-source
           side-column)))
    (when (eq side-name 'left)
      (insert (make-string column-width ?\s)))))

(defun difftron--structured-fill-flags (rows)
  "Return per-side trailing fill flags for structured diff ROWS."
  (let
      (
       block
       result)
    (cl-labels
        (
         (flush-block
           ()
           (when block
             (setq result
                   (nconc
                    result
                    (difftron--structured-block-fill-flags
                     (nreverse block))))
             (setq block nil))))
      (dolist (row rows)
        (if (difftron--structured-row-changed-p row)
            (push row block)
          (flush-block)
          (setq result
                (nconc result (list (list :left nil :right nil))))))
      (flush-block))
    result))

(defun difftron--structured-block-fill-flags (rows)
  "Return per-side trailing fill flags for one changed block ROWS."
  (let
      (
       (fill-block
        (and difftron-fill-multiline-change-whitespace
             (> (length rows) 1)
             (difftron--structured-block-structural-p rows))))
    (mapcar
     (lambda (row)
       (if fill-block
           (list
            :left
            (difftron--structured-side-fill-p row 'left)
            :right
            (difftron--structured-side-fill-p row 'right))
         (list :left nil :right nil)))
     rows)))

(defun difftron--structured-row-changed-p (row)
  "Return non-nil when ROW is not unchanged."
  (not (equal (plist-get row :kind) "unchanged")))

(defun difftron--structured-block-structural-p (rows)
  "Return non-nil when changed ROWS contain block-style edits."
  (cl-some
   (lambda (row)
     (or
      (member (plist-get row :kind) '("novel_left" "novel_right"))
      (difftron--structured-side-all-novel-p (plist-get row :left))
      (difftron--structured-side-all-novel-p (plist-get row :right))))
   rows))

(defun difftron--structured-side-fill-p (row side-name)
  "Return non-nil when SIDE-NAME of ROW should fill trailing whitespace."
  (pcase (plist-get row :kind)
    ("novel_left"
     (and
      (eq side-name 'left)
      (difftron--structured-side-all-novel-p (plist-get row :left))))
    ("novel_right"
     (and
      (eq side-name 'right)
      (difftron--structured-side-all-novel-p (plist-get row :right))))
    ((or "replaced_code" "replaced_comment" "replaced_string")
     (difftron--structured-side-all-novel-p
      (plist-get
       row
       (pcase side-name
         ('left :left)
         (_ :right)))))
    (_ nil)))

(defun difftron--structured-side-all-novel-p (side)
  "Return non-nil when every segment in SIDE is novel."
  (when-let ((segments (plist-get side :segments)))
    (cl-every
     (lambda (segment)
       (equal (plist-get segment :kind) "novel"))
     segments)))

(defun difftron--structured-side-source (item side)
  "Return source metadata for SIDE of structured diff ITEM."
  (list
   :side side
   :entity
   (or
    (pcase side
      ('lhs (plist-get item :lhs))
      (_ (plist-get item :rhs)))
    (plist-get item :entity))))

(defun difftron--insert-structured-segments
    (segments side-name face remaining-width source side-column)
  "Insert SEGMENTS for SIDE-NAME with FACE and SOURCE metadata.
Insert at most REMAINING-WIDTH columns, starting at SIDE-COLUMN."
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
            (difftron--add-source-properties
             start
             (point)
             source
             side-column)
            (when refine-face
              (difftron--add-refine-overlay
               start
               (point)
               refine-face))
            (setq remaining (- remaining (string-width text)))))))))

(defun difftron--insert-structured-padding
    (width face refine-face source side-column)
  "Insert WIDTH spaces with FACE, REFINE-FACE, SOURCE, and SIDE-COLUMN metadata."
  (when (> width 0)
    (let
        (
         (start (point))
         (padding (make-string width ?\s)))
      (difftron--insert-diff-text padding face)
      (difftron--add-source-properties start (point) source side-column)
      (when refine-face
        (difftron--add-refine-overlay start (point) refine-face)))))

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
    ("novel" (difftron--side-refine-face side-name))
    (_ nil)))

(defun difftron--side-refine-face (side-name)
  "Return the refinement face for SIDE-NAME."
  (pcase side-name
    ('left 'diff-refine-removed)
    (_ 'diff-refine-added)))

(defun difftron--add-refine-overlay (start end face)
  "Add a Magit-style fine diff overlay from START to END using FACE."
  (let ((overlay (make-overlay start end nil t)))
    (overlay-put overlay 'diff-mode 'fine)
    (overlay-put overlay 'evaporate t)
    (overlay-put overlay 'face face)
    overlay))

(defun difftron--add-source-properties
    (start end source side-column)
  "Mark START to END as source text from SOURCE at SIDE-COLUMN."
  (add-text-properties
   start end
   (list
    'difftron-source-side
    (plist-get source :side)
    'difftron-source-entity
    (plist-get source :entity)
    'difftron-source-row-line
    (plist-get source :row-line)
    'difftron-source-side-column
    side-column
    'mouse-face
    'highlight
    'help-echo
    "RET visits this side at point in history")))

(defun difftron--modified-column-width ()
  "Return the per-side width for structured modified diffs."
  (max 24 (/ (- (difftron--current-display-width) 3) 2)))

(defun difftron--visit-item (item)
  "Visit the default source location for ITEM."
  (let*
      (
       (side (difftron--default-side-for-item item))
       (entity (difftron--entity-for-item-side item side)))
    (difftron--visit-entity-in-snapshot
     (difftron--snapshot-for-side side)
     entity)))

(defun difftron--source-location-at-point ()
  "Return the side-aware source location at point, if any."
  (when-let
      (
       (source-position (difftron--source-property-position))
       (side
        (get-text-property source-position 'difftron-source-side))
       (entity
        (get-text-property source-position 'difftron-source-entity)))
    (let*
        (
         (row-line
          (or
           (get-text-property
            source-position
            'difftron-source-row-line)
           1))
         (side-column
          (or
           (get-text-property
            source-position
            'difftron-source-side-column)
           (current-column)))
         (line
          (+ (or (plist-get entity :start_line) 1)
             row-line
             -1))
         (column
          (+ (if (= row-line 1)
                 (max 0 (1- (or (plist-get entity :start_col) 1)))
               0)
             (max 0 (- (current-column) side-column)))))
      (list
       :snapshot (difftron--snapshot-for-side side)
       :entity entity
       :line line
       :column column))))

(defun difftron--source-property-position ()
  "Return the position carrying source metadata at or before point."
  (or
   (and
    (get-text-property (point) 'difftron-source-side)
    (point))
   (and
    (> (point) (point-min))
    (get-text-property (1- (point)) 'difftron-source-side)
    (1- (point)))))

(defun difftron--visit-source-location (source)
  "Visit side-aware SOURCE."
  (difftron--visit-entity-in-snapshot
   (plist-get source :snapshot)
   (plist-get source :entity)
   (plist-get source :line)
   (plist-get source :column)))

(defun difftron--visit-entity-in-snapshot
    (snapshot entity &optional line column)
  "Visit ENTITY in SNAPSHOT at LINE and COLUMN."
  (let
      (
       (line (or line (plist-get entity :start_line) 1))
       (column
        (or column
            (max 0 (1- (or (plist-get entity :start_col) 1))))))
    (pcase (plist-get snapshot :kind)
      ("git_revision"
       (difftron--visit-git-entity snapshot entity line column))
      ((or "directory" "file")
       (difftron--visit-filesystem-entity entity line column))
      (_
       (difftron--visit-filesystem-entity entity line column)))))

(defun difftron--visit-git-entity
    (snapshot entity line column)
  "Visit ENTITY from Git SNAPSHOT at LINE and COLUMN."
  (require 'magit-diff)
  (let*
      (
       (rev
        (or (plist-get snapshot :rev)
            (user-error "Git revision snapshot has no revision")))
       (file
        (or (plist-get entity :snapshot_path)
            (user-error "Entity has no snapshot path")))
       (default-directory
        (or (plist-get snapshot :root) default-directory))
       (buffer (magit-find-file-noselect rev file))
       (pos (difftron--buffer-position buffer line column)))
    (pop-to-buffer-same-window buffer)
    (magit-diff-visit-file--setup buffer pos)
    buffer))

(defun difftron--visit-filesystem-entity
    (entity line column)
  "Visit filesystem ENTITY at LINE and COLUMN."
  (let*
      (
       (file
        (or (plist-get entity :file_path)
            (plist-get entity :snapshot_path)
            (user-error "Entity has no file path")))
       (buffer (find-file-noselect file))
       (pos (difftron--buffer-position buffer line column)))
    (pop-to-buffer-same-window buffer)
    (with-current-buffer buffer
      (goto-char pos))
    buffer))

(defun difftron--buffer-position
    (buffer line column)
  "Return position in BUFFER at LINE and COLUMN."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (goto-char (point-min))
      (forward-line (max 0 (1- line)))
      (move-to-column (max 0 column))
      (point))))

(defun difftron--snapshot-for-side (side)
  "Return the payload snapshot for SIDE."
  (pcase side
    ('lhs (plist-get difftron--payload :lhs))
    ('rhs (plist-get difftron--payload :rhs))
    (_ (plist-get difftron--payload :snapshot))))

(defun difftron--default-side-for-item (item)
  "Return the default source side for ITEM."
  (pcase (plist-get item :status)
    ((or 'deleted 'moved-from 'moved-modified-from) 'lhs)
    (_ 'rhs)))

(defun difftron--entity-for-item-side (item side)
  "Return ITEM's entity for SIDE."
  (or
   (pcase side
     ('lhs (plist-get item :lhs))
     ('rhs (plist-get item :rhs)))
   (plist-get item :entity)))

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
  (let
      (
       (lhs (plist-get change :lhs))
       (rhs (plist-get change :rhs)))
    (list
     :kind (plist-get rhs :kind)
     :status 'modified
     :lhs lhs
     :rhs rhs
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
      :summary
      (format "  %s moved to %s"
              (plist-get lhs :name)
              (plist-get rhs :name)))
     (list
      :kind (plist-get rhs :kind)
      :status 'moved-to
      :entity rhs
      :summary
      (format "  %s moved from %s"
              (plist-get rhs :name)
              (plist-get lhs :name))))))

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
      (format "M %s moved to %s"
              (plist-get lhs :name)
              (plist-get rhs :name)))
     (list
      :kind (plist-get rhs :kind)
      :status 'moved-modified-to
      :entity rhs
      :summary
      (format "M %s moved from %s"
              (plist-get rhs :name)
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
  "Insert ITEMS using the current hierarchy."
  (if items
      (difftron--insert-hierarchy
       items
       (difftron--effective-hierarchy)
       0)
    (insert "No entities\n")))

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
