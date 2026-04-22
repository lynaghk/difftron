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
(require 'outline)
(require 'seq)
(require 'subr-x)

(defgroup rust-dive-magit nil
  "Emacs integration for the rust_dive CLI."
  :group 'tools)

(defcustom rust-dive-magit-executable "rust_dive"
  "Path to the rust_dive executable."
  :type 'file)

(defcustom rust-dive-magit-buffer-name "*rust-dive*"
  "Name of the rust_dive results buffer."
  :type 'string)

(defface rust-dive-magit-heading
  '((t :inherit bold))
  "Face used for rust_dive section headings."
  :group 'rust-dive-magit)

(defface rust-dive-magit-summary
  '((t :inherit default))
  "Face used for entity summary headings."
  :group 'rust-dive-magit)

(defvar rust-dive-magit-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'rust-dive-magit-refresh)
    (define-key map (kbd "RET") #'rust-dive-magit-visit-thing)
    (define-key map (kbd "<tab>") #'rust-dive-magit-toggle-section)
    (define-key map (kbd "TAB") #'rust-dive-magit-toggle-section)
    (define-key map (kbd "<backtab>") #'rust-dive-magit-cycle-buffer)
    map)
  "Keymap for `rust-dive-magit-mode'.")

(defconst rust-dive-magit--kind-order
  '("struct" "enum" "union" "trait" "type_alias" "function" "impl" "module"))

(defvar-local rust-dive-magit--command-args nil)
(defvar-local rust-dive-magit--default-directory nil)
(defvar-local rust-dive-magit--payload nil)

(define-derived-mode rust-dive-magit-mode special-mode "Rust-Dive"
  "Major mode for rust_dive results."
  (setq-local truncate-lines t)
  (setq-local outline-regexp "\\*+ ")
  (setq-local outline-level #'rust-dive-magit--outline-level)
  (outline-minor-mode 1))

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
         (args (append (list "diff" lhs rhs "--format" "json")
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

(defun rust-dive-magit-toggle-section ()
  "Toggle the outline section at point."
  (interactive)
  (if (fboundp 'outline-cycle)
      (outline-cycle)
    (save-excursion
      (outline-back-to-heading t)
      (outline-toggle-children))))

(defun rust-dive-magit-cycle-buffer ()
  "Cycle visibility for the entire buffer."
  (interactive)
  (if (fboundp 'outline-cycle-buffer)
      (outline-cycle-buffer)
    (outline-show-all)))

(defun rust-dive-magit-visit-thing ()
  "Visit the entity at point or activate a button."
  (interactive)
  (cond
   ((button-at (point))
    (push-button))
   ((get-text-property (point) 'rust-dive-entity)
    (rust-dive-magit--visit-entity
     (get-text-property (point) 'rust-dive-entity)))
   (t
    (rust-dive-magit-toggle-section))))

(defun rust-dive-magit--display-buffer (default-directory args payload)
  "Render PAYLOAD in the dedicated buffer.
DEFAULT-DIRECTORY and ARGS are stored to support refresh."
  (let ((buffer (get-buffer-create rust-dive-magit-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (rust-dive-magit-mode)
        (setq rust-dive-magit--default-directory default-directory)
        (setq rust-dive-magit--command-args args)
        (setq rust-dive-magit--payload payload)
        (rust-dive-magit--insert-payload payload)
        (rust-dive-magit--collapse-to-kind-headings)
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(defun rust-dive-magit--collapse-to-kind-headings ()
  "Collapse the buffer to the top-level kind headings."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward outline-regexp nil t)
      (goto-char (match-beginning 0))
      (outline-hide-sublevels 1))))

(defun rust-dive-magit--insert-payload (payload)
  "Insert PAYLOAD into the current buffer."
  (pcase (plist-get payload :command)
    ("diff" (rust-dive-magit--insert-diff payload))
    ("list" (rust-dive-magit--insert-list payload))
    (_ (insert (format "Unsupported rust_dive command: %S" payload)))))

(defun rust-dive-magit--insert-list (payload)
  "Insert a list-mode PAYLOAD into the current buffer."
  (rust-dive-magit--insert-title
   (format "rust_dive list %s" (plist-get (plist-get payload :snapshot) :label)))
  (rust-dive-magit--insert-kind-groups
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
    (rust-dive-magit--insert-kind-groups
     (rust-dive-magit--diff-items payload))))

(defun rust-dive-magit--insert-title (title)
  "Insert TITLE at the top of the current buffer."
  (insert (propertize title 'face 'rust-dive-magit-heading))
  (insert "\n\n"))

(defun rust-dive-magit--insert-kind-groups (items)
  "Insert ITEMS grouped by entity kind."
  (let ((groups (rust-dive-magit--group-items-by-kind items)))
    (if groups
        (dolist (group groups)
          (rust-dive-magit--insert-kind-group (car group) (cdr group)))
      (insert "No entities\n"))))

(defun rust-dive-magit--insert-kind-group (kind items)
  "Insert a kind heading for KIND and its ITEMS."
  (insert (propertize
           (format "* %s (%d)\n" (rust-dive-magit--kind-label kind) (length items))
           'face 'rust-dive-magit-heading))
  (dolist (item items)
    (rust-dive-magit--insert-item item))
  (insert "\n"))

(defun rust-dive-magit--insert-item (item)
  "Insert ITEM as a foldable second-level heading."
  (let* ((entity (plist-get item :entity))
         (heading-start (point)))
    (insert (propertize
             (format "** %s\n" (plist-get item :summary))
             'face 'rust-dive-magit-summary))
    (add-text-properties
     heading-start (1- (point))
     `(rust-dive-entity ,entity
       mouse-face highlight
       help-echo "RET visits source, TAB toggles section"))
    (insert "Location: ")
    (rust-dive-magit--insert-location-button entity)
    (insert "\n")
    (pcase (plist-get item :status)
      ('modified
       (rust-dive-magit--insert-ansi-block
        (or (plist-get item :difftastic-display) "")))
      (_
       (insert (format "%s\n\n" (plist-get entity :rendered_summary)))
       (when-let ((source (plist-get entity :source_text)))
         (insert source)
         (unless (string-suffix-p "\n" source)
           (insert "\n")))))
    (unless (eq (char-before) ?\n)
      (insert "\n"))
    (insert "\n")))

(defun rust-dive-magit--insert-ansi-block (text)
  "Insert TEXT and apply ANSI color escapes."
  (let ((start (point)))
    (if (string-empty-p text)
        (insert "No difftastic output.\n")
      (insert text)
      (unless (string-suffix-p "\n" text)
        (insert "\n")))
    (ansi-color-apply-on-region start (point))))

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
             (sort (nreverse (gethash kind table))
                   #'rust-dive-magit--item-lessp)))
     (sort kinds #'rust-dive-magit--kind-lessp))))

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

(defun rust-dive-magit--outline-level ()
  "Return the outline level at point."
  (- (match-end 0) (match-beginning 0) 1))

(defun rust-dive-magit--split-paths (input)
  "Split comma-separated INPUT into normalized path filters."
  (if (string-empty-p input)
      nil
    (seq-filter
     (lambda (item) (not (string-empty-p item)))
     (mapcar #'string-trim (split-string input "," t)))))

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

(provide 'rust-dive-magit)

;;; rust-dive-magit.el ends here
