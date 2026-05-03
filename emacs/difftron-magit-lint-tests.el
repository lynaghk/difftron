;;; difftron-magit-lint-tests.el --- Tests for difftron-magit lint helpers -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)

(add-to-list
 'load-path
 (file-name-directory (or load-file-name buffer-file-name)))
(require 'difftron-magit-lint)

(ert-deftest difftron-magit-lint-finds-unused-private-definitions ()
  (let*
      (
       (forms
        '
        (
         (defun difftron-magit--used ()
           t)
         (defun difftron-magit--unused ()
           nil)
         (defun difftron-magit-demo ()
           (difftron-magit--used))))
       (unused
        (difftron-magit-lint--unused-private-definitions forms nil)))
    (should (equal unused '(difftron-magit--unused)))))

(ert-deftest
    difftron-magit-lint-ignores-allowlisted-private-definitions
    ()
  (let*
      (
       (forms
        '
        (
         (defun difftron-magit--used ()
           t)
         (defun difftron-magit--allowlisted ()
           nil)
         (defun difftron-magit-demo ()
           (difftron-magit--used))))
       (unused
        (difftron-magit-lint--unused-private-definitions
         forms
         '(difftron-magit--allowlisted))))
    (should-not unused)))

(ert-deftest difftron-magit-lint-counts-references-from-other-files
    ()
  (let*
      (
       (forms
        '
        (
         (defun difftron-magit--helper ()
           t)
         (defun difftron-magit-demo ()
           t)
         (ert-deftest difftron-magit-demo-test ()
           (should (difftron-magit--helper)))))
       (unused
        (difftron-magit-lint--unused-private-definitions forms nil)))
    (should-not unused)))

(provide 'difftron-magit-lint-tests)

;;; difftron-magit-lint-tests.el ends here
