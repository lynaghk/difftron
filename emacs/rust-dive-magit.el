;;; rust-dive-magit.el --- View rust_dive output from Emacs  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Dedicated Emacs integration for the rust_dive CLI.  The main entrypoint is
;; `rust-dive-magit-diff', which shells out to `rust_dive diff --format json'
;; and renders the result in a navigation-focused buffer.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'json)
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
  "Face used for top-level rust_dive headings."
  :group 'rust-dive-magit)

(defvar rust-dive-magit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'rust-dive-magit-refresh)
    (define-key map (kbd "RET") #'push-button)
    map)
  "Keymap for `rust-dive-magit-mode'.")

(defvar-local rust-dive-magit--command-args nil)
(defvar-local rust-dive-magit--default-directory nil)
(defvar-local rust-dive-magit--payload nil)

(define-derived-mode rust-dive-magit-mode special-mode "Rust-Dive"
  "Major mode for rust_dive results."
  (setq-local truncate-lines t))

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
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

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
  (rust-dive-magit--insert-entity-group "Entities" (plist-get payload :entities)))

(defun rust-dive-magit--insert-diff (payload)
  "Insert a diff PAYLOAD into the current buffer."
  (let ((lhs (plist-get payload :lhs))
        (rhs (plist-get payload :rhs)))
    (rust-dive-magit--insert-title
     (format "rust_dive diff %s -> %s"
             (plist-get lhs :label)
             (plist-get rhs :label)))
    (rust-dive-magit--insert-entity-group "Added" (plist-get payload :added))
    (rust-dive-magit--insert-entity-group "Deleted" (plist-get payload :deleted))
    (rust-dive-magit--insert-modified-group "Modified" (plist-get payload :modified))))

(defun rust-dive-magit--insert-title (title)
  "Insert TITLE at the top of the current buffer."
  (insert (propertize title 'face 'rust-dive-magit-heading))
  (insert "\n\n"))

(defun rust-dive-magit--insert-entity-group (title entities)
  "Insert TITLE and ENTITIES grouped by file."
  (insert (propertize title 'face 'rust-dive-magit-heading))
  (insert "\n")
  (if entities
      (dolist (group (rust-dive-magit--group-by-path entities))
        (insert (format "  %s\n" (car group)))
        (dolist (entity (cdr group))
          (rust-dive-magit--insert-entity-line entity "    ")))
    (insert "  none\n"))
  (insert "\n"))

(defun rust-dive-magit--insert-modified-group (title changes)
  "Insert TITLE and CHANGES grouped by file."
  (insert (propertize title 'face 'rust-dive-magit-heading))
  (insert "\n")
  (if changes
      (dolist (group (rust-dive-magit--group-by-path changes))
        (insert (format "  %s\n" (car group)))
        (dolist (change (cdr group))
          (rust-dive-magit--insert-modified-line change)))
    (insert "  none\n"))
  (insert "\n"))

(defun rust-dive-magit--insert-entity-line (entity prefix)
  "Insert ENTITY with PREFIX."
  (insert prefix)
  (rust-dive-magit--insert-location-button entity)
  (insert (format "  [%s] %s\n"
                  (plist-get entity :kind)
                  (plist-get entity :rendered_summary))))

(defun rust-dive-magit--insert-modified-line (change)
  "Insert CHANGE."
  (let ((lhs (plist-get change :lhs))
        (rhs (plist-get change :rhs)))
    (insert "    ")
    (rust-dive-magit--insert-location-button rhs)
    (insert (format "  [%s] %s\n"
                    (plist-get rhs :kind)
                    (plist-get rhs :name)))
    (insert (format "      before: %s\n" (plist-get lhs :rendered_summary)))
    (insert (format "      after:  %s\n" (plist-get rhs :rendered_summary)))))

(defun rust-dive-magit--insert-location-button (entity)
  "Insert a button for ENTITY's location."
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

(defun rust-dive-magit--group-by-path (items)
  "Group ITEMS by their relative path."
  (let ((table (make-hash-table :test #'equal))
        ordered)
    (dolist (item items)
      (let* ((entity (if (plist-get item :lhs) (plist-get item :lhs) item))
             (path (or (plist-get item :path)
                       (plist-get entity :relative_path)
                       "<unknown>")))
        (unless (gethash path table)
          (push path ordered)
          (puthash path nil table))
        (puthash path (append (gethash path table) (list item)) table)))
    (mapcar (lambda (path) (cons path (gethash path table)))
            (sort ordered #'string<))))

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
