;;; rust-dive-magit-lint.el --- Formatting and lint helpers for rust-dive-magit -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Batch helpers shared by the repo's Emacs formatting and lint scripts.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst rust-dive-magit-lint--private-symbol-allowlist nil
  "Private symbols intentionally exempt from unused-symbol checks.")

(defun rust-dive-magit-lint--repo-root ()
  "Return the repository root for the current lint session."
  (or (locate-dominating-file default-directory "emacs")
      (error "Could not locate repo root from %s" default-directory)))

(defun rust-dive-magit-lint--owned-elisp-files ()
  "Return repo-owned Emacs Lisp files covered by formatting and linting."
  (append
   (directory-files
    (expand-file-name "emacs" (rust-dive-magit-lint--repo-root))
    t
    "\\.el\\'")
   (directory-files
    (expand-file-name "emacs/test-config"
		      (rust-dive-magit-lint--repo-root))
    t "\\.el\\'")))

(defun rust-dive-magit-lint--checkdoc-files (files)
  "Return the subset of FILES that should be checked by `checkdoc'."
  (seq-remove
   (lambda (file)
     (or (string-suffix-p "-tests.el" file)
         (string-match-p "/test-config/" file)))
   files))

(defun rust-dive-magit-lint--message (format-string &rest args)
  "Print a lint FORMAT-STRING with ARGS to stderr."
  (princ (apply #'format (concat format-string "\n") args)
	 #'external-debugging-output))

(defun rust-dive-magit-lint--read-forms (file)
  "Read all top-level forms from FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let
	(
         forms
         form)
      (condition-case nil
          (while t
            (setq form (read (current-buffer)))
            (push form forms))
        (end-of-file
         nil))
      (nreverse forms))))

(defun rust-dive-magit-lint--private-definition-symbol (form)
  "Return the private symbol defined by FORM, or nil."
  (when
      (and (consp form) (memq (car form) '(defun defmacro defsubst)))
    (let ((symbol (nth 1 form)))
      (when
          (and (symbolp symbol)
               (string-prefix-p "rust-dive-magit--" (symbol-name symbol)))
        symbol))))

(defun rust-dive-magit-lint--form-references-symbol-p (form symbol)
  "Return non-nil when FORM references SYMBOL."
  (cond
   ((symbolp form)
    (eq form symbol))
   ((consp form)
    (or
     (rust-dive-magit-lint--form-references-symbol-p
      (car form)
      symbol)
     (rust-dive-magit-lint--form-references-symbol-p
      (cdr form)
      symbol)))
   (t
    nil)))

(defun rust-dive-magit-lint--unused-private-definitions
    (forms allowlist)
  "Return private definitions in FORMS not referenced outside their definitions.
ALLOWLIST is a list of private symbols to ignore."
  (let*
      (
       (definitions
        (delq
         nil
         (mapcar
          #'rust-dive-magit-lint--private-definition-symbol
          forms)))
       (definition-forms (make-hash-table :test #'eq))
       unused)
    (dolist (form forms)
      (when-let
          (
           (symbol
            (rust-dive-magit-lint--private-definition-symbol form)))
        (puthash symbol form definition-forms)))
    (dolist (symbol definitions)
      (unless
          (or (memq symbol allowlist)
              (cl-some
               (lambda (form)
		 (and (not (eq form (gethash symbol definition-forms)))
                      (rust-dive-magit-lint--form-references-symbol-p
                       form
                       symbol)))
               forms))
        (push symbol unused)))
    (nreverse unused)))

(defun rust-dive-magit-lint--collect-unused-private-definitions
    (files)
  "Return an alist of unused private definitions found in FILES."
  (let (results)
    (dolist (file files)
      (let*
          (
           (forms (rust-dive-magit-lint--read-forms file))
           (unused
            (rust-dive-magit-lint--unused-private-definitions
             forms
             rust-dive-magit-lint--private-symbol-allowlist)))
        (when unused
          (push (cons file unused) results))))
    (nreverse results)))

(defun rust-dive-magit-lint--formatted-contents (file)
  "Return FILE contents after running the configured formatter."
  (with-temp-buffer
    (insert-file-contents file)
    (setq-local buffer-file-name file)
    (emacs-lisp-mode)
    (let ((source-buffer (current-buffer)))
      (with-temp-buffer
        (insert-buffer-substring source-buffer)
        (funcall (buffer-local-value 'major-mode source-buffer))
        (setq-local indent-line-function
                    (buffer-local-value 'indent-line-function source-buffer))
        (setq-local lisp-indent-function
                    (buffer-local-value 'lisp-indent-function source-buffer))
        (setq-local indent-tabs-mode
                    (buffer-local-value 'indent-tabs-mode source-buffer))
        (setq-local lisp-indent-offset
                    (buffer-local-value 'lisp-indent-offset source-buffer))
        (setq-local lisp-body-indent
                    (buffer-local-value 'lisp-body-indent source-buffer))
        (goto-char (point-min))
        (let ((inhibit-message t)
              (message-log-max nil))
          (indent-region (point-min) (point-max)))
        (buffer-string)))))

(defun rust-dive-magit-lint--check-formatting (files)
  "Signal an error when any of FILES is not formatter-clean."
  (let (dirty)
    (dolist (file files)
      (let
          (
           (current
            (with-temp-buffer
              (insert-file-contents file)
              (buffer-string)))
           (formatted (rust-dive-magit-lint--formatted-contents file)))
        (unless (string= current formatted)
          (push file dirty))))
    (when dirty
      (error
       "Formatting check failed for: %s"
       (mapconcat #'file-relative-name (nreverse dirty) ", ")))))

(defun rust-dive-magit-lint--apply-formatting (files)
  "Rewrite FILES in-place using the configured formatter."
  (dolist (file files)
    (let*
	(
         (current
          (with-temp-buffer
            (insert-file-contents file)
            (buffer-string)))
         (formatted (rust-dive-magit-lint--formatted-contents file)))
      (unless (string= current formatted)
        (with-temp-file file
          (insert formatted))
        (rust-dive-magit-lint--message "Formatted %s"
				       (file-relative-name file))))))

(defun rust-dive-magit-lint--byte-compile-file (file)
  "Check FILE with the byte-compiler and signal an error on warnings."
  (let ((byte-compile-error-on-warn t))
    (with-temp-buffer
      (insert-file-contents file)
      (delay-mode-hooks
        (emacs-lisp-mode))
      (setq buffer-file-name file)
      (byte-compile-from-buffer (current-buffer)))))

(defun rust-dive-magit-lint--run-byte-compile (files)
  "Byte-compile FILES with warnings treated as errors."
  (dolist (file files)
    (rust-dive-magit-lint--message "Byte-compiling %s"
				   (file-relative-name file))
    (rust-dive-magit-lint--byte-compile-file file)))

(defun rust-dive-magit-lint--run-checkdoc (files)
  "Run `checkdoc' against FILES."
  (require 'checkdoc)
  (dolist (file files)
    (rust-dive-magit-lint--message "Running checkdoc on %s"
				   (file-relative-name file))
    (with-temp-buffer
      (insert-file-contents file)
      (delay-mode-hooks
        (emacs-lisp-mode))
      (setq buffer-file-name file)
      (let (problems)
        (let
            (
             (checkdoc-create-error-function
              (lambda (text start end &optional _unfixable)
                (push (list text start end) problems))))
          (checkdoc-current-buffer t))
        (when problems
          (dolist (problem (nreverse problems))
            (pcase-let ((`(,text ,start ,_end) problem))
              (save-excursion
                (goto-char start)
                (rust-dive-magit-lint--message "%s:%s: checkdoc: %s"
					       (file-relative-name file)
					       (line-number-at-pos)
					       text))))
          (error
           "Checkdoc failed for %s"
           (file-relative-name file)))))))

(defun rust-dive-magit-lint--run-package-lint (file)
  "Run `package-lint' against FILE."
  (require 'package-lint)
  (rust-dive-magit-lint--message "Running package-lint on %s"
				 (file-relative-name file))
  (with-temp-buffer
    (insert-file-contents file)
    (delay-mode-hooks
      (emacs-lisp-mode))
    (setq buffer-file-name file)
    (let ((issues (package-lint-buffer)))
      (when issues
        (dolist (issue issues)
          (pcase-let ((`(,line ,column ,type ,message) issue))
            (rust-dive-magit-lint--message "%s:%s:%s: %s: %s"
					   (file-relative-name file)
					   line
					   column
					   type
					   message)))
        (error
         "Package-lint failed for %s"
         (file-relative-name file))))))

(defun rust-dive-magit-lint--run-relint (files)
  "Run `relint' against FILES."
  (require 'relint)
  (dolist (file files)
    (rust-dive-magit-lint--message "Running relint on %s"
				   (file-relative-name file))
    (pcase-let ((`(,errors . ,warnings) (relint-file file)))
      (unless (and (zerop errors) (zerop warnings))
        (error
         "Relint failed for %s (%s errors, %s warnings)"
         (file-relative-name file)
         errors
         warnings)))))

(defun rust-dive-magit-lint--run-unused-private-check (files)
  "Fail when FILES contain unused private definitions."
  (let
      (
       (unused
        (rust-dive-magit-lint--collect-unused-private-definitions
         files)))
    (when unused
      (dolist (entry unused)
        (rust-dive-magit-lint--message
         "%s: unused private definitions: %s"
         (file-relative-name (car entry))
         (mapconcat #'symbol-name (cdr entry) ", ")))
      (error "Unused private definitions found"))))

(defun rust-dive-magit-format-batch-and-exit ()
  "Format repo-owned Emacs Lisp files and exit."
  (interactive)
  (condition-case err
      (progn
	(rust-dive-magit-lint--apply-formatting
         (rust-dive-magit-lint--owned-elisp-files))
	(kill-emacs 0))
    (error
     (rust-dive-magit-lint--message "%s" (error-message-string err))
     (kill-emacs 1))))

(defun rust-dive-magit-lint-batch-and-exit ()
  "Check formatting and run lint for repo-owned Emacs Lisp files."
  (interactive)
  (condition-case err
      (let*
	  (
           (owned-files (rust-dive-magit-lint--owned-elisp-files))
           (package-file
            (expand-file-name "emacs/rust-dive-magit.el"
			      (rust-dive-magit-lint--repo-root))))
	(rust-dive-magit-lint--message "Checking formatting")
	(rust-dive-magit-lint--check-formatting owned-files)
	(rust-dive-magit-lint--run-byte-compile owned-files)
	(rust-dive-magit-lint--run-checkdoc
         (rust-dive-magit-lint--checkdoc-files owned-files))
	(rust-dive-magit-lint--run-package-lint package-file)
	(rust-dive-magit-lint--run-relint owned-files)
	(rust-dive-magit-lint--run-unused-private-check owned-files)
	(kill-emacs 0))
    (error
     (rust-dive-magit-lint--message "%s" (error-message-string err))
     (kill-emacs 1))))

(provide 'rust-dive-magit-lint)

;;; rust-dive-magit-lint.el ends here
