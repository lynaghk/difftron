;;; rust-dive-magit.el --- View rust_dive output from Emacs  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Dedicated Emacs integration for the rust_dive CLI.  The main entrypoint is
;; `rust-dive-magit-diff', which shells out to `rust_dive diff --format json'
;; and renders the result in a foldable buffer.

;;; Code:

(require 'ansi-color)
(require 'button)
(require 'cl-lib)
(require 'json)
(require 'magit-section)
(require 'seq)
(require 'subr-x)
(require 'transient)

(defgroup rust-dive-magit nil
  "Emacs integration for the rust_dive CLI."
  :group 'tools)

(defcustom rust-dive-magit-executable "rust_dive"
  "Path to the rust_dive executable."
  :type 'file)

(defcustom rust-dive-magit-buffer-name "*rust-dive*"
  "Name of the rust_dive results buffer."
  :type 'string)

(defcustom rust-dive-magit-default-grouping 'kind
  "Default top-level grouping for Rust Dive buffers."
  :type '(choice (const :tag "Entity then file" kind)
                 (const :tag "File then entity" file)))

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

(defconst rust-dive-magit--kind-order
  '("struct" "enum" "union" "trait" "type_alias" "function" "impl" "module"))

(defvar-local rust-dive-magit--command-args nil)
(defvar-local rust-dive-magit--default-directory nil)
(defvar-local rust-dive-magit--payload nil)
(defvar-local rust-dive-magit--grouping nil
  "Current grouping mode for the Rust Dive buffer.")

(define-derived-mode rust-dive-magit-mode magit-section-mode "Rust-Dive"
  "Major mode for rust_dive results."
  (setq-local truncate-lines t))

(transient-define-prefix rust-dive-magit-dispatch ()
  "Show commands for `rust-dive-magit-mode'."
  [["Rust Dive"
    ("g" "Refresh" rust-dive-magit-refresh)
    ("f" "Cycle grouping" rust-dive-magit-cycle-grouping)
    ("q" "Quit buffer" quit-window)
    ("TAB" "Toggle section" magit-section-toggle)
    ("RET" "Visit thing" rust-dive-magit-visit-thing)]
   ["Visibility"
    ("<backtab>" "Cycle all" magit-section-cycle-global)
    ("1" "Level 1" magit-section-show-level-1)
    ("2" "Level 2" magit-section-show-level-2)
    ("3" "Level 3" magit-section-show-level-3)]
   ["Movement"
    ("n" "Next section" magit-section-forward)
    ("p" "Previous section" magit-section-backward)
    ("M-n" "Next sibling" magit-section-forward-sibling)
    ("M-p" "Previous sibling" magit-section-backward-sibling)]])

(defun rust-dive-magit-diff-dwim ()
  "Run `rust_dive diff' using the current Magit diff context."
  (interactive)
  (require 'magit-diff)
  (pcase-let* ((default-directory (rust-dive-magit--repo-root))
               (`(,_args ,paths) (magit-diff-arguments))
               (`(,lhs ,rhs) (rust-dive-magit--dwim-endpoints
                              (ignore-errors (magit-diff--dwim))
                              default-directory)))
    (rust-dive-magit-diff lhs rhs paths)))

(defun rust-dive-magit-diff (lhs rhs &optional paths)
  "Run `rust_dive diff' for LHS and RHS and display the results.
When called interactively, default to comparing `HEAD' against the current
working tree rooted at the current repository."
  (interactive
   (let* ((repo-root (rust-dive-magit--repo-root))
          (default-lhs "HEAD")
          (default-rhs repo-root)
          (lhs (read-string "Left snapshot/rev: " default-lhs))
          (rhs (read-string "Right snapshot/rev: " default-rhs))
          (path-input (read-string "Filter paths (comma-separated, optional): ")))
     (list lhs rhs (rust-dive-magit--split-paths path-input))))
  (let* ((default-directory (rust-dive-magit--repo-root))
         (args (append (list "diff" lhs rhs
                             "--format" "json"
                             "--width" (number-to-string
                                        (rust-dive-magit--current-display-width)))
                       (cl-mapcan (lambda (path) (list "--path" path)) paths)))
         (payload (rust-dive-magit--run-command default-directory args)))
    (rust-dive-magit--display-buffer default-directory args payload)))

(defun rust-dive-magit-refresh ()
  "Re-run the last rust_dive command in the current buffer."
  (interactive)
  (unless (and rust-dive-magit--command-args rust-dive-magit--default-directory)
    (user-error "No rust_dive command is associated with this buffer"))
  (let ((payload (rust-dive-magit--run-command
                  rust-dive-magit--default-directory
                  rust-dive-magit--command-args)))
    (rust-dive-magit--display-buffer
     rust-dive-magit--default-directory
     rust-dive-magit--command-args
     payload)))

(defun rust-dive-magit-cycle-grouping ()
  "Cycle the Rust Dive grouping mode for the current buffer."
  (interactive)
  (unless rust-dive-magit--payload
    (user-error "No rust_dive payload is associated with this buffer"))
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
    (magit-section-show-level-1)))

(defun rust-dive-magit-visit-thing ()
  "Visit the entity at point or activate a button."
  (interactive)
  (if-let* ((section (rust-dive-magit--entity-section-at-point))
            (entity (plist-get (oref section value) :entity)))
      (rust-dive-magit--visit-entity entity)
    (if (button-at (point))
        (push-button)
      (magit-section-toggle (magit-current-section)))))

(defun rust-dive-magit--display-buffer (default-directory args payload)
  "Render PAYLOAD in the dedicated buffer.
DEFAULT-DIRECTORY and ARGS are stored to support refresh."
  (let ((buffer (get-buffer-create rust-dive-magit-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (rust-dive-magit-mode)
        (setq rust-dive-magit--grouping rust-dive-magit-default-grouping)
        (setq rust-dive-magit--default-directory default-directory)
        (setq rust-dive-magit--command-args args)
        (setq rust-dive-magit--payload payload)
        (rust-dive-magit--insert-payload payload)
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(defun rust-dive-magit--insert-payload (payload)
  "Insert PAYLOAD into the current buffer."
  (magit-insert-section (rust-dive-root)
    (pcase (plist-get payload :command)
      ("diff" (rust-dive-magit--insert-diff payload))
      ("list" (rust-dive-magit--insert-list payload))
      (_ (insert (format "Unsupported rust_dive command: %S" payload))))))

(defun rust-dive-magit--insert-list (payload)
  "Insert a list-mode PAYLOAD into the current buffer."
  (rust-dive-magit--insert-title
   (format "rust_dive list %s" (plist-get (plist-get payload :snapshot) :label)))
  (rust-dive-magit--insert-items
   (mapcar #'rust-dive-magit--list-entity->item
           (plist-get payload :entities))))

(defun rust-dive-magit--insert-diff (payload)
  "Insert a diff PAYLOAD into the current buffer."
  (let ((lhs (plist-get payload :lhs))
        (rhs (plist-get payload :rhs)))
    (rust-dive-magit--insert-title
     (format "rust_dive diff %s -> %s"
             (plist-get lhs :label)
             (plist-get rhs :label)))
    (rust-dive-magit--insert-items
     (rust-dive-magit--diff-items payload))))

(defun rust-dive-magit--insert-title (title)
  "Insert TITLE at the top of the current buffer."
  (insert (propertize title 'font-lock-face 'magit-section-heading))
  (insert "\n")
  (insert (propertize
           (format "Grouping: %s"
                   (pcase rust-dive-magit--grouping
                     ('file "File -> Entity")
                     (_ "Entity -> File")))
           'font-lock-face 'magit-section-secondary-heading))
  (insert "\n\n"))

(defun rust-dive-magit--insert-kind-groups (items)
  "Insert ITEMS grouped by entity kind."
  (let ((groups (rust-dive-magit--group-items-by-kind items)))
    (if groups
        (dolist (group groups)
          (rust-dive-magit--insert-kind-group (car group) (cdr group)))
      (insert "No entities\n"))))

(defun rust-dive-magit--insert-file-groups (items)
  "Insert ITEMS grouped by file."
  (let ((groups (rust-dive-magit--group-items-by-file items)))
    (if groups
        (dolist (group groups)
          (rust-dive-magit--insert-file-group (car group) (cdr group)))
      (insert "No entities\n"))))

(defun rust-dive-magit--insert-kind-group (kind items)
  "Insert a kind heading for KIND and its ITEMS."
  (magit-insert-section (rust-dive-kind kind t)
    (magit-insert-heading
      (format "%s (%d)" (rust-dive-magit--kind-label kind) (length items)))
    (dolist (group (rust-dive-magit--group-items-by-file items))
      (rust-dive-magit--insert-file-group (car group) (cdr group)))
    (insert "\n")))

(defun rust-dive-magit--insert-file-group (file items)
  "Insert a file heading for FILE and its ITEMS."
  (magit-insert-section (rust-dive-file file t)
    (magit-insert-heading
      (format "%s (%d)" file (length items)))
    (dolist (item items)
      (rust-dive-magit--insert-item item))
    (insert "\n")))

(defun rust-dive-magit--insert-item (item)
  "Insert ITEM as a foldable second-level heading."
  (let ((entity (plist-get item :entity)))
    (magit-insert-section (rust-dive-entity item t)
      (magit-insert-heading
        (propertize (plist-get item :summary)
                    'font-lock-face 'magit-diff-file-heading))
      (add-text-properties
       (oref magit-insert-section--current start)
       (oref magit-insert-section--current content)
       '(mouse-face highlight
         help-echo "RET visits source, TAB toggles section"))
    (insert "Location: ")
    (rust-dive-magit--insert-location-button entity)
    (insert "\n")
    (pcase (plist-get item :status)
      ('modified
       (rust-dive-magit--insert-ansi-block
        (or (plist-get item :difftastic-display) "")))
      (_
       (rust-dive-magit--insert-faced-block
        (format "%s\n\n" (plist-get entity :rendered_summary))
        (rust-dive-magit--status-face (plist-get item :status)))
       (when-let ((source (plist-get entity :source_text)))
         (rust-dive-magit--insert-faced-block
          source
          (rust-dive-magit--status-face (plist-get item :status)))
         (unless (string-suffix-p "\n" source)
           (insert "\n")))))
    (unless (eq (char-before) ?\n)
      (insert "\n"))
      (insert "\n"))))

(defun rust-dive-magit--insert-ansi-block (text)
  "Insert TEXT and apply ANSI color escapes."
  (let ((start (point)))
    (if (string-empty-p text)
        (insert "No difftastic output.\n")
      (insert text)
      (unless (string-suffix-p "\n" text)
        (insert "\n")))
    (ansi-color-apply-on-region start (point))))

(defun rust-dive-magit--insert-faced-block (text face)
  "Insert TEXT with FACE."
  (insert (propertize text 'font-lock-face face)))

(defun rust-dive-magit--insert-location-button (entity)
  "Insert a button for ENTITY's source location."
  (let ((label (format "%s:%s"
                       (plist-get entity :relative_path)
                       (plist-get entity :start_line))))
    (insert-text-button
     label
     'follow-link t
     'help-echo "Visit source location"
     'action (lambda (_button)
               (rust-dive-magit--visit-entity entity)))))

(defun rust-dive-magit--visit-entity (entity)
  "Visit ENTITY in another buffer."
  (let ((file (plist-get entity :file_path))
        (line (plist-get entity :start_line))
        (column (plist-get entity :start_col)))
    (find-file-other-window file)
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column (max 0 (1- column)))))

(defun rust-dive-magit--diff-items (payload)
  "Flatten diff PAYLOAD into display items."
  (append
   (mapcar (lambda (entity)
             (rust-dive-magit--item-from-entity 'added entity))
           (plist-get payload :added))
   (mapcar (lambda (entity)
             (rust-dive-magit--item-from-entity 'deleted entity))
           (plist-get payload :deleted))
   (mapcar #'rust-dive-magit--item-from-change
           (plist-get payload :modified))))

(defun rust-dive-magit--item-from-change (change)
  "Build a display item from modified CHANGE."
  (let ((rhs (plist-get change :rhs)))
    (list :kind (plist-get rhs :kind)
          :status 'modified
          :entity rhs
          :summary (format "M %s" (plist-get rhs :name))
          :difftastic-display (plist-get change :difftastic_display))))

(defun rust-dive-magit--item-from-entity (status entity)
  "Build a display item from ENTITY with STATUS."
  (list :kind (plist-get entity :kind)
        :status status
        :entity entity
        :summary (format "%s %s"
                         (pcase status
                           ('added "+")
                           ('deleted "-")
                           (_ " "))
                         (plist-get entity :name))))

(defun rust-dive-magit--list-entity->item (entity)
  "Build a display item from a list-mode ENTITY."
  (list :kind (plist-get entity :kind)
        :status 'present
        :entity entity
        :summary (plist-get entity :name)))

(defun rust-dive-magit--group-items-by-kind (items)
  "Group ITEMS by entity kind in display order."
  (let ((table (make-hash-table :test #'equal))
        kinds)
    (dolist (item items)
      (let ((kind (plist-get item :kind)))
        (unless (gethash kind table)
          (push kind kinds)
          (puthash kind nil table))
        (puthash kind (cons item (gethash kind table)) table)))
    (mapcar
     (lambda (kind)
       (cons kind
             (nreverse (gethash kind table))))
     (sort kinds #'rust-dive-magit--kind-lessp))))

(defun rust-dive-magit--group-items-by-file (items)
  "Group ITEMS by relative path."
  (let ((table (make-hash-table :test #'equal))
        files)
    (dolist (item items)
      (let ((file (plist-get (plist-get item :entity) :relative_path)))
        (unless (gethash file table)
          (push file files)
          (puthash file nil table))
        (puthash file (cons item (gethash file table)) table)))
    (mapcar
     (lambda (file)
       (cons file
             (sort (nreverse (gethash file table))
                   #'rust-dive-magit--item-lessp)))
     (sort files #'string<))))

(defun rust-dive-magit--item-lessp (lhs rhs)
  "Return non-nil when LHS should sort before RHS."
  (let ((lhs-rank (rust-dive-magit--status-rank (plist-get lhs :status)))
        (rhs-rank (rust-dive-magit--status-rank (plist-get rhs :status))))
    (if (/= lhs-rank rhs-rank)
        (< lhs-rank rhs-rank)
      (string< (plist-get lhs :summary)
               (plist-get rhs :summary)))))

(defun rust-dive-magit--kind-lessp (lhs rhs)
  "Return non-nil when kind LHS should sort before RHS."
  (< (rust-dive-magit--kind-rank lhs)
     (rust-dive-magit--kind-rank rhs)))

(defun rust-dive-magit--kind-rank (kind)
  "Return the display rank for KIND."
  (or (cl-position kind rust-dive-magit--kind-order :test #'equal)
      (length rust-dive-magit--kind-order)))

(defun rust-dive-magit--kind-label (kind)
  "Return the user-facing heading label for KIND."
  (pcase kind
    ("struct" "Structs")
    ("enum" "Enums")
    ("union" "Unions")
    ("trait" "Traits")
    ("type_alias" "Type Aliases")
    ("function" "Functions")
    ("impl" "Impls")
    ("module" "Modules")
    (_ (capitalize kind))))

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

(defun rust-dive-magit--run-command (default-directory args)
  "Run rust_dive with ARGS from DEFAULT-DIRECTORY and parse JSON output."
  (with-temp-buffer
    (let ((default-directory default-directory)
          (stderr-file (make-temp-file "rust-dive-stderr-")))
      (unwind-protect
          (let ((status (apply #'process-file
                               rust-dive-magit-executable
                               nil
                               (list (current-buffer) stderr-file)
                               nil
                               args)))
            (unless (eq status 0)
              (error "rust_dive failed: %s"
                     (string-trim
                      (with-temp-buffer
                        (insert-file-contents stderr-file)
                        (buffer-string)))))
            (goto-char (point-min))
            (json-parse-buffer :object-type 'plist :array-type 'list))
        (delete-file stderr-file)))))

(defun rust-dive-magit--repo-root ()
  "Return the repository root for the current buffer."
  (or (and (fboundp 'magit-toplevel)
           (ignore-errors (magit-toplevel)))
      (locate-dominating-file default-directory ".git")
      (user-error "Not inside a Git repository")))

(defun rust-dive-magit--dwim-endpoints (spec repo-root)
  "Return Rust Dive LHS and RHS endpoints from Magit SPEC in REPO-ROOT."
  (pcase spec
    ((or 'unstaged 'staged 'unmerged 'undefined)
     (list "HEAD" repo-root))
    (`(commit . ,rev)
     (list (format "%s^" rev) rev))
    (`(stash . ,rev)
     (list (format "%s^" rev) rev))
    ((pred stringp)
     (or (rust-dive-magit--range-endpoints spec)
         (list spec repo-root)))
    (_
     (list "HEAD" repo-root))))

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
    (while (and section
                (not (eq (oref section type) 'rust-dive-entity)))
      (setq section (oref section parent)))
    section))

(defun rust-dive-magit-register-magit-diff-suffix ()
  "Register Rust Dive in the `magit-diff' transient."
  (when (and (featurep 'magit-diff)
             (not (ignore-errors (transient-get-suffix 'magit-diff "D"))))
    (transient-append-suffix 'magit-diff "d"
      rust-dive-magit--magit-diff-suffix)))

(defun rust-dive-magit-unregister-magit-diff-suffix ()
  "Remove Rust Dive from the `magit-diff' transient."
  (when (and (featurep 'magit-diff)
             (ignore-errors (transient-get-suffix 'magit-diff "D")))
    (transient-remove-suffix 'magit-diff "D")))

(define-minor-mode rust-dive-magit-bindings-mode
  "Toggle Rust Dive bindings in Magit transients."
  :global t
  :group 'rust-dive-magit
  (if rust-dive-magit-bindings-mode
      (rust-dive-magit-register-magit-diff-suffix)
    (rust-dive-magit-unregister-magit-diff-suffix)))

(with-eval-after-load 'magit-diff
  (when rust-dive-magit-bindings-mode
    (rust-dive-magit-register-magit-diff-suffix)))

(provide 'rust-dive-magit)

;;; rust-dive-magit.el ends here
