;;; init.el --- Minimal rust_dive + Magit setup  -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Usage:
;;   emacs -Q -l /path/to/rust_dive/emacs/test-config/init.el

;;; Code:

(load (expand-file-name "bootstrap.el"
                        (file-name-directory
                         (or load-file-name buffer-file-name)))
      nil 'nomessage)
(rust-dive-test-config-bootstrap)

(defconst rust-dive-dev-wrapper
  (expand-file-name "../../scripts/rust_dive_dev"
                    rust-dive-test-config-root))

(use-package
 magit
 :straight (magit :type git :host github :repo "magit/magit")
 :defer t)

(use-package
 rust-dive-magit
 :straight nil
 :load-path rust-dive-elisp-root
 :demand t
 :bind ("C-c r d" . rust-dive-magit-diff)
 :init (setq rust-dive-magit-executable rust-dive-dev-wrapper)
 :config (rust-dive-magit-bindings-mode 1))

(provide 'init)

;;; init.el ends here
