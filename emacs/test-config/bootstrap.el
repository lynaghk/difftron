;;; bootstrap.el --- Shared bootstrap for difftron Emacs test config -*- lexical-binding: t; -*-

;;; Code:

(setq package-enable-at-startup nil)

(defvar comp-async-report-warnings-errors)
(defvar native-comp-async-report-warnings-errors)

(setq comp-async-report-warnings-errors nil)
(setq native-comp-async-report-warnings-errors nil)

(defconst difftron-test-config-root
  (file-name-directory (or load-file-name buffer-file-name)))

(defconst difftron-elisp-root
  (expand-file-name ".." difftron-test-config-root))

(defun difftron-test-config--path-segment (value)
  "Return VALUE as a filesystem-friendly path segment."
  (replace-regexp-in-string
   "[^[:alnum:]._-]+"
   "-"
   (format "%s" value)))

(defun difftron-test-config-straight-build-dir ()
  "Return the host-specific straight.el build directory name."
  (format "build-%s-%s-%s"
	  (difftron-test-config--path-segment emacs-version)
	  (difftron-test-config--path-segment system-type)
	  (difftron-test-config--path-segment system-configuration)))

(defun difftron-test-config-bootstrap ()
  "Bootstrap straight.el and `use-package' for local test config."
  (setq straight-base-dir difftron-test-config-root)
  (setq straight-build-dir (difftron-test-config-straight-build-dir))
  (setq straight-use-package-by-default t)
  (defvar bootstrap-version)
  (let
      (
       (bootstrap-file
        (expand-file-name "straight/repos/straight.el/bootstrap.el"
			  straight-base-dir))
       (bootstrap-version 7))
    (unless (file-exists-p bootstrap-file)
      (with-current-buffer
          (url-retrieve-synchronously
           "https://raw.githubusercontent.com/radian-software/straight.el/develop/install.el"
           'silent
           'inhibit-cookies)
        (goto-char (point-max))
        (eval-print-last-sexp)))
    (load bootstrap-file nil 'nomessage))
  (straight-use-package 'use-package)
  (require 'use-package))

(provide 'difftron-test-config-bootstrap)

;;; bootstrap.el ends here
