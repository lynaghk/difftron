;;; difftron-tests.el --- Tests for difftron  -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)

(add-to-list
 'load-path
 (file-name-directory (or load-file-name buffer-file-name)))
(require 'difftron)

(defvar difftron-tests--sample-payload)

(defconst difftron-tests--entity-kind-order
  '
  ("struct"
   "enum"
   "union"
   "trait"
   "protocol"
   "record"
   "type"
   "type_alias"
   "function"
   "macro"
   "multimethod"
   "method"
   "var"
   "impl"
   "module"
   "namespace"))

(defconst difftron-tests--entity-kinds
  (list
   :struct (list :label "Struct" :group_label "Structs")
   :enum (list :label "Enum" :group_label "Enums")
   :union (list :label "Union" :group_label "Unions")
   :trait (list :label "Trait" :group_label "Traits")
   :protocol (list :label "Protocol" :group_label "Protocols")
   :record (list :label "Record" :group_label "Records")
   :type (list :label "Type" :group_label "Types")
   :type_alias (list :label "Type Alias" :group_label "Type Aliases")
   :function (list :label "Function" :group_label "Functions")
   :macro (list :label "Macro" :group_label "Macros")
   :multimethod (list :label "Multimethod" :group_label "Multimethods")
   :method (list :label "Method" :group_label "Methods")
   :var (list :label "Var" :group_label "Vars")
   :impl (list :label "Impl" :group_label "Impls")
   :module (list :label "Module" :group_label "Modules")
   :namespace (list :label "Namespace" :group_label "Namespaces")))

(defun difftron-tests--git-revision (label rev)
  (list
   :label label
   :kind "git_revision"
   :root "/tmp/repo"
   :rev rev
   :summary (format "Commit %s" rev)))

(defun difftron-tests--git-revision-in-repo
    (repo label rev summary)
  (list
   :label label
   :kind "git_revision"
   :root repo
   :rev rev
   :summary summary))

(defun difftron-tests--directory-snapshot (path)
  (list :label path :kind "directory" :root path))

(defun difftron-tests--file-snapshot (path)
  (list :label path :kind "file" :root path))

(defun difftron-tests--snapshot-section (side)
  (seq-find
   (lambda (section)
     (and
      (eq (oref section type) 'difftron-snapshot)
      (eq (oref section value) side)))
   (oref magit-root-section children)))

(defun difftron-tests--first-child-section (parent type)
  (seq-find
   (lambda (section)
     (eq (oref section type) type))
   (oref parent children)))

(defun difftron-tests--sections-of-type (type)
  "Return all Magit sections whose type is TYPE."
  (let (sections)
    (magit-map-sections
     (lambda (section)
       (when (eq (oref section type) type)
         (push section sections))))
    (nreverse sections)))

(defun difftron-tests--section-has-invisible-overlay-p
    (section)
  "Return non-nil when SECTION's body has a hiding overlay."
  (when-let ((content (oref section content)))
    (seq-some
     (lambda (overlay)
       (overlay-get overlay 'invisible))
     (overlays-at content))))

(defun difftron-tests--show-section-ancestors (section)
  "Show SECTION's ancestors without changing SECTION visibility."
  (let ((ancestor (oref section parent))
        ancestors)
    (while ancestor
      (push ancestor ancestors)
      (setq ancestor (oref ancestor parent)))
    (dolist (visible-section (nreverse ancestors))
      (magit-section-show visible-section))))

(defconst difftron-tests--repo-git-env-regexp
  "\\`GIT_\\(DIR\\|WORK_TREE\\|INDEX_FILE\\|OBJECT_DIRECTORY\\|ALTERNATE_OBJECT_DIRECTORIES\\|CEILING_DIRECTORIES\\|PREFIX\\)=")

(defun difftron-tests--git (repo &rest args)
  "Run Git with ARGS in REPO and return stdout."
  (with-temp-buffer
    (let
        (
         (process-environment
          (seq-remove
           (lambda (entry)
             (string-match-p
              difftron-tests--repo-git-env-regexp
              entry))
           process-environment))
         (exit-code
          (apply
           #'process-file
           "git"
           nil
           t
           nil
           (append (list "-C" repo) args))))
      (unless (zerop exit-code)
        (error
         "Git failed with exit code %s: git %s\n%s"
         exit-code
         (string-join (append (list "-C" repo) args) " ")
         (buffer-string)))
      (string-trim-right (buffer-string)))))

(defun difftron-tests--write-file (repo path contents)
  "Write CONTENTS to PATH under REPO."
  (let ((file (expand-file-name path repo)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert contents))))

(defun difftron-tests--commit
    (repo path contents subject body date)
  "Create a commit in REPO and return its full hash."
  (difftron-tests--write-file repo path contents)
  (difftron-tests--git repo "add" path)
  (let
      (
       (process-environment
        (append
         (list
          "GIT_AUTHOR_NAME=Codex"
          "GIT_AUTHOR_EMAIL="
          "GIT_COMMITTER_NAME=Codex"
          "GIT_COMMITTER_EMAIL="
          (format "GIT_AUTHOR_DATE=%s" date)
          (format "GIT_COMMITTER_DATE=%s" date))
         process-environment)))
    (difftron-tests--git
     repo
     "commit"
     "--no-verify"
     "-m"
     subject
     "-m"
     body))
  (difftron-tests--git repo "rev-parse" "HEAD"))

(defun difftron-tests--with-revision-repo (fn)
  "Call FN with a temporary Git repo and two deterministic revisions."
  (let ((repo (file-name-as-directory
               (make-temp-file "difftron-repo-" t))))
    (unwind-protect
        (progn
          (difftron-tests--git repo "init" "-q")
          (difftron-tests--git
           repo
           "symbolic-ref"
           "HEAD"
           "refs/heads/master")
          (let*
              (
               (parent-subject "Move entity kind labels into JSON")
               (child-subject "Add Clojure entity kind metadata")
               (parent
                (difftron-tests--commit
                 repo
                 "README.md"
                 "parent\n"
                 parent-subject
                 "Parent body."
                 "Tue Apr 28 16:50:00 2026 +0000"))
               (child
                (difftron-tests--commit
                 repo
                 "README.md"
                 "child\n"
                 child-subject
                 "Expose Clojure namespaces vars and related forms through the normalized kind table."
                 "Tue Apr 28 16:51:46 2026 +0000")))
            (funcall fn repo parent child parent-subject child-subject)))
      (delete-directory repo t))))

(defun difftron-tests--payload-with-revisions
    (repo lhs-rev rhs-rev lhs-summary rhs-summary)
  "Return the sample payload with Git revisions from REPO."
  (let ((payload (copy-sequence difftron-tests--sample-payload)))
    (setq
     payload
     (plist-put
      payload
      :lhs
      (difftron-tests--git-revision-in-repo
       repo
       (format "repo@%s" (substring lhs-rev 0 7))
       lhs-rev
       lhs-summary)))
    (plist-put
     payload
     :rhs
     (difftron-tests--git-revision-in-repo
      repo
      (format "repo@%s" (substring rhs-rev 0 7))
      rhs-rev
      rhs-summary))))

(cl-defun
    difftron-tests--entity
    (name
     kind
     file-path
     snapshot-path
     source-text
     &key
     (start-line 1)
     (start-col 1)
     (end-line 1)
     (end-col 10)
     rendered-summary)
  (list
   :name name
   :kind kind
   :rendered_summary (or rendered-summary (format "%s %s" kind name))
   :file_path file-path
   :snapshot_path snapshot-path
   :start_line start-line
   :start_col start-col
   :end_line end-line
   :end_col end-col
   :source_text source-text))

(defun difftron-tests--segments (text novel)
  (let ((match (string-match (regexp-quote novel) text)))
    (list
     (list :text (substring text 0 match) :kind "context")
     (list :text novel :kind "novel")
     (list
      :text (substring text (+ match (length novel)))
      :kind "context"))))

(defun difftron-tests--side (text novel)
  (list
   :line_number 1
   :text text
   :segments (difftron-tests--segments text novel)))

(defun difftron-tests--modified-change
    (path lhs rhs lhs-novel rhs-novel)
  (list
   :path path
   :lhs lhs
   :rhs rhs
   :diff
   (list
    :rows
    (list
     (list
      :kind "replaced_code"
      :left
      (difftron-tests--side
       (plist-get lhs :source_text)
       lhs-novel)
      :right
      (difftron-tests--side
       (plist-get rhs :source_text)
       rhs-novel))))))

(defun difftron-tests--moved-change (lhs rhs)
  (list :lhs lhs :rhs rhs))

(defun difftron-tests--moved-modified-change (lhs rhs)
  (list
   :lhs lhs
   :rhs rhs
   :diff
   (list
    :rows
    (list
     (list
      :kind "replaced_code"
      :left
      (difftron-tests--side
       (plist-get lhs :source_text)
       "old_location")
      :right
      (difftron-tests--side
       (plist-get rhs :source_text)
       "new_location"))))))

(cl-defun
    difftron-tests--diff-payload
    (&key
     added
     deleted
     moved
     moved-modified
     modified
     (lhs-label "repo@HEAD~1")
     (rhs-label "repo@HEAD")
     (lhs-rev "HEAD~1")
     (rhs-rev "HEAD"))
  (list
   :command "diff"
   :entity_kind_order difftron-tests--entity-kind-order
   :entity_kinds difftron-tests--entity-kinds
   :lhs (difftron-tests--git-revision lhs-label lhs-rev)
   :rhs (difftron-tests--git-revision rhs-label rhs-rev)
   :added added
   :deleted deleted
   :moved moved
   :moved_modified moved-modified
   :modified modified))

(defconst difftron-tests--sample-payload
  (let*
      (
       (added
        (difftron-tests--entity
         "demo::added"
         "function"
         "/tmp/repo/src/lib.rs"
         "src/lib.rs"
         "fn added() {}"
         :start-line 10
         :end-line 12
         :end-col 2
         :rendered-summary "function demo::added() @ /tmp/repo/src/lib.rs:10:1-12:2"))
       (lhs
        (difftron-tests--entity
         "demo::meaning"
         "function"
         "/tmp/repo/src/lib.rs"
         "src/lib.rs"
         "fn meaning() -> u32 { 41 }"
         :rendered-summary "function demo::meaning() @ /tmp/repo/src/lib.rs:1:1-1:10"))
       (rhs
        (difftron-tests--entity
         "demo::meaning"
         "function"
         "/tmp/repo/src/lib.rs"
         "src/lib.rs"
         "fn meaning() -> u32 { 42 }"
         :rendered-summary "function demo::meaning() @ /tmp/repo/src/lib.rs:1:1-1:10")))
    (difftron-tests--diff-payload
     :added (list added)
     :deleted nil
     :modified
     (list
      (difftron-tests--modified-change
       "src/lib.rs"
       lhs
       rhs
       "41"
       "42")))))

(defconst difftron-tests--multi-file-payload
  (let*
      (
       (added
        (difftron-tests--entity
         "demo::added"
         "function"
         "/tmp/repo/src/a.rs"
         "src/a.rs"
         "fn added() {}"
         :start-line 10
         :end-line 12
         :end-col 2
         :rendered-summary "function demo::added()"))
       (deleted
        (difftron-tests--entity
         "demo::old_struct"
         "struct"
         "/tmp/repo/src/b.rs"
         "src/b.rs"
         "struct Old;"
         :start-line 20
         :end-line 22
         :end-col 2
         :rendered-summary "struct demo::old_struct"))
       (lhs
        (difftron-tests--entity
         "demo::meaning"
         "function"
         "/tmp/repo/src/b.rs"
         "src/b.rs"
         "fn meaning() -> u32 { 41 }"
         :rendered-summary "function demo::meaning()"))
       (rhs
        (difftron-tests--entity
         "demo::meaning"
         "function"
         "/tmp/repo/src/b.rs"
         "src/b.rs"
         "fn meaning() -> u32 { 42 }"
         :rendered-summary "function demo::meaning()")))
    (difftron-tests--diff-payload
     :added (list added)
     :deleted (list deleted)
     :modified
     (list
      (difftron-tests--modified-change
       "src/b.rs"
       lhs
       rhs
       "41"
       "42")))))

(defconst difftron-tests--refresh-payload
  (let*
      (
       (added
        (difftron-tests--entity
         "demo::alpha"
         "function"
         "/tmp/repo/src/a.rs"
         "src/a.rs"
         "fn alpha() {}"
         :start-line 10
         :end-line 12
         :end-col 2
         :rendered-summary "function demo::alpha()"))
       (beta-lhs
        (difftron-tests--entity
         "demo::beta"
         "function"
         "/tmp/repo/src/b.rs"
         "src/b.rs"
         "fn beta() -> u32 { 41 }"
         :rendered-summary "function demo::beta()"))
       (beta-rhs
        (difftron-tests--entity
         "demo::beta"
         "function"
         "/tmp/repo/src/b.rs"
         "src/b.rs"
         "fn beta() -> u32 { 42 }"
         :rendered-summary "function demo::beta()"))
       (gamma-lhs
        (difftron-tests--entity
         "demo::gamma"
         "function"
         "/tmp/repo/src/c.rs"
         "src/c.rs"
         "fn gamma() -> u32 { 7 }"
         :rendered-summary "function demo::gamma()"))
       (gamma-rhs
        (difftron-tests--entity
         "demo::gamma"
         "function"
         "/tmp/repo/src/c.rs"
         "src/c.rs"
         "fn gamma() -> u32 { 8 }"
         :rendered-summary "function demo::gamma()")))
    (difftron-tests--diff-payload
     :added (list added)
     :deleted nil
     :modified
     (list
      (difftron-tests--modified-change
       "src/b.rs"
       beta-lhs
       beta-rhs
       "41"
       "42")
      (difftron-tests--modified-change
       "src/c.rs"
       gamma-lhs
       gamma-rhs
       "7"
       "8")))))

(ert-deftest difftron-groups-items-by-kind ()
  (let*
      (
       (items
        (difftron--diff-items
         difftron-tests--sample-payload))
       (grouped (difftron--group-items-by-kind items)))
    (should (equal (caar grouped) "function"))
    (should (equal (length grouped) 1))
    (should
     (equal
      (sort
       (mapcar
        (lambda (item) (plist-get (plist-get item :entity) :name))
        (copy-sequence (cdar grouped)))
       #'string<)
      '("demo::added" "demo::meaning")))))

(ert-deftest difftron-groups-items-by-file ()
  (let*
      (
       (items
        (difftron--diff-items
         difftron-tests--multi-file-payload))
       (grouped (difftron--group-items-by-file items)))
    (should (equal (mapcar #'car grouped) '("src/a.rs" "src/b.rs")))))

(ert-deftest difftron-renders-moved-items ()
  (let*
      (
       (lhs
        (difftron-tests--entity
         "demo::old::moved"
         "function"
         "/tmp/repo/src/old.rs"
         "src/old.rs"
         "fn moved() { old_location(); }"))
       (rhs
        (difftron-tests--entity
         "demo::new::moved"
         "function"
         "/tmp/repo/src/new.rs"
         "src/new.rs"
         "fn moved() { new_location(); }"))
       (payload
        (difftron-tests--diff-payload
         :moved (list (difftron-tests--moved-change lhs rhs)))))
    (with-temp-buffer
      (difftron-mode)
      (setq difftron--hierarchy '(file kind))
      (let ((inhibit-read-only t))
        (difftron--insert-payload payload))
      (let*
          (
           (text (buffer-string))
           (items (difftron--diff-items payload))
           (grouped (difftron--group-items-by-file items)))
        (should (string-match-p "^src/old\\.rs (1)$" text))
        (should (string-match-p "^src/new\\.rs (1)$" text))
        (should
         (string-match-p
          "^      demo::old::moved moved to demo::new::moved$"
          text))
        (should
         (string-match-p
          "^      demo::new::moved moved from demo::old::moved$"
          text))
        (should
         (string-match-p "fn moved() { old_location(); }" text))
        (should
         (string-match-p "fn moved() { new_location(); }" text))
        (should
         (equal (mapcar #'car grouped) '("src/new.rs" "src/old.rs")))
        (should (equal (plist-get (car items) :entity) lhs))
        (should (equal (plist-get (cadr items) :entity) rhs))))))

(ert-deftest difftron-renders-moved-modified-items ()
  (let*
      (
       (lhs
        (difftron-tests--entity
         "demo::old::moved"
         "function"
         "/tmp/repo/src/old.rs"
         "src/old.rs"
         "fn moved() { old_location(); }"))
       (rhs
        (difftron-tests--entity
         "demo::new::moved"
         "function"
         "/tmp/repo/src/new.rs"
         "src/new.rs"
         "fn moved() { new_location(); }"))
       (payload
        (difftron-tests--diff-payload
         :moved-modified
         (list
          (difftron-tests--moved-modified-change lhs rhs)))))
    (with-temp-buffer
      (difftron-mode)
      (setq difftron--hierarchy '(file kind))
      (let ((inhibit-read-only t))
        (difftron--insert-payload payload))
      (let*
          (
           (text (buffer-string))
           (items (difftron--diff-items payload))
           (grouped (difftron--group-items-by-file items)))
        (should (string-match-p "^src/old\\.rs (1)$" text))
        (should (string-match-p "^src/new\\.rs (1)$" text))
        (should
         (string-match-p
          "^    M demo::old::moved moved to demo::new::moved$"
          text))
        (should
         (string-match-p
          "^    M demo::new::moved moved from demo::old::moved$"
          text))
        (should
         (string-match-p "fn moved() { old_location(); }" text))
        (should
         (string-match-p "fn moved() { new_location(); }" text))
        (should
         (equal (mapcar #'car grouped) '("src/new.rs" "src/old.rs")))
        (should (equal (plist-get (car items) :entity) lhs))
        (should (equal (plist-get (cadr items) :entity) rhs))))))

(ert-deftest difftron-renders-diff-buffer ()
  (with-temp-buffer
    (difftron-mode)
    (let ((inhibit-read-only t))
      (difftron--insert-payload
       difftron-tests--sample-payload))
    (let*
        (
         (text (buffer-string))
         (root magit-root-section)
         (file-section
          (difftron-tests--first-child-section
           root
           'difftron-file))
         (entity-section (car (oref file-section children))))
      (should
       (string-match-p
        "^lhs: repo@HEAD~1  Commit HEAD~1\nrhs: repo@HEAD  Commit HEAD\n\n"
        text))
      (should (string-match-p "repo@HEAD~1  Commit HEAD~1" text))
      (should (string-match-p "repo@HEAD  Commit HEAD" text))
      (should-not (string-match-p "difftron diff" text))
      (should-not (string-match-p "Grouping:" text))
      (should (derived-mode-p 'magit-section-mode))
      (should (equal (oref file-section type) 'difftron-file))
      (should (equal (oref entity-section type) 'difftron-entity))
      (should (oref file-section hidden))
      (should (oref entity-section hidden))
      (should (string-match-p "^src/lib\\.rs (2)$" text))
      (should (string-match-p "^  M demo::meaning$" text))
      (should (string-match-p "M demo::meaning" text))
      (should (string-match-p "\\+ demo::added" text))
      (should (string-match-p "fn meaning() -> u32" text))
      (should-not (string-match-p "ANSI-DIFF" text))
      (should-not (string-match-p "Location:" text))
      (should-not
       (string-match-p
        "function demo::added() @ /tmp/repo/src/lib.rs:10:1-12:2"
        text)))))

(ert-deftest difftron-renders-kind-file-hierarchy ()
  (with-temp-buffer
    (difftron-mode)
    (setq difftron--hierarchy '(kind file))
    (let ((inhibit-read-only t))
      (difftron--insert-payload
       difftron-tests--multi-file-payload))
    (let*
        (
         (root magit-root-section)
         (kind-section
          (difftron-tests--first-child-section
           root
           'difftron-kind))
         (file-section (car (oref kind-section children)))
         (entity-section (car (oref file-section children))))
      (should (equal (oref kind-section type) 'difftron-kind))
      (should (equal (oref file-section type) 'difftron-file))
      (should (equal (oref entity-section type) 'difftron-entity))
      (goto-char (point-min))
      (search-forward "src/a.rs (1)")
      (should
       (eq
        (get-text-property (match-beginning 0) 'font-lock-face)
        'difftron-level-1-heading))
      (should-not (string-match-p "Grouping:" (buffer-string))))))

(ert-deftest difftron-renders-file-kind-hierarchy ()
  (with-temp-buffer
    (difftron-mode)
    (setq difftron--hierarchy '(file kind))
    (let ((inhibit-read-only t))
      (difftron--insert-payload
       difftron-tests--multi-file-payload))
    (let*
        (
         (root magit-root-section)
         (file-section
          (difftron-tests--first-child-section
           root
           'difftron-file))
         (kind-section (car (oref file-section children)))
         (entity-section (car (oref kind-section children))))
      (should (equal (oref file-section type) 'difftron-file))
      (should (equal (oref kind-section type) 'difftron-kind))
      (should (equal (oref entity-section type) 'difftron-entity))
      (goto-char (point-min))
      (search-forward "src/a.rs (1)")
      (should
       (eq
        (get-text-property (match-beginning 0) 'font-lock-face)
        'magit-section-heading))
      (should (string-match-p "^src/a\\.rs (1)$" (buffer-string)))
      (should (string-match-p "^  Functions (1)$" (buffer-string)))
      (should
       (string-match-p "^    \\+ demo::added$" (buffer-string)))
      (should-not (string-match-p "Grouping:" (buffer-string))))))

(ert-deftest difftron-renders-file-only-hierarchy ()
  (with-temp-buffer
    (difftron-mode)
    (setq difftron--hierarchy '(file))
    (let ((inhibit-read-only t))
      (difftron--insert-payload
       difftron-tests--multi-file-payload))
    (let*
        (
         (root magit-root-section)
         (file-section
          (difftron-tests--first-child-section
           root
           'difftron-file))
         (entity-section (car (oref file-section children))))
      (should (equal (oref file-section type) 'difftron-file))
      (should (equal (oref entity-section type) 'difftron-entity))
      (should-not
       (difftron-tests--first-child-section file-section 'difftron-kind))
      (should (string-match-p "^src/a\\.rs (1)$" (buffer-string)))
      (should
       (string-match-p "^  \\+ demo::added$" (buffer-string))))))

(ert-deftest difftron-renders-kind-only-hierarchy ()
  (with-temp-buffer
    (difftron-mode)
    (setq difftron--hierarchy '(kind))
    (let ((inhibit-read-only t))
      (difftron--insert-payload
       difftron-tests--multi-file-payload))
    (let*
        (
         (root magit-root-section)
         (kind-section
          (difftron-tests--first-child-section
           root
           'difftron-kind))
         (entity-section (car (oref kind-section children))))
      (should (equal (oref kind-section type) 'difftron-kind))
      (should (equal (oref entity-section type) 'difftron-entity))
      (should-not
       (difftron-tests--first-child-section root 'difftron-file))
      (should
       (string-match-p "^Functions (2)$" (buffer-string)))
      (should
       (string-match-p "^  \\+ demo::added$" (buffer-string))))))

(ert-deftest difftron-renders-kind-labels-from-payload ()
  (with-temp-buffer
    (difftron-mode)
    (setq difftron--hierarchy '(kind))
    (let ((inhibit-read-only t))
      (difftron--insert-payload
       (difftron-tests--diff-payload
        :added
        (list
         (difftron-tests--entity
          "demo.core::message"
          "var"
          "/tmp/repo/src/demo/core.clj"
          "src/demo/core.clj"
          "(def message \"hello\")")))))
    (should (string-match-p "^Vars (1)$" (buffer-string)))))

(ert-deftest difftron-default-hierarchy-is-file ()
  (should
   (equal
    (eval
     (car (get 'difftron-default-hierarchy 'standard-value))
     t)
    '(file))))

(ert-deftest difftron-scroll-section-after-navigation-defaults-to-true ()
  (should
   (eq
    (eval
     (car
      (get
       'difftron-scroll-section-after-navigation
       'standard-value))
     t)
    t)))

(ert-deftest difftron-display-buffer-uses-default-hierarchy ()
  (let ((difftron-default-hierarchy '(file)))
    (cl-letf
	(((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (difftron--display-buffer
       "/tmp/repo/"
       '("diff" "HEAD~1" "HEAD")
       difftron-tests--multi-file-payload))
    (with-current-buffer difftron-buffer-name
      (let*
          (
           (root magit-root-section)
           (file-section
            (difftron-tests--first-child-section
             root
             'difftron-file))
           (sibling-file-section
            (cadr
             (seq-filter
              (lambda (section)
		(eq (oref section type) 'difftron-file))
              (oref root children))))
           (entity-section (car (oref file-section children))))
        (should (equal difftron--hierarchy '(file)))
        (should-not (string-match-p "Grouping:" (buffer-string)))
        (should-not (oref file-section hidden))
        (should (oref entity-section hidden))
        (should
         (difftron-tests--section-has-invisible-overlay-p
          entity-section))
        (should-not (oref sibling-file-section hidden))
        (should-not
         (difftron-tests--section-has-invisible-overlay-p
          sibling-file-section))))))

(ert-deftest difftron-display-buffer-shows-all-default-hierarchy-groups ()
  (let ((difftron-default-hierarchy '(kind file)))
    (cl-letf
	(((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (difftron--display-buffer
       "/tmp/repo/"
       '("diff" "HEAD~1" "HEAD")
       difftron-tests--multi-file-payload))
    (with-current-buffer difftron-buffer-name
      (dolist (section
               (append
                (difftron-tests--sections-of-type 'difftron-kind)
                (difftron-tests--sections-of-type 'difftron-file)))
        (should-not (oref section hidden))
        (should-not
         (difftron-tests--section-has-invisible-overlay-p
          section)))
      (dolist (section
               (difftron-tests--sections-of-type 'difftron-entity))
        (should (oref section hidden))
        (should
         (difftron-tests--section-has-invisible-overlay-p
          section))))))

(ert-deftest difftron-inherits-magit-all-level-bindings ()
  (should
   (eq
    (lookup-key difftron-mode-map (kbd "M-1"))
    #'magit-section-show-level-1-all))
  (should
   (eq
    (lookup-key difftron-mode-map (kbd "M-2"))
    #'magit-section-show-level-2-all))
  (should
   (eq
    (lookup-key difftron-mode-map (kbd "M-3"))
    #'magit-section-show-level-3-all))
  (should
   (eq
    (lookup-key difftron-mode-map (kbd "M-4"))
    #'magit-section-show-level-4-all)))

(ert-deftest difftron-binds-commit-navigation ()
  (should
   (eq
    (lookup-key difftron-mode-map (kbd "N"))
    #'difftron-next-commit))
  (should
   (eq
    (lookup-key difftron-mode-map (kbd "P"))
    #'difftron-previous-commit))
  (should
   (eq
    (lookup-key difftron-mode-map (kbd "n"))
    #'difftron-next-section))
  (should
   (eq
    (lookup-key difftron-mode-map (kbd "p"))
    #'difftron-previous-section)))

(ert-deftest difftron-binds-hierarchy-cycle ()
  (should
   (eq
    (lookup-key difftron-mode-map (kbd "y"))
    #'difftron-cycle-hierarchy))
  (should-not
   (lookup-key difftron-mode-map (kbd "t")))
  (should
   (eq
    (lookup-key difftron-mode-map (kbd "h"))
    #'difftron-dispatch))
  (should
   (eq
    (lookup-key difftron-mode-map (kbd "?"))
    #'difftron-dispatch)))

(ert-deftest difftron-next-section-scrolls-to-top-when-enabled ()
  (let ((difftron-scroll-section-after-navigation t)
        calls)
    (cl-letf
        (
         ((symbol-function 'magit-section-forward)
          (lambda () (push 'forward calls)))
         ((symbol-function 'recenter)
          (lambda (arg) (push (list 'recenter arg) calls))))
      (difftron-next-section))
    (should
     (equal
      (nreverse calls)
      '(forward (recenter 0))))))

(ert-deftest difftron-previous-section-scrolls-to-top-when-enabled ()
  (let ((difftron-scroll-section-after-navigation t)
        calls)
    (cl-letf
        (
         ((symbol-function 'magit-section-backward)
          (lambda () (push 'backward calls)))
         ((symbol-function 'recenter)
          (lambda (arg) (push (list 'recenter arg) calls))))
      (difftron-previous-section))
    (should
     (equal
      (nreverse calls)
      '(backward (recenter 0))))))

(ert-deftest difftron-next-section-does-not-scroll-when-disabled ()
  (let ((difftron-scroll-section-after-navigation nil)
        calls)
    (cl-letf
        (
         ((symbol-function 'magit-section-forward)
          (lambda () (push 'forward calls)))
         ((symbol-function 'recenter)
          (lambda (arg) (push (list 'recenter arg) calls))))
      (difftron-next-section))
    (should (equal (nreverse calls) '(forward)))))

(ert-deftest difftron-previous-section-does-not-scroll-when-disabled ()
  (let ((difftron-scroll-section-after-navigation nil)
        calls)
    (cl-letf
        (
         ((symbol-function 'magit-section-backward)
          (lambda () (push 'backward calls)))
         ((symbol-function 'recenter)
          (lambda (arg) (push (list 'recenter arg) calls))))
      (difftron-previous-section))
    (should (equal (nreverse calls) '(backward)))))

(ert-deftest difftron-next-section-temporarily-unfolds-entity ()
  (let ((difftron-scroll-section-after-navigation nil))
    (with-temp-buffer
      (difftron-mode)
      (let ((inhibit-read-only t))
        (difftron--insert-payload difftron-tests--sample-payload))
      (let*
          (
           (entities
            (difftron--entity-sections magit-root-section))
           (first-entity (car entities))
           (second-entity (cadr entities))
           (parent-section (oref first-entity parent)))
        (difftron-tests--show-section-ancestors first-entity)
        (goto-char (oref parent-section start))
        (should (oref first-entity hidden))
        (should (oref second-entity hidden))
        (difftron-next-section)
        (should (eq (magit-current-section) first-entity))
        (should-not (oref first-entity hidden))
        (difftron-next-section)
        (should (eq (magit-current-section) second-entity))
        (should (oref first-entity hidden))
        (should-not (oref second-entity hidden))))))

(ert-deftest difftron-next-section-preserves-already-unfolded-entity ()
  (let ((difftron-scroll-section-after-navigation nil))
    (with-temp-buffer
      (difftron-mode)
      (let ((inhibit-read-only t))
        (difftron--insert-payload difftron-tests--sample-payload))
      (let*
          (
           (entities
            (difftron--entity-sections magit-root-section))
           (first-entity (car entities))
           (second-entity (cadr entities))
           (parent-section (oref first-entity parent)))
        (difftron-tests--show-section-ancestors first-entity)
        (magit-section-show first-entity)
        (goto-char (oref parent-section start))
        (difftron-next-section)
        (should (eq (magit-current-section) first-entity))
        (should-not (oref first-entity hidden))
        (difftron-next-section)
        (should (eq (magit-current-section) second-entity))
        (should-not (oref first-entity hidden))
        (should-not (oref second-entity hidden))))))

(ert-deftest difftron-binds-side-selection ()
  (should
   (eq
    (lookup-key difftron-mode-map (kbd "l"))
    #'difftron-select-left))
  (should
   (eq
    (lookup-key difftron-mode-map (kbd "r"))
    #'difftron-select-right))
  (should
   (eq
    (lookup-key difftron-mode-map (kbd "s"))
    #'difftron-swap-sides)))

(ert-deftest difftron-binds-commit-message-toggle ()
  (should
   (eq
    (lookup-key difftron-mode-map (kbd "m"))
    #'difftron-toggle-commit-messages))
  (should
   (eq
    (lookup-key difftron-mode-map (kbd "TAB"))
    #'difftron-toggle-section-or-message)))

(ert-deftest difftron-read-snapshot-arg-completes-ref ()
  (let (read-prompt read-default read-collection)
    (cl-letf
        (
         ((symbol-function 'magit-list-branch-names)
          (lambda () '("main" "feature")))
         ((symbol-function 'magit-git-lines)
          (lambda (&rest args)
            (pcase args
              (`("log" "--max-count=100" "--date=short" "--format=%h%x09%H%x09%an%x09%ad%x09%s")
               nil)
              (`("ls-files") nil)
              (_ (error "Unexpected git args: %S" args)))))
         ((symbol-function 'completing-read)
          (lambda (prompt collection &rest args)
            (setq read-prompt prompt)
            (setq read-collection collection)
            (setq read-default (nth 4 args))
            "feature")))
      (should
       (equal
        (difftron--read-snapshot-arg
         'lhs
         "/tmp/repo/"
         "HEAD")
        "feature")))
    (should (equal read-prompt "Left snapshot: "))
    (should (equal read-default "HEAD"))
    (should (functionp read-collection))
    (should
     (member
      "feature"
      (all-completions "" read-collection)))))

(ert-deftest difftron-read-snapshot-arg-groups-candidates ()
  (let (read-collection)
    (cl-letf
        (
         ((symbol-function 'magit-list-branch-names)
          (lambda () '("main")))
         ((symbol-function 'magit-git-lines)
          (lambda (&rest args)
            (pcase args
              (`("log" "--max-count=100" "--date=short" "--format=%h%x09%H%x09%an%x09%ad%x09%s")
               '("abc1234\tabc1234full\tAda Dev\t2026-05-04\tAdd thing"
                 "def5678\tdef5678full\tBea Dev\t2026-05-03\tAdd a much longer thing"))
              (`("ls-files") '("src/lib.rs"))
              (_ (error "Unexpected git args: %S" args)))))
         ((symbol-function 'completing-read)
          (lambda (_prompt collection &rest _)
            (setq read-collection collection)
            "main")))
      (difftron--read-snapshot-arg 'lhs "/tmp/repo/" "HEAD"))
    (let*
        (
         (metadata (funcall read-collection "" nil 'metadata))
         (metadata-items (cdr metadata))
         (group-function (cdr (assq 'group-function metadata-items)))
         (affixation-function
          (cdr (assq 'affixation-function metadata-items)))
         (completions (all-completions "" read-collection)))
      (should (member "main" completions))
      (should (member "abc1234 Add thing" completions))
      (should (member "def5678 Add a much longer thing" completions))
      (should (member "src/lib.rs" completions))
      (should
       (equal
        (funcall group-function "main" nil)
        "Branches"))
      (should
       (equal
        (funcall group-function "abc1234 Add thing" nil)
        "Current Branch Commits"))
      (should
       (equal
        (funcall group-function "src/lib.rs" nil)
        "Repo Paths"))
      (let*
          (
           (commit-affix
            (car
             (funcall affixation-function
                      '("abc1234 Add thing"))))
           (commit-suffix (nth 2 commit-affix)))
        (should (equal (car commit-affix) "abc1234 Add thing"))
        (should
         (equal
          (substring-no-properties commit-suffix)
          " Ada Dev                  2026-05-04"))
        (should
         (equal
          (get-text-property 0 'display commit-suffix)
          `(space :align-to
                  ,(+ (length "def5678 Add a much longer thing") 2)))))
      (should
       (member
        '("main" "" "")
        (funcall affixation-function '("main"))))
      (should
       (member
        '("src/lib.rs" "" "")
        (funcall affixation-function '("src/lib.rs")))))))

(ert-deftest difftron-read-snapshot-arg-selects-full-commit-hash ()
  (cl-letf
      (
       ((symbol-function 'magit-list-branch-names)
        (lambda () '("main")))
       ((symbol-function 'magit-git-lines)
        (lambda (&rest args)
          (pcase args
            (`("log" "--max-count=100" "--date=short" "--format=%h%x09%H%x09%an%x09%ad%x09%s")
             '("abc1234\tabc1234full\tAda Dev\t2026-05-04\tAdd thing"))
            (`("ls-files") nil)
            (_ (error "Unexpected git args: %S" args)))))
       ((symbol-function 'completing-read)
        (lambda (&rest _) "abc1234 Add thing")))
    (should
     (equal
      (difftron--read-snapshot-arg 'lhs "/tmp/repo/" "HEAD")
      "abc1234full"))))

(ert-deftest difftron-read-snapshot-arg-selects-repo-path ()
  (cl-letf
      (
       ((symbol-function 'magit-list-branch-names)
        (lambda () '("main")))
       ((symbol-function 'magit-git-lines)
        (lambda (&rest args)
          (pcase args
            (`("log" "--max-count=100" "--date=short" "--format=%h%x09%H%x09%an%x09%ad%x09%s")
             nil)
            (`("ls-files") '("src/lib.rs"))
            (_ (error "Unexpected git args: %S" args)))))
       ((symbol-function 'completing-read)
        (lambda (&rest _) "src/lib.rs")))
    (should
     (equal
      (difftron--read-snapshot-arg 'lhs "/tmp/repo/" "HEAD")
      "/tmp/repo/src/lib.rs"))))

(ert-deftest difftron-read-snapshot-arg-allows-typed-revision ()
  (cl-letf
      (
       ((symbol-function 'magit-list-branch-names)
        (lambda () '("main")))
       ((symbol-function 'magit-git-lines)
        (lambda (&rest args)
          (pcase args
            (`("log" "--max-count=100" "--date=short" "--format=%h%x09%H%x09%an%x09%ad%x09%s")
             nil)
            (`("ls-files") nil)
            (_ (error "Unexpected git args: %S" args)))))
       ((symbol-function 'completing-read)
        (lambda (&rest _) "abc1234")))
    (should
     (equal
      (difftron--read-snapshot-arg 'rhs "/tmp/repo/" "HEAD")
      "abc1234"))))

(ert-deftest difftron-read-snapshot-arg-uses-default-on-empty-input ()
  (cl-letf
      (
       ((symbol-function 'magit-list-branch-names)
        (lambda () '("main")))
       ((symbol-function 'magit-git-lines)
        (lambda (&rest args)
          (pcase args
            (`("log" "--max-count=100" "--date=short" "--format=%h%x09%H%x09%an%x09%ad%x09%s")
             nil)
            (`("ls-files") nil)
            (_ (error "Unexpected git args: %S" args)))))
       ((symbol-function 'completing-read)
        (lambda (&rest _) "")))
    (should
     (equal
      (difftron--read-snapshot-arg 'lhs "/tmp/repo/" "HEAD")
      "HEAD"))))

(ert-deftest difftron-read-snapshot-arg-browses-file-path ()
  (let (read-file-prompt read-file-dir read-file-default)
    (cl-letf
        (
         ((symbol-function 'magit-list-branch-names)
          (lambda () '("main")))
         ((symbol-function 'magit-git-lines)
          (lambda (&rest args)
            (pcase args
              (`("log" "--max-count=100" "--date=short" "--format=%h%x09%H%x09%an%x09%ad%x09%s")
               nil)
              (`("ls-files") nil)
              (_ (error "Unexpected git args: %S" args)))))
         ((symbol-function 'completing-read)
          (lambda (&rest _) difftron--browse-path-choice))
         ((symbol-function 'read-file-name)
          (lambda (prompt dir default-filename &rest _)
            (setq read-file-prompt prompt)
            (setq read-file-dir dir)
            (setq read-file-default default-filename)
            "/tmp/repo/src/lib.rs"))
         ((symbol-function 'file-directory-p)
          (lambda (path) (equal path "/tmp/repo/src/"))))
      (should
       (equal
        (difftron--read-snapshot-arg
         'rhs
         "/tmp/repo/"
         "/tmp/repo/src/")
        "/tmp/repo/src/lib.rs")))
    (should (equal read-file-prompt "Right path: "))
    (should (equal read-file-dir "/tmp/repo/"))
    (should (equal read-file-default "/tmp/repo/src/"))))

(ert-deftest difftron-read-snapshot-arg-browses-directory-path ()
  (cl-letf
      (
       ((symbol-function 'magit-list-branch-names)
        (lambda () '("main")))
       ((symbol-function 'magit-git-lines)
        (lambda (&rest args)
          (pcase args
            (`("log" "--max-count=100" "--date=short" "--format=%h%x09%H%x09%an%x09%ad%x09%s")
             nil)
            (`("ls-files") nil)
            (_ (error "Unexpected git args: %S" args)))))
       ((symbol-function 'completing-read)
        (lambda (&rest _) difftron--browse-path-choice))
       ((symbol-function 'read-file-name)
        (lambda (&rest _) "/tmp/repo/src"))
       ((symbol-function 'file-directory-p)
        (lambda (path) (equal path "/tmp/repo/src"))))
    (should
     (equal
      (difftron--read-snapshot-arg 'lhs "/tmp/repo/" "HEAD")
      "/tmp/repo/src/"))))

(ert-deftest difftron-read-snapshot-arg-expands-typed-repo-path ()
  (let ((repo (file-name-as-directory
               (make-temp-file "difftron-path-" t))))
    (unwind-protect
        (let ((file (expand-file-name "src/lib.rs" repo)))
          (make-directory (file-name-directory file) t)
          (with-temp-file file
            (insert "fn main() {}\n"))
          (cl-letf
              (
               ((symbol-function 'magit-list-branch-names)
                (lambda () '("main")))
               ((symbol-function 'magit-git-lines)
                (lambda (&rest args)
                  (pcase args
                    (`("log" "--max-count=100" "--date=short" "--format=%h%x09%H%x09%an%x09%ad%x09%s")
                     nil)
                    (`("ls-files") nil)
                    (_ (error "Unexpected git args: %S" args)))))
               ((symbol-function 'completing-read)
                (lambda (&rest _) "src/lib.rs")))
            (should
             (equal
              (difftron--read-snapshot-arg
               'lhs
               repo
               "HEAD")
              file))))
      (delete-directory repo t))))

(ert-deftest difftron-read-snapshot-arg-prefers-ref-over-path ()
  (let ((repo (file-name-as-directory
               (make-temp-file "difftron-path-" t))))
    (unwind-protect
        (let ((file (expand-file-name "src/lib.rs" repo)))
          (make-directory (file-name-directory file) t)
          (with-temp-file file
            (insert "fn main() {}\n"))
          (cl-letf
              (
               ((symbol-function 'magit-list-branch-names)
                (lambda () '("src/lib.rs")))
               ((symbol-function 'magit-git-lines)
                (lambda (&rest args)
                  (pcase args
                    (`("log" "--max-count=100" "--date=short" "--format=%h%x09%H%x09%an%x09%ad%x09%s")
                     nil)
                    (`("ls-files") '("src/lib.rs"))
                    (_ (error "Unexpected git args: %S" args)))))
               ((symbol-function 'completing-read)
                (lambda (&rest _) "src/lib.rs")))
            (should
             (equal
              (difftron--read-snapshot-arg
               'lhs
               repo
               "HEAD")
              "src/lib.rs"))))
      (delete-directory repo t))))

(ert-deftest difftron-selects-left-git-revision ()
  (let
      (
       displayed-args
       read-prompt
       read-default
       read-collection)
    (cl-letf
	(
         ((symbol-function 'magit-list-branch-names)
          (lambda () '("feature")))
         ((symbol-function 'magit-git-lines)
          (lambda (&rest args)
            (pcase args
              (`("log" "--max-count=100" "--date=short" "--format=%h%x09%H%x09%an%x09%ad%x09%s")
               nil)
              (`("ls-files") nil)
              (_ (error "Unexpected git args: %S" args)))))
         ((symbol-function 'completing-read)
          (lambda (prompt collection &rest args)
            (setq read-prompt prompt)
            (setq read-collection collection)
            (setq read-default (nth 4 args))
            "feature"))
         ((symbol-function 'difftron--run-command)
          (lambda (_default-directory _args)
            difftron-tests--sample-payload))
         ((symbol-function 'difftron--display-buffer)
          (lambda (_default-directory args _payload)
            (setq displayed-args args))))
      (with-temp-buffer
        (difftron-mode)
        (setq difftron--default-directory "/tmp/repo/")
        (setq difftron--command-args
              '
              ("diff"
               "HEAD~1"
               "HEAD"
               "--format"
               "json"
               "--path"
               "src/lib.rs"))
        (setq difftron--payload
              (copy-tree difftron-tests--sample-payload))
        (difftron-select-left)))
    (should (equal read-prompt "Left snapshot: "))
    (should (equal read-default "HEAD~1"))
    (should (member "feature" (all-completions "" read-collection)))
    (should
     (member
      difftron--browse-path-choice
      (all-completions "" read-collection)))
    (should
     (equal
      displayed-args
      '
      ("diff"
       "feature"
       "HEAD"
       "--format"
       "json"
       "--path"
       "src/lib.rs")))))

(ert-deftest difftron-selects-right-directory ()
  (let
      (
       displayed-args
       snapshot-prompt
       path-prompt
       path-default)
    (cl-letf
	(
         ((symbol-function 'magit-list-branch-names)
          (lambda () '("main")))
         ((symbol-function 'magit-git-lines)
          (lambda (&rest args)
            (pcase args
              (`("log" "--max-count=100" "--date=short" "--format=%h%x09%H%x09%an%x09%ad%x09%s")
               nil)
              (`("ls-files") nil)
              (_ (error "Unexpected git args: %S" args)))))
         ((symbol-function 'completing-read)
          (lambda (prompt &rest _)
            (setq snapshot-prompt prompt)
            difftron--browse-path-choice))
         ((symbol-function 'read-file-name)
          (lambda (prompt _dir default-filename &rest _)
            (setq path-prompt prompt)
            (setq path-default default-filename)
            "/tmp/new-root"))
         ((symbol-function 'file-directory-p)
          (lambda (path) (equal path "/tmp/new-root")))
         ((symbol-function 'difftron--run-command)
          (lambda (_default-directory _args)
            difftron-tests--sample-payload))
         ((symbol-function 'difftron--display-buffer)
          (lambda (_default-directory args _payload)
            (setq displayed-args args))))
      (with-temp-buffer
        (difftron-mode)
        (setq difftron--default-directory "/tmp/repo/")
        (setq difftron--command-args
              '("diff" "HEAD~1" "/tmp/old-root" "--format" "json"))
        (setq difftron--payload
              (difftron-tests--diff-payload :lhs-rev "HEAD~1"))
        (plist-put
         difftron--payload
         :rhs (difftron-tests--directory-snapshot "/tmp/old-root"))
        (difftron-select-right)))
    (should (equal snapshot-prompt "Right snapshot: "))
    (should (equal path-prompt "Right path: "))
    (should (equal path-default "/tmp/old-root"))
    (should
     (equal
      displayed-args
      '("diff" "HEAD~1" "/tmp/new-root/" "--format" "json")))))

(ert-deftest difftron-selects-left-file ()
  (let
      (
       displayed-args
       snapshot-prompt
       path-prompt
       path-default)
    (cl-letf
	(
         ((symbol-function 'magit-list-branch-names)
          (lambda () '("main")))
         ((symbol-function 'magit-git-lines)
          (lambda (&rest args)
            (pcase args
              (`("log" "--max-count=100" "--date=short" "--format=%h%x09%H%x09%an%x09%ad%x09%s")
               nil)
              (`("ls-files") nil)
              (_ (error "Unexpected git args: %S" args)))))
         ((symbol-function 'completing-read)
          (lambda (prompt &rest _)
            (setq snapshot-prompt prompt)
            difftron--browse-path-choice))
         ((symbol-function 'read-file-name)
          (lambda (prompt _dir default-filename &rest _)
            (setq path-prompt prompt)
            (setq path-default default-filename)
            "/tmp/next.rs"))
         ((symbol-function 'file-directory-p)
          (lambda (_path) nil))
         ((symbol-function 'difftron--run-command)
          (lambda (_default-directory _args)
            difftron-tests--sample-payload))
         ((symbol-function 'difftron--display-buffer)
          (lambda (_default-directory args _payload)
            (setq displayed-args args))))
      (with-temp-buffer
        (difftron-mode)
        (setq difftron--default-directory "/tmp/repo/")
        (setq difftron--command-args
              '("diff" "/tmp/old.rs" "HEAD" "--format" "json"))
        (setq difftron--payload
              (copy-tree difftron-tests--sample-payload))
        (plist-put
         difftron--payload
         :lhs (difftron-tests--file-snapshot "/tmp/old.rs"))
        (difftron-select-left)))
    (should (equal snapshot-prompt "Left snapshot: "))
    (should (equal path-prompt "Left path: "))
    (should (equal path-default "/tmp/old.rs"))
    (should
     (equal
      displayed-args
      '("diff" "/tmp/next.rs" "HEAD" "--format" "json")))))

(ert-deftest difftron-swaps-sides-preserving-path-filters ()
  (let (displayed-args)
    (cl-letf
        (
         ((symbol-function 'difftron--run-command)
          (lambda (_default-directory _args)
            difftron-tests--sample-payload))
         ((symbol-function 'difftron--display-buffer)
          (lambda (_default-directory args _payload)
            (setq displayed-args args))))
      (with-temp-buffer
        (difftron-mode)
        (setq difftron--default-directory "/tmp/repo/")
        (setq difftron--command-args
              '
              ("diff"
               "HEAD~1"
               "HEAD"
               "--format"
               "json"
               "--path"
               "src/lib.rs"))
        (setq difftron--payload
              (copy-tree difftron-tests--sample-payload))
        (difftron-swap-sides)))
    (should
     (equal
      displayed-args
      '
      ("diff"
       "HEAD"
       "HEAD~1"
       "--format"
       "json"
       "--path"
       "src/lib.rs")))))

(ert-deftest difftron-side-selection-requires-payload ()
  (with-temp-buffer
    (difftron-mode)
    (should-error (difftron-select-left) :type 'user-error)
    (should-error (difftron-select-right) :type 'user-error)
    (should-error (difftron-swap-sides) :type 'user-error)))

(ert-deftest difftron-previous-commit-preserves-path-filters ()
  (let
      (
       displayed-args
       displayed-directory)
    (cl-letf
	(
         ((symbol-function 'magit-git-lines)
          (lambda (&rest args)
            (pcase args
              (`("rev-list" "-1" "--parents" "commit-c")
               '("commit-c commit-b"))
              (`("rev-list" "-1" "--parents" "commit-b")
               '("commit-b commit-a"))
              (_ (error "Unexpected git args: %S" args)))))
         ((symbol-function 'difftron--run-command)
          (lambda (_default-directory _args)
            difftron-tests--sample-payload))
         ((symbol-function 'difftron--display-buffer)
          (lambda (default-directory args _payload)
            (setq displayed-directory default-directory)
            (setq displayed-args args))))
      (with-temp-buffer
        (difftron-mode)
        (setq difftron--default-directory "/tmp/repo/")
        (setq difftron--command-args
              '
              ("diff"
               "commit-b"
               "commit-c"
               "--format"
               "json"
               "--path"
               "src/lib.rs"))
        (setq difftron--payload
              (difftron-tests--diff-payload
               :lhs-rev "commit-b"
               :rhs-rev "commit-c"))
        (difftron-previous-commit)))
    (should (equal displayed-directory "/tmp/repo/"))
    (should
     (equal
      displayed-args
      '
      ("diff"
       "commit-a"
       "commit-b"
       "--format"
       "json"
       "--path"
       "src/lib.rs")))))

(ert-deftest difftron-next-commit-walks-head-first-parent ()
  (let (displayed-args)
    (cl-letf
	(
         ((symbol-function 'magit-git-lines)
          (lambda (&rest args)
            (pcase args
              (
               `
               ("rev-list"
                "--first-parent"
                "--reverse"
                "commit-b..HEAD")
               '("commit-c" "commit-d"))
              (`("rev-list" "-1" "--parents" "commit-c")
               '("commit-c commit-b"))
              (_ (error "Unexpected git args: %S" args)))))
         ((symbol-function 'difftron--run-command)
          (lambda (_default-directory _args)
            difftron-tests--sample-payload))
         ((symbol-function 'difftron--display-buffer)
          (lambda (_default-directory args _payload)
            (setq displayed-args args))))
      (with-temp-buffer
        (difftron-mode)
        (setq difftron--default-directory "/tmp/repo/")
        (setq difftron--command-args
              '
              ("diff"
               "commit-a"
               "commit-b"
               "--format"
               "json"
               "--path"
               "src/lib.rs"
               "--path"
               "src/main.rs"))
        (setq difftron--payload
              (difftron-tests--diff-payload
               :lhs-rev "commit-a"
               :rhs-rev "commit-b"))
        (difftron-next-commit)))
    (should
     (equal
      displayed-args
      '
      ("diff"
       "commit-b"
       "commit-c"
       "--format"
       "json"
       "--path"
       "src/lib.rs"
       "--path"
       "src/main.rs")))))

(ert-deftest difftron-commit-navigation-requires-git-rhs ()
  (with-temp-buffer
    (difftron-mode)
    (setq difftron--payload
	  (list
           :command "diff"
           :rhs (list :kind "path" :label "/tmp/repo")))
    (should-error (difftron-previous-commit) :type 'user-error)
    (should-error (difftron-next-commit) :type 'user-error)))

(ert-deftest difftron-previous-commit-errors-at-root ()
  (cl-letf
      (
       ((symbol-function 'magit-git-lines)
        (lambda (&rest args)
          (pcase args
            (`("rev-list" "-1" "--parents" "commit-a") '("commit-a"))
            (_ (error "Unexpected git args: %S" args))))))
    (with-temp-buffer
      (difftron-mode)
      (setq difftron--payload
            (difftron-tests--diff-payload
             :lhs-rev "commit-a^"
             :rhs-rev "commit-a"))
      (should-error
       (difftron-previous-commit)
       :type 'user-error))))

(ert-deftest difftron-next-commit-errors-at-head ()
  (cl-letf
      (
       ((symbol-function 'magit-git-lines)
        (lambda (&rest args)
          (pcase args
            (
             `
             ("rev-list"
              "--first-parent"
              "--reverse"
              "commit-c..HEAD")
             nil)
            (_ (error "Unexpected git args: %S" args))))))
    (with-temp-buffer
      (difftron-mode)
      (setq difftron--payload
            (difftron-tests--diff-payload
             :lhs-rev "commit-b"
             :rhs-rev "commit-c"))
      (should-error
       (difftron-next-commit)
       :type 'user-error))))

(ert-deftest difftron-next-commit-resets-default-hierarchy-visibility ()
  (let*
      (
       (difftron-default-hierarchy '(kind file))
       (initial-payload (copy-tree difftron-tests--multi-file-payload))
       (next-payload (copy-tree difftron-tests--multi-file-payload)))
    (plist-put
     initial-payload
     :lhs (difftron-tests--git-revision "repo@commit-a" "commit-a"))
    (plist-put
     initial-payload
     :rhs (difftron-tests--git-revision "repo@commit-b" "commit-b"))
    (plist-put
     next-payload
     :lhs (difftron-tests--git-revision "repo@commit-b" "commit-b"))
    (plist-put
     next-payload
     :rhs (difftron-tests--git-revision "repo@commit-c" "commit-c"))
    (cl-letf
        (
         ((symbol-function 'magit-git-lines)
          (lambda (&rest args)
            (pcase args
              (
               `
               ("rev-list"
                "--first-parent"
                "--reverse"
                "commit-b..HEAD")
               '("commit-c"))
              (`("rev-list" "-1" "--parents" "commit-c")
               '("commit-c commit-b"))
              (_ (error "Unexpected git args: %S" args)))))
         ((symbol-function 'difftron--run-command)
          (lambda (_default-directory _args)
            next-payload))
         ((symbol-function 'pop-to-buffer)
          (lambda (&rest _) nil)))
      (with-temp-buffer
        (rename-buffer difftron-buffer-name t)
        (difftron-mode)
        (setq difftron--default-directory "/tmp/repo/")
        (setq difftron--command-args
              '("diff" "commit-a" "commit-b" "--format" "json"))
        (setq difftron--payload
              (difftron-tests--diff-payload
               :lhs-rev "commit-a"
               :rhs-rev "commit-b"))
        (difftron--display-buffer
         "/tmp/repo/"
         difftron--command-args
         initial-payload)
        (with-current-buffer difftron-buffer-name
          (magit-section-hide
           (cadr
            (difftron-tests--sections-of-type 'difftron-kind)))
          (setq difftron--temporary-expanded-entity
                (cons
                 (car
                  (difftron-tests--sections-of-type 'difftron-entity))
                 nil))
          (difftron-next-commit)
          (dolist (section
                   (append
                    (difftron-tests--sections-of-type 'difftron-kind)
                    (difftron-tests--sections-of-type 'difftron-file)))
            (should-not (oref section hidden))
            (should-not
             (difftron-tests--section-has-invisible-overlay-p
              section)))
          (dolist (section
                   (difftron-tests--sections-of-type 'difftron-entity))
            (should (oref section hidden))
            (should
             (difftron-tests--section-has-invisible-overlay-p
              section)))
          (should-not difftron--temporary-expanded-entity))))))

(ert-deftest difftron-refresh-preserves-magit-display-state ()
  (let ((difftron-default-hierarchy '(file)))
    (with-temp-buffer
      (rename-buffer difftron-buffer-name t)
      (difftron-mode)
      (setq difftron--default-directory "/tmp/repo/")
      (setq difftron--command-args '("diff" "HEAD~1" "HEAD"))
      (setq difftron--payload
            difftron-tests--refresh-payload)
      (setq difftron--hierarchy '(kind file))
      (let ((inhibit-read-only t))
        (difftron--insert-payload
         difftron-tests--refresh-payload))
      (let*
          (
           (root magit-root-section)
           (kind-section
            (difftron-tests--first-child-section
             root
             'difftron-kind))
           (file-section-b (nth 1 (oref kind-section children)))
           (file-section-c (nth 2 (oref kind-section children)))
           (entity-section-b (car (oref file-section-b children)))
           (entity-section-c (car (oref file-section-c children))))
        (magit-section-show kind-section)
        (magit-section-show file-section-b)
        (magit-section-show entity-section-b)
        (magit-section-show file-section-c)
        (magit-section-show entity-section-c)
        (goto-char (oref entity-section-c content))
        (search-forward "7")
        (backward-char 1)
        (let
            (
             (expected-point-line (line-number-at-pos))
             (expected-point-column (current-column)))
          (cl-letf
              (
               ((symbol-function 'difftron--run-command)
                (lambda (_default-directory _args)
                  difftron-tests--refresh-payload))
               ((symbol-function 'pop-to-buffer)
                (lambda (&rest _) nil)))
            (difftron-refresh))
          (let*
              (
               (new-root magit-root-section)
               (new-kind-section
                (difftron-tests--first-child-section
                 new-root
                 'difftron-kind))
               (new-file-section-a
                (nth 0 (oref new-kind-section children)))
               (new-file-section-b
                (nth 1 (oref new-kind-section children)))
               (new-file-section-c
                (nth 2 (oref new-kind-section children)))
               (new-entity-section-a
                (car (oref new-file-section-a children)))
               (new-entity-section-b
                (car (oref new-file-section-b children)))
               (new-entity-section-c
                (car (oref new-file-section-c children)))
               (actual-visibility
                (mapcar
                 (lambda (section)
                   (cons
                    (magit-section-ident section)
                    (oref section hidden)))
                 (list
                  new-kind-section
                  new-file-section-a
                  new-entity-section-a
                  new-file-section-b
                  new-entity-section-b
                  new-file-section-c
                  new-entity-section-c))))
            (should (equal difftron--hierarchy '(kind file)))
            (should
             (equal
              (car actual-visibility)
              (cons (magit-section-ident new-kind-section) nil)))
            (should (oref new-file-section-a hidden))
            (should (oref new-entity-section-a hidden))
            (should-not (oref new-file-section-b hidden))
            (should-not (oref new-entity-section-b hidden))
            (should-not (oref new-file-section-c hidden))
            (should-not (oref new-entity-section-c hidden))
            (should (equal (line-number-at-pos) expected-point-line))
            (should (equal (current-column) expected-point-column))
            (should
             (eq (magit-current-section) new-entity-section-c))))))))

(ert-deftest difftron-git-snapshots-are-expandable-sections ()
  (cl-letf
      (((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
    (difftron--display-buffer
     "/tmp/repo/"
     '("diff" "HEAD~1" "HEAD")
     difftron-tests--sample-payload))
  (with-current-buffer difftron-buffer-name
    (let ((lhs-section (difftron-tests--snapshot-section 'lhs)))
      (should lhs-section)
      (should (oref lhs-section hidden))
      (should
       (seq-some
        (lambda (overlay)
          (overlay-get overlay 'magit-vis-indicator))
        (overlays-in
         (oref lhs-section start)
         (oref lhs-section content)))))))

(ert-deftest difftron-tab-toggles-revision-details-at-point ()
  (difftron-tests--with-revision-repo
   (lambda (repo parent child parent-subject child-subject)
     (let
         (
          (payload
           (difftron-tests--payload-with-revisions
            repo
            child
            child
            child-subject
            child-subject)))
       (with-temp-buffer
         (difftron-mode)
         (setq difftron--default-directory repo)
         (let ((inhibit-read-only t))
           (difftron--insert-payload payload))
         (should-not (string-match-p "AuthorDate:" (buffer-string)))
         (goto-char (point-min))
         (search-forward "lhs: ")
         (difftron-toggle-section-or-message)
         (should-not
          (oref (difftron-tests--snapshot-section 'lhs) hidden))
         (should (string-match-p child (buffer-string)))
         (should (string-match-p "Author:     Codex <>" (buffer-string)))
         (should
          (string-match-p
           "AuthorDate: Tue Apr 28 16:51:46 2026 [+]0000"
           (buffer-string)))
         (should (string-match-p "Commit:     Codex <>" (buffer-string)))
         (should
          (string-match-p
           "CommitDate: Tue Apr 28 16:51:46 2026 [+]0000"
           (buffer-string)))
         (should
          (string-match-p
           (format
            "Parent:     %s %s"
            (substring parent 0 7)
            (regexp-quote parent-subject))
           (buffer-string)))
         (should (string-match-p "Contained:  master" (buffer-string)))
         (should (string-match-p child-subject (buffer-string)))
         (should
          (string-match-p
           "Expose Clojure namespaces vars and related forms"
           (buffer-string)))
         (difftron-toggle-section-or-message)
         (should
          (oref (difftron-tests--snapshot-section 'lhs) hidden)))))))

(ert-deftest difftron-commit-message-fold-does-not-hide-entity-area ()
  (difftron-tests--with-revision-repo
   (lambda (repo parent child parent-subject child-subject)
     (let
         (
          (payload
           (difftron-tests--payload-with-revisions
            repo
            parent
            child
            parent-subject
            child-subject)))
       (with-temp-buffer
         (difftron-mode)
         (setq difftron--default-directory repo)
         (let ((inhibit-read-only t))
           (difftron--insert-payload payload))
         (goto-char (point-min))
         (search-forward "lhs: ")
         (difftron-toggle-section-or-message)
         (let*
             (
              (lhs-section (difftron-tests--snapshot-section 'lhs))
              (message-section
               (difftron-tests--first-child-section
                lhs-section
                'commit-message))
              (entity-point
               (save-excursion
                 (goto-char (point-min))
                 (search-forward "+ demo::added")
                 (point))))
           (should message-section)
           (magit-section-hide message-section)
           (should-not
            (seq-some
             (lambda (overlay)
               (overlay-get overlay 'invisible))
             (overlays-at entity-point)))))))))

(ert-deftest difftron-m-toggles-all-revision-details ()
  (difftron-tests--with-revision-repo
   (lambda (repo parent child parent-subject child-subject)
     (let
         (
          (payload
           (difftron-tests--payload-with-revisions
            repo
            parent
            child
            parent-subject
            child-subject)))
       (with-temp-buffer
         (difftron-mode)
         (setq difftron--default-directory repo)
         (let ((inhibit-read-only t))
           (difftron--insert-payload payload))
         (difftron-toggle-commit-messages)
         (should-not
          (oref (difftron-tests--snapshot-section 'lhs) hidden))
         (should-not
          (oref (difftron-tests--snapshot-section 'rhs) hidden))
         (should (string-match-p parent-subject (buffer-string)))
         (should (string-match-p child-subject (buffer-string)))
         (should
          (string-match-p
           "AuthorDate: Tue Apr 28 16:50:00 2026 [+]0000"
           (buffer-string)))
         (should
          (string-match-p
           "CommitDate: Tue Apr 28 16:51:46 2026 [+]0000"
           (buffer-string)))
         (difftron-toggle-commit-messages)
         (should
          (oref (difftron-tests--snapshot-section 'lhs) hidden))
         (should
          (oref (difftron-tests--snapshot-section 'rhs) hidden)))))))

(ert-deftest difftron-faces-added-and-deleted-entities ()
  (let*
      (
       (payload
        (difftron-tests--diff-payload
         :added
         (list
          (difftron-tests--entity
           "demo::added"
           "function"
           "/tmp/repo/src/lib.rs"
           "src/lib.rs"
           "fn added() {}"
           :start-line 10
           :end-line 12
           :end-col 2
           :rendered-summary "function demo::added()"))
         :deleted
         (list
          (difftron-tests--entity
           "demo::deleted"
           "function"
           "/tmp/repo/src/lib.rs"
           "src/lib.rs"
           "fn deleted() {}"
           :start-line 20
           :end-line 22
           :end-col 2
           :rendered-summary "function demo::deleted()"))
         :modified nil)))
    (with-temp-buffer
      (difftron-mode)
      (let ((inhibit-read-only t))
        (difftron--insert-payload payload))
      (goto-char (point-min))
      (search-forward "+ demo::added")
      (should
       (eq
        (get-text-property (match-beginning 0) 'font-lock-face)
        'difftron-level-1-heading))
      (search-forward "fn added() {}")
      (should
       (eq
        (get-text-property (match-beginning 0) 'font-lock-face)
        'magit-diff-added))
      (goto-char (point-min))
      (search-forward "- demo::deleted")
      (should
       (eq
        (get-text-property (match-beginning 0) 'font-lock-face)
        'difftron-level-1-heading))
      (search-forward "fn deleted() {}")
      (should
       (eq
        (get-text-property (match-beginning 0) 'font-lock-face)
        'magit-diff-removed)))))

(ert-deftest difftron-renders-structured-modified-diff-faces ()
  (with-temp-buffer
    (difftron-mode)
    (let ((inhibit-read-only t))
      (difftron--insert-payload
       difftron-tests--sample-payload))
    (goto-char (point-min))
    (search-forward "41")
    (should
     (eq
      (get-text-property (match-beginning 0) 'font-lock-face)
      'magit-diff-context))
    (should
     (cl-some
      (lambda (overlay)
        (and (eq (overlay-get overlay 'diff-mode) 'fine)
             (eq (overlay-get overlay 'face) 'diff-refine-removed)))
      (overlays-at (match-beginning 0))))
    (goto-char (point-min))
    (search-forward "42")
    (should
     (eq
      (get-text-property (match-beginning 0) 'font-lock-face)
      'magit-diff-context))
    (should
     (cl-some
      (lambda (overlay)
        (and (eq (overlay-get overlay 'diff-mode) 'fine)
             (eq (overlay-get overlay 'face) 'diff-refine-added)))
      (overlays-at (match-beginning 0))))
    (goto-char (point-min))
    (search-forward "fn meaning")
    (should
     (eq
      (get-text-property (match-beginning 0) 'font-lock-face)
      'magit-diff-context))))

(ert-deftest difftron-diff-omits-width-for-json-output ()
  (cl-letf
      (
       ((symbol-function 'difftron--repo-root)
        (lambda () "/tmp/repo/"))
       ((symbol-function 'difftron--run-command)
        (lambda (_default-directory args)
          (should
           (equal
            args
            '
            ("diff"
             "HEAD~1"
             "HEAD"
             "--format"
             "json"
             "--path"
             "src/lib.rs")))
          difftron-tests--sample-payload))
       ((symbol-function 'difftron--display-buffer)
        (lambda (_default-directory _args _payload) nil)))
    (difftron-diff "HEAD~1" "HEAD" '("src/lib.rs"))))

(ert-deftest difftron-diff-interactive-does-not-read-paths ()
  (let (prompts defaults ran-args)
    (cl-letf
        (
         ((symbol-function 'difftron--repo-root)
          (lambda () "/tmp/repo/"))
         ((symbol-function 'magit-list-branch-names)
          (lambda () '("main")))
         ((symbol-function 'magit-git-lines)
          (lambda (&rest args)
            (pcase args
              (`("log" "--max-count=100" "--date=short" "--format=%h%x09%H%x09%an%x09%ad%x09%s")
               nil)
              (`("ls-files") nil)
              (_ (error "Unexpected git args: %S" args)))))
         ((symbol-function 'completing-read)
          (lambda (prompt _collection &rest args)
            (push prompt prompts)
            (push (nth 4 args) defaults)
            ""))
         ((symbol-function 'difftron--run-command)
          (lambda (_default-directory args)
            (setq ran-args args)
            difftron-tests--sample-payload))
         ((symbol-function 'difftron--display-buffer)
          (lambda (_default-directory _args _payload) nil)))
      (call-interactively #'difftron-diff))
    (should
     (equal
      (nreverse prompts)
      '("Left snapshot: " "Right snapshot: ")))
    (should
     (equal
      (nreverse defaults)
      '("HEAD" "/tmp/repo/")))
    (should
     (equal ran-args '("diff" "HEAD" "/tmp/repo/" "--format" "json")))))

(ert-deftest difftron-cycle-hierarchy-order ()
  (let ((difftron-default-hierarchy '(file)))
    (with-temp-buffer
      (difftron-mode)
      (setq difftron--default-directory "/tmp/repo/")
      (setq difftron--command-args '("diff" "HEAD~1" "HEAD"))
      (setq difftron--payload
	    difftron-tests--multi-file-payload)
      (setq difftron--hierarchy '(file))
      (cl-letf
	  (((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
	(difftron-cycle-hierarchy)
	(should (equal difftron-default-hierarchy '(kind)))
	(should (equal difftron--hierarchy '(kind)))
	(difftron-cycle-hierarchy)
	(should (equal difftron-default-hierarchy '(file kind)))
	(should (equal difftron--hierarchy '(file kind)))
	(difftron-cycle-hierarchy)
	(should (equal difftron-default-hierarchy '(kind file)))
	(should (equal difftron--hierarchy '(kind file)))
	(difftron-cycle-hierarchy)
	(should (equal difftron-default-hierarchy '(file)))
	(should (equal difftron--hierarchy '(file)))))))

(ert-deftest difftron-cycle-hierarchy-redraws-buffer ()
  (let ((difftron-default-hierarchy '(file)))
    (with-temp-buffer
      (difftron-mode)
      (setq difftron--default-directory "/tmp/repo/")
      (setq difftron--command-args '("diff" "HEAD~1" "HEAD"))
      (setq difftron--payload
	    difftron-tests--multi-file-payload)
      (setq difftron--hierarchy '(file))
      (cl-letf
	  (((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
	(difftron-cycle-hierarchy)
	(difftron-cycle-hierarchy))
      (with-current-buffer difftron-buffer-name
	(let*
            (
             (root magit-root-section)
             (file-section
              (difftron-tests--first-child-section
               root
               'difftron-file))
             (kind-section (car (oref file-section children)))
             (entity-section (car (oref kind-section children)))
             (text (buffer-string)))
          (should (equal difftron--hierarchy '(file kind)))
          (should-not (string-match-p "Grouping:" text))
          (should-not (oref file-section hidden))
          (should-not (oref kind-section hidden))
          (should (oref entity-section hidden)))))))

(ert-deftest difftron-dispatch-has-hierarchy-section ()
  (should (transient-get-suffix 'difftron-dispatch "y"))
  (should-not
   (ignore-errors
     (transient-get-suffix 'difftron-dispatch "t")))
  (should (transient-get-suffix 'difftron-dispatch "s")))

(ert-deftest difftron-hierarchy-infix-highlights-current-choice ()
  (with-temp-buffer
    (difftron-mode)
    (setq difftron--hierarchy '(file kind))
    (let*
        (
         (obj
          (difftron--hierarchy-infix
           :variable 'difftron--hierarchy))
         (value (transient-format-value obj)))
      (should (string-match-p "file > type" value))
      (should
       (eq
        (get-text-property
         (string-match "file > type" value)
         'face
         value)
        'transient-value))
      (should
       (eq
        (get-text-property
         (string-match "type > file" value)
         'face
         value)
        'transient-inactive-value)))))

(ert-deftest difftron-dispatch-transient-setup-succeeds ()
  (with-temp-buffer
    (difftron-mode)
    (transient-setup 'difftron-dispatch)))

(ert-deftest difftron-shortens-path-backed-diff-labels ()
  (with-temp-buffer
    (difftron-mode)
    (let ((inhibit-read-only t))
      (difftron--insert-payload
       (difftron-tests--diff-payload
        :lhs-label "/Users/dev/work/incubator/2026-04-21-diff@5767f35^"
        :rhs-label "/Users/dev/work/incubator/2026-04-21-diff@5767f35")))
    (should
     (string-prefix-p
      (concat
       "lhs: 2026-04-21-diff@5767f35^  Commit HEAD~1\n"
       "rhs: 2026-04-21-diff@5767f35  Commit HEAD\n\n")
      (buffer-string)))))

(ert-deftest difftron-renders-clickable-diff-snapshots ()
  (with-temp-buffer
    (difftron-mode)
    (let ((inhibit-read-only t))
      (difftron--insert-payload
       difftron-tests--sample-payload))
    (goto-char (point-min))
    (search-forward "repo@HEAD~1")
    (should (button-at (1- (point))))
    (search-forward "repo@HEAD")
    (should (button-at (1- (point))))))

(ert-deftest difftron-visits-git-revision-snapshot ()
  (let
      (
       visited-rev
       visited-directory)
    (cl-letf
	(
         ((symbol-function 'magit-show-commit)
          (lambda (rev &rest _)
            (setq visited-rev rev)
            (setq visited-directory default-directory))))
      (difftron--visit-snapshot
       (difftron-tests--git-revision "repo@HEAD~1" "HEAD~1")))
    (should (equal visited-rev "HEAD~1"))
    (should (equal visited-directory "/tmp/repo"))))

(ert-deftest difftron-ret-visits-diff-snapshot ()
  (let (visited-rev)
    (cl-letf
	(
         ((symbol-function 'magit-show-commit)
          (lambda (rev &rest _) (setq visited-rev rev))))
      (with-temp-buffer
        (difftron-mode)
        (let ((inhibit-read-only t))
          (difftron--insert-payload
           difftron-tests--sample-payload))
        (goto-char (point-min))
        (search-forward "rhs: ")
        (search-forward "repo@HEAD")
        (difftron-visit-thing)))
    (should (equal visited-rev "HEAD"))))

(defun difftron-tests--with-visit-capture (fn)
  "Call FN while capturing Magit file visits."
  (let
      (
       visited-rev
       visited-file
       visited-line
       visited-column
       shown-buffer
       (target-buffer (generate-new-buffer " *difftron-visited*")))
    (unwind-protect
        (progn
          (with-current-buffer target-buffer
            (insert
             (mapconcat
	      (lambda (_line)
                "abcdefghijklmnopqrstuvwxyz0123456789")
	      (number-sequence 1 80)
	      "\n")))
          (cl-letf
	      (
	       ((symbol-function 'magit-find-file-noselect)
                (lambda (rev file)
                  (setq visited-rev rev)
                  (setq visited-file file)
                  target-buffer))
	       ((symbol-function 'pop-to-buffer-same-window)
                (lambda (buffer &rest _)
                  (setq shown-buffer buffer)))
	       ((symbol-function 'magit-diff-visit-file--setup)
                (lambda (buffer pos)
                  (with-current-buffer buffer
                    (goto-char pos)
                    (setq visited-line (line-number-at-pos))
                    (setq visited-column (current-column))))))
            (funcall fn)
            (list
             :rev visited-rev
             :file visited-file
             :line visited-line
             :column visited-column
             :shown-buffer-name (buffer-name shown-buffer))))
      (kill-buffer target-buffer))))

(ert-deftest difftron-ret-on-left-structured-diff-visits-lhs-snapshot ()
  (let*
      (
       (payload
        (difftron-tests--diff-payload
         :lhs-rev "base-rev"
         :rhs-rev "topic-rev"
         :modified
         (list
          (difftron-tests--modified-change
           "src/lib.rs"
           (difftron-tests--entity
            "demo::meaning"
            "function"
            "/tmp/repo/src/lib.rs"
            "src/lib.rs"
            "fn meaning() -> u32 { 41 }"
            :start-line 10
            :start-col 3)
           (difftron-tests--entity
            "demo::meaning"
            "function"
            "/tmp/repo/src/lib.rs"
            "src/lib.rs"
            "fn meaning() -> u32 { 42 }"
            :start-line 20
            :start-col 5)
           "41"
           "42"))))
       (visit
        (difftron-tests--with-visit-capture
         (lambda ()
           (with-temp-buffer
             (difftron-mode)
             (let ((inhibit-read-only t))
	       (difftron--insert-payload payload))
             (goto-char (point-min))
             (search-forward "41")
             (goto-char (match-beginning 0))
             (difftron-visit-thing))))))
    (should (equal (plist-get visit :rev) "base-rev"))
    (should (equal (plist-get visit :file) "src/lib.rs"))
    (should (equal (plist-get visit :line) 10))
    (should (equal (plist-get visit :shown-buffer-name)
                   " *difftron-visited*"))))

(ert-deftest difftron-ret-on-right-structured-diff-visits-rhs-snapshot ()
  (let*
      (
       (payload
        (difftron-tests--diff-payload
         :lhs-rev "base-rev"
         :rhs-rev "topic-rev"
         :modified
         (list
          (difftron-tests--modified-change
           "src/lib.rs"
           (difftron-tests--entity
            "demo::meaning"
            "function"
            "/tmp/repo/src/lib.rs"
            "src/lib.rs"
            "fn meaning() -> u32 { 41 }"
            :start-line 10
            :start-col 3)
           (difftron-tests--entity
            "demo::meaning"
            "function"
            "/tmp/repo/src/lib.rs"
            "src/lib.rs"
            "fn meaning() -> u32 { 42 }"
            :start-line 20
            :start-col 5)
           "41"
           "42"))))
       (visit
        (difftron-tests--with-visit-capture
         (lambda ()
           (with-temp-buffer
             (difftron-mode)
             (let ((inhibit-read-only t))
	       (difftron--insert-payload payload))
             (goto-char (point-min))
             (search-forward "42")
             (goto-char (match-beginning 0))
             (difftron-visit-thing))))))
    (should (equal (plist-get visit :rev) "topic-rev"))
    (should (equal (plist-get visit :file) "src/lib.rs"))
    (should (equal (plist-get visit :line) 20))))

(ert-deftest difftron-ret-after-right-structured-diff-text-keeps-row-line ()
  (let*
      (
       (lhs
        (difftron-tests--entity
         "demo::meaning"
         "function"
         "/tmp/repo/src/lib.rs"
         "src/lib.rs"
         "line 1\nold line\nline 3"
         :start-line 10))
       (rhs
        (difftron-tests--entity
         "demo::meaning"
         "function"
         "/tmp/repo/src/lib.rs"
         "src/lib.rs"
         "line 1\nnew line\nline 3"
         :start-line 20))
       (change
        (list
         :path "src/lib.rs"
         :lhs lhs
         :rhs rhs
         :diff
         (list
          :rows
          (list
           (list
            :kind "replaced_code"
            :left
            (list
             :line_number 2
             :text "old line"
             :segments
             (list (list :text "old line" :kind "novel")))
            :right
            (list
             :line_number 2
             :text "new line"
             :segments
             (list (list :text "new line" :kind "novel"))))))))
       (payload
        (difftron-tests--diff-payload
         :lhs-rev "base-rev"
         :rhs-rev "topic-rev"
         :modified
         (list change)))
       (visit
        (difftron-tests--with-visit-capture
         (lambda ()
           (with-temp-buffer
             (difftron-mode)
             (let ((inhibit-read-only t))
	       (difftron--insert-payload payload))
             (goto-char (point-min))
             (search-forward "new line")
             (difftron-visit-thing))))))
    (should (equal (plist-get visit :rev) "topic-rev"))
    (should (equal (plist-get visit :file) "src/lib.rs"))
    (should (equal (plist-get visit :line) 21))))

(ert-deftest difftron-ret-on-modified-heading-defaults-to-rhs-snapshot ()
  (let*
      (
       (payload
        (difftron-tests--diff-payload
         :lhs-rev "base-rev"
         :rhs-rev "topic-rev"
         :modified
         (list
          (difftron-tests--modified-change
           "src/lib.rs"
           (difftron-tests--entity
            "demo::meaning"
            "function"
            "/tmp/repo/src/lib.rs"
            "src/lib.rs"
            "fn meaning() -> u32 { 41 }"
            :start-line 10)
           (difftron-tests--entity
            "demo::meaning"
            "function"
            "/tmp/repo/src/lib.rs"
            "src/lib.rs"
            "fn meaning() -> u32 { 42 }"
            :start-line 20)
           "41"
           "42"))))
       (visit
        (difftron-tests--with-visit-capture
         (lambda ()
           (with-temp-buffer
             (difftron-mode)
             (let ((inhibit-read-only t))
	       (difftron--insert-payload payload))
             (goto-char (point-min))
             (search-forward "M demo::meaning")
             (goto-char (match-beginning 0))
             (difftron-visit-thing))))))
    (should (equal (plist-get visit :rev) "topic-rev"))
    (should (equal (plist-get visit :file) "src/lib.rs"))
    (should (equal (plist-get visit :line) 20))))

(ert-deftest difftron-checkout-visit-bindings-match-magit ()
  (should
   (eq
    (lookup-key difftron-mode-map (kbd "C-<return>"))
    #'difftron-visit-thing-in-checkout))
  (should
   (eq
    (lookup-key difftron-mode-map (kbd "C-j"))
    #'difftron-visit-thing-in-checkout)))

(defun difftron-tests--with-checkout-visit-capture
    (diff-payload list-payload fn)
  "Call FN while capturing checkout file visits."
  (let
      (
       run-args
       visited-file
       shown-buffer
       (target-buffer (generate-new-buffer " *difftron-checkout-visited*")))
    (unwind-protect
        (progn
          (with-current-buffer target-buffer
            (insert
             (mapconcat
	      (lambda (_line)
                "abcdefghijklmnopqrstuvwxyz0123456789")
	      (number-sequence 1 80)
	      "\n")))
          (cl-letf
	      (
	       ((symbol-function 'difftron--run-command)
                (lambda (_default-directory args)
                  (push args run-args)
                  (pcase (car args)
                    ("diff" diff-payload)
                    ("list" list-payload)
                    (_ (error "Unexpected difftron command: %S" args)))))
	       ((symbol-function 'find-file-noselect)
                (lambda (file &rest _)
                  (setq visited-file file)
                  target-buffer))
	       ((symbol-function 'pop-to-buffer-same-window)
                (lambda (buffer &rest _)
                  (setq shown-buffer buffer))))
            (funcall fn)
            (with-current-buffer target-buffer
              (list
               :run-args (nreverse run-args)
               :file visited-file
               :line (line-number-at-pos)
               :column (current-column)
               :shown-buffer-name (buffer-name shown-buffer)))))
      (kill-buffer target-buffer))))

(ert-deftest difftron-control-enter-visits-current-checkout-entity-line ()
  (let*
      (
       (base
        (difftron-tests--entity
         "demo::meaning"
         "function"
         "/tmp/repo/src/lib.rs"
         "src/lib.rs"
         "line 1\nold line\nline 3"
         :start-line 10))
       (topic
        (difftron-tests--entity
         "demo::meaning"
         "function"
         "/tmp/repo/src/lib.rs"
         "src/lib.rs"
         "line 1\nright line\nline 3"
         :start-line 20))
       (current
        (difftron-tests--entity
         "demo::meaning"
         "function"
         "/tmp/repo/src/lib.rs"
         "src/lib.rs"
         "line 1\ncurrent line\npadding\nline 3"
         :start-line 30))
       (display-change
        (difftron-tests--modified-change
         "src/lib.rs"
         base
         topic
         "old"
         "right"))
       (checkout-change
        (list
         :path "src/lib.rs"
         :lhs base
         :rhs current
         :diff
         (list
          :rows
          (list
           (list
            :kind "replaced_code"
            :left
            (list
             :line_number 2
             :text "old line"
             :segments
             (list (list :text "old line" :kind "novel")))
            :right
            (list
             :line_number 4
             :text "line 3"
             :segments
             (list (list :text "line 3" :kind "context"))))))))
       (display-payload
	(difftron-tests--diff-payload
	 :lhs-rev "base-rev"
	 :rhs-rev "topic-rev"
	 :modified (list display-change)))
       (checkout-payload
	(difftron-tests--diff-payload
	 :lhs-rev "base-rev"
	 :rhs-label "/tmp/repo"
	 :rhs-rev nil
	 :modified (list checkout-change)))
       (visit
	(difftron-tests--with-checkout-visit-capture
	 checkout-payload
	 nil
	 (lambda ()
           (with-temp-buffer
             (difftron-mode)
             (setq difftron--default-directory "/tmp/repo/")
             (setq difftron--payload display-payload)
             (let ((inhibit-read-only t))
	       (difftron--insert-payload display-payload))
             (goto-char (point-min))
             (search-forward "old line")
             (goto-char (match-beginning 0))
             (difftron-visit-thing-in-checkout))))))
    (should
     (equal
      (car (plist-get visit :run-args))
      '("diff" "base-rev" "." "--format" "json")))
    (should (equal (plist-get visit :file) "/tmp/repo/src/lib.rs"))
    (should (equal (plist-get visit :line) 33))
    (should (equal (plist-get visit :shown-buffer-name)
		   " *difftron-checkout-visited*"))))

(ert-deftest difftron-control-enter-follows-moved-entity-to-checkout ()
  (let*
      (
       (old
        (difftron-tests--entity
         "demo::meaning"
         "function"
         "/tmp/repo/src/old.rs"
         "src/old.rs"
         "fn meaning() {}"
         :start-line 5))
       (historical-new
        (difftron-tests--entity
         "demo::meaning"
         "function"
         "/tmp/repo/src/new.rs"
         "src/new.rs"
         "fn meaning() {}"
         :start-line 9))
       (current
        (difftron-tests--entity
         "demo::meaning"
         "function"
         "/tmp/repo/src/current.rs"
         "src/current.rs"
         "fn meaning() {}"
         :start-line 12))
       (display-payload
        (difftron-tests--diff-payload
         :lhs-rev "base-rev"
         :rhs-rev "topic-rev"
         :moved
         (list (difftron-tests--moved-change old historical-new))))
       (checkout-payload
        (difftron-tests--diff-payload
         :lhs-rev "base-rev"
         :moved
         (list (difftron-tests--moved-change old current))))
       (visit
        (difftron-tests--with-checkout-visit-capture
         checkout-payload
         nil
         (lambda ()
           (with-temp-buffer
             (difftron-mode)
             (setq difftron--default-directory "/tmp/repo/")
             (setq difftron--payload display-payload)
             (let ((inhibit-read-only t))
	       (difftron--insert-payload display-payload))
             (goto-char (point-min))
             (search-forward "moved to")
             (goto-char (line-beginning-position))
             (difftron-visit-thing-in-checkout))))))
    (should (equal (plist-get visit :file) "/tmp/repo/src/current.rs"))
    (should (equal (plist-get visit :line) 12))))

(ert-deftest difftron-control-enter-errors-when-entity-is-deleted-in-checkout ()
  (let*
      (
       (entity
        (difftron-tests--entity
         "demo::meaning"
         "function"
         "/tmp/repo/src/lib.rs"
         "src/lib.rs"
         "fn meaning() {}"))
       (display-payload
        (difftron-tests--diff-payload
         :lhs-rev "base-rev"
         :rhs-rev "topic-rev"
         :deleted (list entity)))
       (checkout-payload
        (difftron-tests--diff-payload
         :lhs-rev "base-rev"
         :deleted (list entity))))
    (difftron-tests--with-checkout-visit-capture
     checkout-payload
     nil
     (lambda ()
       (with-temp-buffer
         (difftron-mode)
         (setq difftron--default-directory "/tmp/repo/")
         (setq difftron--payload display-payload)
         (let ((inhibit-read-only t))
	   (difftron--insert-payload display-payload))
         (goto-char (point-min))
         (search-forward "- demo::meaning")
         (goto-char (match-beginning 0))
         (should-error
          (difftron-visit-thing-in-checkout)
          :type 'user-error))))))

(ert-deftest difftron-control-enter-falls-back-to-list-for-unchanged-entity ()
  (let*
      (
       (historical
        (difftron-tests--entity
         "demo::meaning"
         "function"
         "/tmp/repo/src/lib.rs"
         "src/lib.rs"
         "fn meaning() {}"
         :start-line 8))
       (current
        (difftron-tests--entity
         "demo::meaning"
         "function"
         "/tmp/repo/src/lib.rs"
         "src/lib.rs"
         "fn meaning() {}"
         :start-line 18))
       (display-payload
        (difftron-tests--diff-payload
         :lhs-rev "base-rev"
         :rhs-rev "topic-rev"
         :added (list historical)))
       (checkout-payload
        (difftron-tests--diff-payload
         :lhs-rev "topic-rev"))
       (list-payload
        (list
         :command "list"
         :entity_kind_order difftron-tests--entity-kind-order
         :entity_kinds difftron-tests--entity-kinds
         :snapshot (difftron-tests--directory-snapshot "/tmp/repo")
         :entities (list current)))
       (visit
        (difftron-tests--with-checkout-visit-capture
         checkout-payload
         list-payload
         (lambda ()
           (with-temp-buffer
             (difftron-mode)
             (setq difftron--default-directory "/tmp/repo/")
             (setq difftron--payload display-payload)
             (let ((inhibit-read-only t))
	       (difftron--insert-payload display-payload))
             (goto-char (point-min))
             (search-forward "+ demo::meaning")
             (goto-char (match-beginning 0))
             (difftron-visit-thing-in-checkout))))))
    (should
     (equal
      (plist-get visit :run-args)
      '(("diff" "topic-rev" "." "--format" "json")
	("list" "." "--format" "json"))))
    (should (equal (plist-get visit :file) "/tmp/repo/src/lib.rs"))
    (should (equal (plist-get visit :line) 18))))

(ert-deftest difftron-dwim-endpoints-from-commit ()
  (should
   (equal
    (difftron--dwim-endpoints
     '(commit . "HEAD~2")
     "/tmp/repo")
    '("HEAD~2^" "HEAD~2"))))

(ert-deftest difftron-dwim-endpoints-from-range ()
  (should
   (equal
    (difftron--dwim-endpoints "main..feature" "/tmp/repo")
    '("main" "feature")))
  (should
   (equal
    (difftron--dwim-endpoints "HEAD" "/tmp/repo")
    '("HEAD" "/tmp/repo"))))

(ert-deftest difftron-dwim-endpoints-from-worktree-context ()
  (should
   (equal
    (difftron--dwim-endpoints 'unstaged "/tmp/repo")
    '("HEAD" "/tmp/repo")))
  (should
   (equal
    (difftron--dwim-endpoints nil "/tmp/repo")
    '("HEAD" "/tmp/repo"))))

(ert-deftest difftron-bindings-mode-registers-magit-suffix ()
  (require 'magit-diff)
  (unwind-protect
      (progn
	(difftron-bindings-mode 1)
	(should (transient-get-suffix 'magit-diff "D")))
    (difftron-bindings-mode -1)))

(ert-deftest difftron-bindings-mode-registers-magit-diff-key ()
  (require 'magit-diff)
  (unwind-protect
      (progn
	(difftron-bindings-mode 1)
	(should
         (eq
          (lookup-key magit-diff-mode-map (kbd "D"))
          #'difftron-diff-at-point))
	(should
         (eq
          (lookup-key magit-diff-section-map (kbd "D"))
          #'difftron-diff-at-point)))
    (difftron-bindings-mode -1)))

(ert-deftest difftron-diff-at-point-jumps-to-current-entity ()
  (let (ran-args)
    (cl-letf
	(
         ((symbol-function 'difftron--repo-root)
          (lambda () "/tmp/repo/"))
         ((symbol-function 'magit-diff-arguments)
          (lambda (&rest _) (list '("--stat") nil)))
         ((symbol-function 'magit-diff--dwim)
          (lambda () "HEAD~1..HEAD"))
         ((symbol-function 'difftron--magit-diff-path-at-point)
          (lambda () "src/lib.rs"))
         ((symbol-function 'difftron--magit-diff-line-at-point)
          (lambda () 10))
         ((symbol-function 'difftron--run-command)
          (lambda (_default-directory args)
            (setq ran-args args)
            difftron-tests--sample-payload))
         ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (difftron-diff-at-point))
    (should
     (equal
      ran-args
      '
      ("diff"
       "HEAD~1"
       "HEAD"
       "--format"
       "json"
       "--path"
       "src/lib.rs")))
    (with-current-buffer difftron-buffer-name
      (let ((section (magit-current-section)))
        (should (equal (oref section type) 'difftron-entity))
        (should
         (equal
          (plist-get (oref section value) :summary)
          "+ demo::added"))
        (should-not (oref section hidden))))))

(ert-deftest difftron-diff-dwim-obeys-magit-path-toggle ()
  (let (selected-paths)
    (cl-letf
        (
         ((symbol-function 'difftron--repo-root)
          (lambda () "/tmp/repo/"))
         ((symbol-function 'magit-diff-arguments)
          (lambda (&rest _) (list nil '("src/lib.rs"))))
         ((symbol-function 'magit-diff--dwim)
          (lambda () "HEAD~1..HEAD"))
         ((symbol-function 'difftron-diff)
          (lambda (_lhs _rhs paths)
            (setq selected-paths paths))))
      (let ((difftron-use-magit-paths t))
        (difftron-diff-dwim))
      (should (equal selected-paths '("src/lib.rs")))
      (let ((difftron-use-magit-paths nil))
        (difftron-diff-dwim))
      (should-not selected-paths))))

(ert-deftest difftron-diff-at-point-omits-path-when-toggle-off ()
  (let (ran-args)
    (cl-letf
        (
         ((symbol-function 'difftron--repo-root)
          (lambda () "/tmp/repo/"))
         ((symbol-function 'magit-diff-arguments)
          (lambda (&rest _) (list nil '("src/other.rs"))))
         ((symbol-function 'magit-diff--dwim)
          (lambda () "HEAD~1..HEAD"))
         ((symbol-function 'difftron--magit-diff-path-at-point)
          (lambda () "src/lib.rs"))
         ((symbol-function 'difftron--magit-diff-line-at-point)
          (lambda () 10))
         ((symbol-function 'difftron--run-command)
          (lambda (_default-directory args)
            (setq ran-args args)
            difftron-tests--sample-payload))
         ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (let ((difftron-use-magit-paths nil))
        (difftron-diff-at-point)))
    (should
     (equal ran-args '("diff" "HEAD~1" "HEAD" "--format" "json")))
    (with-current-buffer difftron-buffer-name
      (let ((section (magit-current-section)))
        (should (equal (oref section type) 'difftron-entity))
        (should-not (oref section hidden))))))

(ert-deftest difftron-bindings-mode-registers-after-magit-load
    ()
  (when (featurep 'magit-diff)
    (unload-feature 'magit-diff t))
  (unwind-protect
      (progn
	(difftron-bindings-mode 1)
	(should-not (featurep 'magit-diff))
	(require 'magit-diff)
	(should (transient-get-suffix 'magit-diff "D")))
    (difftron-bindings-mode -1)))

(ert-deftest difftron-bindings-mode-unregisters-magit-suffix ()
  (require 'magit-diff)
  (difftron-bindings-mode 1)
  (difftron-bindings-mode -1)
  (should-not
   (ignore-errors
     (transient-get-suffix 'magit-diff "D")))
  (should-not (difftron--magit-diff-suffix-p "D")))

(ert-deftest difftron-bindings-mode-unregisters-magit-diff-key
    ()
  (require 'magit-diff)
  (difftron-bindings-mode 1)
  (difftron-bindings-mode -1)
  (should-not
   (eq
    (lookup-key magit-diff-mode-map (kbd "D"))
    #'difftron-diff-at-point))
  (should-not
   (eq
    (lookup-key magit-diff-section-map (kbd "D"))
    #'difftron-diff-at-point)))

(provide 'difftron-tests)

;;; difftron-tests.el ends here
