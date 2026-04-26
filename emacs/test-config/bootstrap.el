;;; bootstrap.el --- Shared bootstrap for rust_dive Emacs test config -*- lexical-binding: t; -*-

;;; Code:

(setq package-enable-at-startup nil)

(defvar comp-async-report-warnings-errors)
(defvar native-comp-async-report-warnings-errors)

(setq comp-async-report-warnings-errors nil)
(setq native-comp-async-report-warnings-errors nil)

(defconst rust-dive-test-config-root
  (file-name-directory (or load-file-name buffer-file-name)))

(defconst rust-dive-elisp-root
  (expand-file-name ".." rust-dive-test-config-root))

(defun rust-dive-test-config--path-segment (value)
  "Return VALUE as a filesystem-friendly path segment."
  (replace-regexp-in-string
    "[^[:alnum:]._-]+"
    "-"
    (format "%s" value)))

(defun rust-dive-test-config-straight-build-dir ()
  "Return the host-specific straight.el build directory name."
  (format "build-%s-%s-%s"
    (rust-dive-test-config--path-segment emacs-version)
    (rust-dive-test-config--path-segment system-type)
    (rust-dive-test-config--path-segment system-configuration)))

(defun rust-dive-test-config-bootstrap ()
  "Bootstrap straight.el and `use-package' for local test config."
  (setq straight-base-dir rust-dive-test-config-root)
  (setq straight-build-dir (rust-dive-test-config-straight-build-dir))
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

(provide 'rust-dive-test-config-bootstrap)

;;; bootstrap.el ends here
