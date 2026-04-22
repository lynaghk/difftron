;;; init.el --- Minimal rust_dive + Magit setup  -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Usage:
;;   emacs -Q -l /path/to/rust_dive/emacs/test-config/init.el

;;; Code:

(setq package-enable-at-startup nil)

(defconst rust-dive-test-config-root
  (file-name-directory (or load-file-name buffer-file-name)))

(defconst rust-dive-elisp-root
  (expand-file-name ".." rust-dive-test-config-root))

(defconst rust-dive-dev-wrapper
  (expand-file-name "../../scripts/rust_dive_dev" rust-dive-test-config-root))

(setq straight-base-dir rust-dive-test-config-root)
(setq straight-use-package-by-default t)

(defvar bootstrap-version)
(let ((bootstrap-file
       (expand-file-name "straight/repos/straight.el/bootstrap.el" straight-base-dir))
      (bootstrap-version 7))
  (unless (file-exists-p bootstrap-file)
    (with-current-buffer
        (url-retrieve-synchronously
         "https://raw.githubusercontent.com/radian-software/straight.el/develop/install.el"
         'silent 'inhibit-cookies)
      (goto-char (point-max))
      (eval-print-last-sexp)))
  (load bootstrap-file nil 'nomessage))

(straight-use-package 'use-package)
(require 'use-package)

(use-package magit
  :straight (magit :type git :host github :repo "magit/magit")
  :defer t)

(use-package rust-dive-magit
  :straight nil
  :load-path rust-dive-elisp-root
  :demand t
  :bind ("C-c r d" . rust-dive-magit-diff)
  :init
  (setq rust-dive-magit-executable rust-dive-dev-wrapper)
  :config
  (rust-dive-magit-bindings-mode 1))

(provide 'init)

;;; init.el ends here
