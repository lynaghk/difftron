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
(require 'json)
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

(defcustom rust-dive-magit-default-grouping 'kind
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
      ("q" "Quit buffer" quit-window)
      ("TAB" "Toggle section" magit-section-toggle)
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
  (insert "\n"))

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
            (insert
              (propertize source
                'font-lock-face
                (rust-dive-magit--status-face
                  (plist-get item :status))))
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
    (let ((start (point)))
      (rust-dive-magit--insert-structured-segments
        (plist-get side :segments)
        side-name
        column-width)
      (when (eq side-name 'left)
        (insert
          (make-string
            (max 0 (- column-width (- (point) start)))
            ?\s))))
    (when (eq side-name 'left)
      (insert (make-string column-width ?\s)))))

(defun rust-dive-magit--insert-structured-segments
  (segments side-name remaining-width)
  "Insert SEGMENTS for SIDE-NAME within REMAINING-WIDTH columns."
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
            (face
              (rust-dive-magit--segment-face
                side-name
                (plist-get segment :kind))))
          (unless (string-empty-p text)
            (insert (propertize text 'font-lock-face face))
            (setq remaining (- remaining (string-width text)))))))))

(defun rust-dive-magit--segment-face (side-name kind)
  "Return the face for segment KIND on SIDE-NAME."
  (pcase kind
    ("novel"
      (pcase side-name
        ('left 'magit-diff-removed)
        (_ 'magit-diff-added)))
    (_ 'default)))

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
    ('added 1)
    ('deleted 2)
    (_ 3)))

(defun rust-dive-magit--status-face (status)
  "Return the Magit face for STATUS."
  (pcase status
    ('added 'magit-diff-added)
    ('deleted 'magit-diff-removed)
    (_ 'default)))

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
