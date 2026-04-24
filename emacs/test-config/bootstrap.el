;;; bootstrap.el --- Shared bootstrap for rust_dive Emacs test config -*- lexical-binding: t; -*-

;;; Code:

(setq package-enable-at-startup nil)

(defconst rust-dive-test-config-root
  (file-name-directory (or load-file-name buffer-file-name)))

(defconst rust-dive-elisp-root
  (expand-file-name ".." rust-dive-test-config-root))

(defun rust-dive-test-config-bootstrap ()
  "Bootstrap straight.el and `use-package' for local test config."
  (setq straight-base-dir rust-dive-test-config-root)
  (setq straight-use-package-by-default t)
  (defvar bootstrap-version)
  (let ((bootstrap-file
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
