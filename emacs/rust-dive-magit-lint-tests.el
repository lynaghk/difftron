;;; rust-dive-magit-lint-tests.el --- Tests for rust-dive-magit lint helpers -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)

(add-to-list
  'load-path
  (file-name-directory (or load-file-name buffer-file-name)))
(require 'rust-dive-magit-lint)

(ert-deftest rust-dive-magit-lint-finds-unused-private-definitions ()
  (let*
    (
      (forms
        '
        (
          (defun rust-dive-magit--used ()
            t)
          (defun rust-dive-magit--unused ()
            nil)
          (defun rust-dive-magit-demo ()
            (rust-dive-magit--used))))
      (unused
        (rust-dive-magit-lint--unused-private-definitions forms nil)))
    (should (equal unused '(rust-dive-magit--unused)))))

(ert-deftest
  rust-dive-magit-lint-ignores-allowlisted-private-definitions
  ()
  (let*
    (
      (forms
        '
        (
          (defun rust-dive-magit--used ()
            t)
          (defun rust-dive-magit--allowlisted ()
            nil)
          (defun rust-dive-magit-demo ()
            (rust-dive-magit--used))))
      (unused
        (rust-dive-magit-lint--unused-private-definitions
          forms
          '(rust-dive-magit--allowlisted))))
    (should-not unused)))

(ert-deftest rust-dive-magit-lint-counts-references-from-other-files
  ()
  (let*
    (
      (forms
        '
        (
          (defun rust-dive-magit--helper ()
            t)
          (defun rust-dive-magit-demo ()
            t)
          (ert-deftest rust-dive-magit-demo-test ()
            (should (rust-dive-magit--helper)))))
      (unused
        (rust-dive-magit-lint--unused-private-definitions forms nil)))
    (should-not unused)))

(provide 'rust-dive-magit-lint-tests)

;;; rust-dive-magit-lint-tests.el ends here
