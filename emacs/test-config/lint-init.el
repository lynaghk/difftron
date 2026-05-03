;;; lint-init.el --- Lint bootstrap for difftron Emacs checks -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Usage:
;;   emacs -Q -l /path/to/difftron/emacs/test-config/lint-init.el

;;; Code:

(load
 (expand-file-name "bootstrap.el"
		   (file-name-directory (or load-file-name buffer-file-name)))
 nil 'nomessage)
(require 'package)

(setq package-user-dir
      (expand-file-name "difftron-emacs-package-cache"
			temporary-file-directory))
(setq package-archives '(("melpa" . "https://melpa.org/packages/")))
(package-initialize)
(unless package-archive-contents
  (package-refresh-contents))
(difftron-test-config-bootstrap)

(straight-use-package 'package-lint)
(straight-use-package 'relint)

(use-package
  magit
  :straight (magit :type git :host github :repo "magit/magit")
  :demand t)

(use-package
  difftron-magit-lint
  :straight nil
  :load-path difftron-elisp-root
  :demand t)

(provide 'lint-init)

;;; lint-init.el ends here
