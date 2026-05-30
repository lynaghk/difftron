;;; init.el --- Minimal difftron + Magit setup  -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Usage:
;;   emacs -Q -l /path/to/difftron/emacs/test-config/init.el

;;; Code:

(load
 (expand-file-name "bootstrap.el"
		   (file-name-directory (or load-file-name buffer-file-name)))
 nil 'nomessage)
(difftron-test-config-bootstrap)

(defconst difftron-dev-wrapper
  (expand-file-name "../../scripts/difftron_dev"
		    difftron-test-config-root))

(use-package
  magit
  :straight (magit :type git :host github :repo "magit/magit")
  :defer t)

(use-package
  difftron
  :straight nil
  :load-path difftron-elisp-root
  :demand t
  :bind ("C-c r d" . difftron-diff)
  :init (setq difftron-executable difftron-dev-wrapper)
  :config (difftron-bindings-mode 1))

(provide 'init)

;;; init.el ends here
