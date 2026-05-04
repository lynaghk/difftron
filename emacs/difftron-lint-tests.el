;;; difftron-lint-tests.el --- Tests for difftron lint helpers -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)

(add-to-list
 'load-path
 (file-name-directory (or load-file-name buffer-file-name)))
(require 'difftron-lint)

(ert-deftest difftron-lint-finds-unused-private-definitions ()
  (let*
      (
       (forms
        '
        (
         (defun difftron--used ()
           t)
         (defun difftron--unused ()
           nil)
         (defun difftron-demo ()
           (difftron--used))))
       (unused
        (difftron-lint--unused-private-definitions forms nil)))
    (should (equal unused '(difftron--unused)))))

(ert-deftest
    difftron-lint-ignores-allowlisted-private-definitions
    ()
  (let*
      (
       (forms
        '
        (
         (defun difftron--used ()
           t)
         (defun difftron--allowlisted ()
           nil)
         (defun difftron-demo ()
           (difftron--used))))
       (unused
        (difftron-lint--unused-private-definitions
         forms
         '(difftron--allowlisted))))
    (should-not unused)))

(ert-deftest difftron-lint-counts-references-from-other-files
    ()
  (let*
      (
       (forms
        '
        (
         (defun difftron--helper ()
           t)
         (defun difftron-demo ()
           t)
         (ert-deftest difftron-demo-test ()
           (should (difftron--helper)))))
       (unused
        (difftron-lint--unused-private-definitions forms nil)))
    (should-not unused)))

(provide 'difftron-lint-tests)

;;; difftron-lint-tests.el ends here
