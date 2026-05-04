;;; difftron-magit-tests.el --- Tests for difftron-magit  -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)

(add-to-list
 'load-path
 (file-name-directory (or load-file-name buffer-file-name)))
(require 'difftron-magit)

(defvar difftron-magit-tests--sample-payload)

(defconst difftron-magit-tests--entity-kind-order
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

(defconst difftron-magit-tests--entity-kinds
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

(defun difftron-magit-tests--git-revision (label rev)
  (list
   :label label
   :kind "git_revision"
   :root "/tmp/repo"
   :rev rev
   :summary (format "Commit %s" rev)))

(defun difftron-magit-tests--git-revision-in-repo
    (repo label rev summary)
  (list
   :label label
   :kind "git_revision"
   :root repo
   :rev rev
   :summary summary))

(defun difftron-magit-tests--directory-snapshot (path)
  (list :label path :kind "directory" :root path))

(defun difftron-magit-tests--file-snapshot (path)
  (list :label path :kind "file" :root path))

(defun difftron-magit-tests--snapshot-section (side)
  (seq-find
   (lambda (section)
     (and
      (eq (oref section type) 'difftron-snapshot)
      (eq (oref section value) side)))
   (oref magit-root-section children)))

(defun difftron-magit-tests--first-child-section (parent type)
  (seq-find
   (lambda (section)
     (eq (oref section type) type))
   (oref parent children)))

(defun difftron-magit-tests--section-has-invisible-overlay-p
    (section)
  "Return non-nil when SECTION's body has a hiding overlay."
  (when-let ((content (oref section content)))
    (seq-some
     (lambda (overlay)
       (overlay-get overlay 'invisible))
     (overlays-at content))))

(defconst difftron-magit-tests--repo-git-env-regexp
  "\\`GIT_\\(DIR\\|WORK_TREE\\|INDEX_FILE\\|OBJECT_DIRECTORY\\|ALTERNATE_OBJECT_DIRECTORIES\\|CEILING_DIRECTORIES\\|PREFIX\\)=")

(defun difftron-magit-tests--git (repo &rest args)
  "Run Git with ARGS in REPO and return stdout."
  (with-temp-buffer
    (let
        (
         (process-environment
          (seq-remove
           (lambda (entry)
             (string-match-p
              difftron-magit-tests--repo-git-env-regexp
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

(defun difftron-magit-tests--write-file (repo path contents)
  "Write CONTENTS to PATH under REPO."
  (let ((file (expand-file-name path repo)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert contents))))

(defun difftron-magit-tests--commit
    (repo path contents subject body date)
  "Create a commit in REPO and return its full hash."
  (difftron-magit-tests--write-file repo path contents)
  (difftron-magit-tests--git repo "add" path)
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
    (difftron-magit-tests--git
     repo
     "commit"
     "--no-verify"
     "-m"
     subject
     "-m"
     body))
  (difftron-magit-tests--git repo "rev-parse" "HEAD"))

(defun difftron-magit-tests--with-revision-repo (fn)
  "Call FN with a temporary Git repo and two deterministic revisions."
  (let ((repo (file-name-as-directory
               (make-temp-file "difftron-magit-repo-" t))))
    (unwind-protect
        (progn
          (difftron-magit-tests--git repo "init" "-q")
          (difftron-magit-tests--git
           repo
           "symbolic-ref"
           "HEAD"
           "refs/heads/master")
          (let*
              (
               (parent-subject "Move entity kind labels into JSON")
               (child-subject "Add Clojure entity kind metadata")
               (parent
                (difftron-magit-tests--commit
                 repo
                 "README.md"
                 "parent\n"
                 parent-subject
                 "Parent body."
                 "Tue Apr 28 16:50:00 2026 +0000"))
               (child
                (difftron-magit-tests--commit
                 repo
                 "README.md"
                 "child\n"
                 child-subject
                 "Expose Clojure namespaces vars and related forms through the normalized kind table."
                 "Tue Apr 28 16:51:46 2026 +0000")))
            (funcall fn repo parent child parent-subject child-subject)))
      (delete-directory repo t))))

(defun difftron-magit-tests--payload-with-revisions
    (repo lhs-rev rhs-rev lhs-summary rhs-summary)
  "Return the sample payload with Git revisions from REPO."
  (let ((payload (copy-sequence difftron-magit-tests--sample-payload)))
    (setq
     payload
     (plist-put
      payload
      :lhs
      (difftron-magit-tests--git-revision-in-repo
       repo
       (format "repo@%s" (substring lhs-rev 0 7))
       lhs-rev
       lhs-summary)))
    (plist-put
     payload
     :rhs
     (difftron-magit-tests--git-revision-in-repo
      repo
      (format "repo@%s" (substring rhs-rev 0 7))
      rhs-rev
      rhs-summary))))

(cl-defun
    difftron-magit-tests--entity
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

(defun difftron-magit-tests--segments (text novel)
  (let ((match (string-match (regexp-quote novel) text)))
    (list
     (list :text (substring text 0 match) :kind "context")
     (list :text novel :kind "novel")
     (list
      :text (substring text (+ match (length novel)))
      :kind "context"))))

(defun difftron-magit-tests--side (text novel)
  (list
   :line_number 1
   :text text
   :segments (difftron-magit-tests--segments text novel)))

(defun difftron-magit-tests--modified-change
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
      (difftron-magit-tests--side
       (plist-get lhs :source_text)
       lhs-novel)
      :right
      (difftron-magit-tests--side
       (plist-get rhs :source_text)
       rhs-novel))))))

(defun difftron-magit-tests--moved-change (lhs rhs)
  (list :lhs lhs :rhs rhs))

(defun difftron-magit-tests--moved-modified-change (lhs rhs)
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
      (difftron-magit-tests--side
       (plist-get lhs :source_text)
       "old_location")
      :right
      (difftron-magit-tests--side
       (plist-get rhs :source_text)
       "new_location"))))))

(cl-defun
    difftron-magit-tests--diff-payload
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
   :entity_kind_order difftron-magit-tests--entity-kind-order
   :entity_kinds difftron-magit-tests--entity-kinds
   :lhs (difftron-magit-tests--git-revision lhs-label lhs-rev)
   :rhs (difftron-magit-tests--git-revision rhs-label rhs-rev)
   :added added
   :deleted deleted
   :moved moved
   :moved_modified moved-modified
   :modified modified))

(defconst difftron-magit-tests--sample-payload
  (let*
      (
       (added
        (difftron-magit-tests--entity
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
        (difftron-magit-tests--entity
         "demo::meaning"
         "function"
         "/tmp/repo/src/lib.rs"
         "src/lib.rs"
         "fn meaning() -> u32 { 41 }"
         :rendered-summary "function demo::meaning() @ /tmp/repo/src/lib.rs:1:1-1:10"))
       (rhs
        (difftron-magit-tests--entity
         "demo::meaning"
         "function"
         "/tmp/repo/src/lib.rs"
         "src/lib.rs"
         "fn meaning() -> u32 { 42 }"
         :rendered-summary "function demo::meaning() @ /tmp/repo/src/lib.rs:1:1-1:10")))
    (difftron-magit-tests--diff-payload
     :added (list added)
     :deleted nil
     :modified
     (list
      (difftron-magit-tests--modified-change
       "src/lib.rs"
       lhs
       rhs
       "41"
       "42")))))

(defconst difftron-magit-tests--multi-file-payload
  (let*
      (
       (added
        (difftron-magit-tests--entity
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
        (difftron-magit-tests--entity
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
        (difftron-magit-tests--entity
         "demo::meaning"
         "function"
         "/tmp/repo/src/b.rs"
         "src/b.rs"
         "fn meaning() -> u32 { 41 }"
         :rendered-summary "function demo::meaning()"))
       (rhs
        (difftron-magit-tests--entity
         "demo::meaning"
         "function"
         "/tmp/repo/src/b.rs"
         "src/b.rs"
         "fn meaning() -> u32 { 42 }"
         :rendered-summary "function demo::meaning()")))
    (difftron-magit-tests--diff-payload
     :added (list added)
     :deleted (list deleted)
     :modified
     (list
      (difftron-magit-tests--modified-change
       "src/b.rs"
       lhs
       rhs
       "41"
       "42")))))

(defconst difftron-magit-tests--refresh-payload
  (let*
      (
       (added
        (difftron-magit-tests--entity
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
        (difftron-magit-tests--entity
         "demo::beta"
         "function"
         "/tmp/repo/src/b.rs"
         "src/b.rs"
         "fn beta() -> u32 { 41 }"
         :rendered-summary "function demo::beta()"))
       (beta-rhs
        (difftron-magit-tests--entity
         "demo::beta"
         "function"
         "/tmp/repo/src/b.rs"
         "src/b.rs"
         "fn beta() -> u32 { 42 }"
         :rendered-summary "function demo::beta()"))
       (gamma-lhs
        (difftron-magit-tests--entity
         "demo::gamma"
         "function"
         "/tmp/repo/src/c.rs"
         "src/c.rs"
         "fn gamma() -> u32 { 7 }"
         :rendered-summary "function demo::gamma()"))
       (gamma-rhs
        (difftron-magit-tests--entity
         "demo::gamma"
         "function"
         "/tmp/repo/src/c.rs"
         "src/c.rs"
         "fn gamma() -> u32 { 8 }"
         :rendered-summary "function demo::gamma()")))
    (difftron-magit-tests--diff-payload
     :added (list added)
     :deleted nil
     :modified
     (list
      (difftron-magit-tests--modified-change
       "src/b.rs"
       beta-lhs
       beta-rhs
       "41"
       "42")
      (difftron-magit-tests--modified-change
       "src/c.rs"
       gamma-lhs
       gamma-rhs
       "7"
       "8")))))

(ert-deftest difftron-magit-groups-items-by-kind ()
  (let*
      (
       (items
        (difftron-magit--diff-items
         difftron-magit-tests--sample-payload))
       (grouped (difftron-magit--group-items-by-kind items)))
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

(ert-deftest difftron-magit-groups-items-by-file ()
  (let*
      (
       (items
        (difftron-magit--diff-items
         difftron-magit-tests--multi-file-payload))
       (grouped (difftron-magit--group-items-by-file items)))
    (should (equal (mapcar #'car grouped) '("src/a.rs" "src/b.rs")))))

(ert-deftest difftron-magit-renders-moved-items ()
  (let*
      (
       (lhs
        (difftron-magit-tests--entity
         "demo::old::moved"
         "function"
         "/tmp/repo/src/old.rs"
         "src/old.rs"
         "fn moved() { old_location(); }"))
       (rhs
        (difftron-magit-tests--entity
         "demo::new::moved"
         "function"
         "/tmp/repo/src/new.rs"
         "src/new.rs"
         "fn moved() { new_location(); }"))
       (payload
        (difftron-magit-tests--diff-payload
         :moved (list (difftron-magit-tests--moved-change lhs rhs)))))
    (with-temp-buffer
      (difftron-magit-mode)
      (setq difftron-magit--grouping 'file)
      (let ((inhibit-read-only t))
        (difftron-magit--insert-payload payload))
      (let*
          (
           (text (buffer-string))
           (items (difftron-magit--diff-items payload))
           (grouped (difftron-magit--group-items-by-file items)))
        (should (string-match-p "^src/old\\.rs (1)$" text))
        (should (string-match-p "^src/new\\.rs (1)$" text))
        (should
         (string-match-p
          "^    Moved from here to demo::new::moved$"
          text))
        (should
         (string-match-p
          "^    Moved here from demo::old::moved$"
          text))
        (should
         (string-match-p "fn moved() { old_location(); }" text))
        (should
         (string-match-p "fn moved() { new_location(); }" text))
        (should
         (equal (mapcar #'car grouped) '("src/new.rs" "src/old.rs")))
        (should (equal (plist-get (car items) :entity) lhs))
        (should (equal (plist-get (cadr items) :entity) rhs))))))

(ert-deftest difftron-magit-renders-moved-modified-items ()
  (let*
      (
       (lhs
        (difftron-magit-tests--entity
         "demo::old::moved"
         "function"
         "/tmp/repo/src/old.rs"
         "src/old.rs"
         "fn moved() { old_location(); }"))
       (rhs
        (difftron-magit-tests--entity
         "demo::new::moved"
         "function"
         "/tmp/repo/src/new.rs"
         "src/new.rs"
         "fn moved() { new_location(); }"))
       (payload
        (difftron-magit-tests--diff-payload
         :moved-modified
         (list
          (difftron-magit-tests--moved-modified-change lhs rhs)))))
    (with-temp-buffer
      (difftron-magit-mode)
      (setq difftron-magit--grouping 'file)
      (let ((inhibit-read-only t))
        (difftron-magit--insert-payload payload))
      (let*
          (
           (text (buffer-string))
           (items (difftron-magit--diff-items payload))
           (grouped (difftron-magit--group-items-by-file items)))
        (should (string-match-p "^src/old\\.rs (1)$" text))
        (should (string-match-p "^src/new\\.rs (1)$" text))
        (should
         (string-match-p
          "^    Moved from here to demo::new::moved, with changes$"
          text))
        (should
         (string-match-p
          "^    Moved here from demo::old::moved, with changes$"
          text))
        (should
         (string-match-p "fn moved() { old_location(); }" text))
        (should
         (string-match-p "fn moved() { new_location(); }" text))
        (should
         (equal (mapcar #'car grouped) '("src/new.rs" "src/old.rs")))
        (should (equal (plist-get (car items) :entity) lhs))
        (should (equal (plist-get (cadr items) :entity) rhs))))))

(ert-deftest difftron-magit-renders-diff-buffer ()
  (with-temp-buffer
    (difftron-magit-mode)
    (let ((inhibit-read-only t))
      (difftron-magit--insert-payload
       difftron-magit-tests--sample-payload))
    (let*
        (
         (text (buffer-string))
         (root magit-root-section)
         (kind-section
          (difftron-magit-tests--first-child-section
           root
           'difftron-kind))
         (file-section (car (oref kind-section children)))
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
      (should (equal (oref kind-section type) 'difftron-kind))
      (should (equal (oref file-section type) 'difftron-file))
      (should (equal (oref entity-section type) 'difftron-entity))
      (should (oref kind-section hidden))
      (should (oref file-section hidden))
      (should (oref entity-section hidden))
      (should (string-match-p "Functions (2)" text))
      (should (string-match-p "^  src/lib\\.rs (2)$" text))
      (should (string-match-p "^    M demo::meaning$" text))
      (should (string-match-p "M demo::meaning" text))
      (should (string-match-p "\\+ demo::added" text))
      (should (string-match-p "fn meaning() -> u32" text))
      (should-not (string-match-p "ANSI-DIFF" text))
      (should-not (string-match-p "Location:" text))
      (should-not
       (string-match-p
        "function demo::added() @ /tmp/repo/src/lib.rs:10:1-12:2"
        text)))))

(ert-deftest difftron-magit-renders-kind-grouping-with-files ()
  (with-temp-buffer
    (difftron-magit-mode)
    (setq difftron-magit--grouping 'kind)
    (let ((inhibit-read-only t))
      (difftron-magit--insert-payload
       difftron-magit-tests--multi-file-payload))
    (let*
        (
         (root magit-root-section)
         (kind-section
          (difftron-magit-tests--first-child-section
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
        'difftron-magit-level-1-heading))
      (should-not (string-match-p "Grouping:" (buffer-string))))))

(ert-deftest difftron-magit-renders-file-grouping ()
  (with-temp-buffer
    (difftron-magit-mode)
    (setq difftron-magit--grouping 'file)
    (let ((inhibit-read-only t))
      (difftron-magit--insert-payload
       difftron-magit-tests--multi-file-payload))
    (let*
        (
         (root magit-root-section)
         (file-section
          (difftron-magit-tests--first-child-section
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

(ert-deftest difftron-magit-renders-kind-labels-from-payload ()
  (with-temp-buffer
    (difftron-magit-mode)
    (let ((inhibit-read-only t))
      (difftron-magit--insert-payload
       (difftron-magit-tests--diff-payload
        :added
        (list
         (difftron-magit-tests--entity
          "demo.core::message"
          "var"
          "/tmp/repo/src/demo/core.clj"
          "src/demo/core.clj"
          "(def message \"hello\")")))))
    (should (string-match-p "^Vars (1)$" (buffer-string)))))

(ert-deftest difftron-magit-default-grouping-is-file ()
  (should
   (eq
    (eval
     (car (get 'difftron-magit-default-grouping 'standard-value))
     t)
    'file)))

(ert-deftest difftron-magit-display-buffer-uses-default-grouping ()
  (let ((difftron-magit-default-grouping 'file))
    (cl-letf
	(((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (difftron-magit--display-buffer
       "/tmp/repo/"
       '("diff" "HEAD~1" "HEAD")
       difftron-magit-tests--multi-file-payload))
    (with-current-buffer difftron-magit-buffer-name
      (let*
          (
           (root magit-root-section)
           (file-section
            (difftron-magit-tests--first-child-section
             root
             'difftron-file))
           (sibling-file-section
            (cadr
             (seq-filter
              (lambda (section)
                (eq (oref section type) 'difftron-file))
              (oref root children))))
           (kind-section (car (oref file-section children)))
           (entity-section (car (oref kind-section children))))
        (should (eq difftron-magit--grouping 'file))
        (should-not (string-match-p "Grouping:" (buffer-string)))
        (should-not (oref file-section hidden))
        (should-not (oref kind-section hidden))
        (should (oref entity-section hidden))
        (should
         (difftron-magit-tests--section-has-invisible-overlay-p
          entity-section))
        (should (oref sibling-file-section hidden))
        (should
         (difftron-magit-tests--section-has-invisible-overlay-p
          sibling-file-section))))))

(ert-deftest difftron-magit-inherits-magit-all-level-bindings ()
  (should
   (eq
    (lookup-key difftron-magit-mode-map (kbd "M-1"))
    #'magit-section-show-level-1-all))
  (should
   (eq
    (lookup-key difftron-magit-mode-map (kbd "M-2"))
    #'magit-section-show-level-2-all))
  (should
   (eq
    (lookup-key difftron-magit-mode-map (kbd "M-3"))
    #'magit-section-show-level-3-all))
  (should
   (eq
    (lookup-key difftron-magit-mode-map (kbd "M-4"))
    #'magit-section-show-level-4-all)))

(ert-deftest difftron-magit-binds-commit-navigation ()
  (should
   (eq
    (lookup-key difftron-magit-mode-map (kbd "N"))
    #'difftron-magit-next-commit))
  (should
   (eq
    (lookup-key difftron-magit-mode-map (kbd "P"))
    #'difftron-magit-previous-commit))
  (should
   (eq
    (lookup-key difftron-magit-mode-map (kbd "n"))
    #'magit-section-forward))
  (should
   (eq
    (lookup-key difftron-magit-mode-map (kbd "p"))
    #'magit-section-backward)))

(ert-deftest difftron-magit-binds-side-selection ()
  (should
   (eq
    (lookup-key difftron-magit-mode-map (kbd "l"))
    #'difftron-magit-select-left))
  (should
   (eq
    (lookup-key difftron-magit-mode-map (kbd "r"))
    #'difftron-magit-select-right)))

(ert-deftest difftron-magit-binds-commit-message-toggle ()
  (should
   (eq
    (lookup-key difftron-magit-mode-map (kbd "m"))
    #'difftron-magit-toggle-commit-messages))
  (should
   (eq
    (lookup-key difftron-magit-mode-map (kbd "TAB"))
    #'difftron-magit-toggle-section-or-message)))

(ert-deftest difftron-magit-read-snapshot-arg-completes-ref ()
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
        (difftron-magit--read-snapshot-arg
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

(ert-deftest difftron-magit-read-snapshot-arg-groups-candidates ()
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
      (difftron-magit--read-snapshot-arg 'lhs "/tmp/repo/" "HEAD"))
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

(ert-deftest difftron-magit-read-snapshot-arg-selects-full-commit-hash ()
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
      (difftron-magit--read-snapshot-arg 'lhs "/tmp/repo/" "HEAD")
      "abc1234full"))))

(ert-deftest difftron-magit-read-snapshot-arg-selects-repo-path ()
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
      (difftron-magit--read-snapshot-arg 'lhs "/tmp/repo/" "HEAD")
      "/tmp/repo/src/lib.rs"))))

(ert-deftest difftron-magit-read-snapshot-arg-allows-typed-revision ()
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
      (difftron-magit--read-snapshot-arg 'rhs "/tmp/repo/" "HEAD")
      "abc1234"))))

(ert-deftest difftron-magit-read-snapshot-arg-uses-default-on-empty-input ()
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
      (difftron-magit--read-snapshot-arg 'lhs "/tmp/repo/" "HEAD")
      "HEAD"))))

(ert-deftest difftron-magit-read-snapshot-arg-browses-file-path ()
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
          (lambda (&rest _) difftron-magit--browse-path-choice))
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
        (difftron-magit--read-snapshot-arg
         'rhs
         "/tmp/repo/"
         "/tmp/repo/src/")
        "/tmp/repo/src/lib.rs")))
    (should (equal read-file-prompt "Right path: "))
    (should (equal read-file-dir "/tmp/repo/"))
    (should (equal read-file-default "/tmp/repo/src/"))))

(ert-deftest difftron-magit-read-snapshot-arg-browses-directory-path ()
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
        (lambda (&rest _) difftron-magit--browse-path-choice))
       ((symbol-function 'read-file-name)
        (lambda (&rest _) "/tmp/repo/src"))
       ((symbol-function 'file-directory-p)
        (lambda (path) (equal path "/tmp/repo/src"))))
    (should
     (equal
      (difftron-magit--read-snapshot-arg 'lhs "/tmp/repo/" "HEAD")
      "/tmp/repo/src/"))))

(ert-deftest difftron-magit-read-snapshot-arg-expands-typed-repo-path ()
  (let ((repo (file-name-as-directory
               (make-temp-file "difftron-magit-path-" t))))
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
              (difftron-magit--read-snapshot-arg
               'lhs
               repo
               "HEAD")
              file))))
      (delete-directory repo t))))

(ert-deftest difftron-magit-read-snapshot-arg-prefers-ref-over-path ()
  (let ((repo (file-name-as-directory
               (make-temp-file "difftron-magit-path-" t))))
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
              (difftron-magit--read-snapshot-arg
               'lhs
               repo
               "HEAD")
              "src/lib.rs"))))
      (delete-directory repo t))))

(ert-deftest difftron-magit-selects-left-git-revision ()
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
         ((symbol-function 'difftron-magit--run-command)
          (lambda (_default-directory _args)
            difftron-magit-tests--sample-payload))
         ((symbol-function 'difftron-magit--display-buffer)
          (lambda (_default-directory args _payload)
            (setq displayed-args args))))
      (with-temp-buffer
        (difftron-magit-mode)
        (setq difftron-magit--default-directory "/tmp/repo/")
        (setq difftron-magit--command-args
              '
              ("diff"
               "HEAD~1"
               "HEAD"
               "--format"
               "json"
               "--path"
               "src/lib.rs"))
        (setq difftron-magit--payload
              (copy-tree difftron-magit-tests--sample-payload))
        (difftron-magit-select-left)))
    (should (equal read-prompt "Left snapshot: "))
    (should (equal read-default "HEAD~1"))
    (should (member "feature" (all-completions "" read-collection)))
    (should
     (member
      difftron-magit--browse-path-choice
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

(ert-deftest difftron-magit-selects-right-directory ()
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
            difftron-magit--browse-path-choice))
         ((symbol-function 'read-file-name)
          (lambda (prompt _dir default-filename &rest _)
            (setq path-prompt prompt)
            (setq path-default default-filename)
            "/tmp/new-root"))
         ((symbol-function 'file-directory-p)
          (lambda (path) (equal path "/tmp/new-root")))
         ((symbol-function 'difftron-magit--run-command)
          (lambda (_default-directory _args)
            difftron-magit-tests--sample-payload))
         ((symbol-function 'difftron-magit--display-buffer)
          (lambda (_default-directory args _payload)
            (setq displayed-args args))))
      (with-temp-buffer
        (difftron-magit-mode)
        (setq difftron-magit--default-directory "/tmp/repo/")
        (setq difftron-magit--command-args
              '("diff" "HEAD~1" "/tmp/old-root" "--format" "json"))
        (setq difftron-magit--payload
              (difftron-magit-tests--diff-payload :lhs-rev "HEAD~1"))
        (plist-put
         difftron-magit--payload
         :rhs (difftron-magit-tests--directory-snapshot "/tmp/old-root"))
        (difftron-magit-select-right)))
    (should (equal snapshot-prompt "Right snapshot: "))
    (should (equal path-prompt "Right path: "))
    (should (equal path-default "/tmp/old-root"))
    (should
     (equal
      displayed-args
      '("diff" "HEAD~1" "/tmp/new-root/" "--format" "json")))))

(ert-deftest difftron-magit-selects-left-file ()
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
            difftron-magit--browse-path-choice))
         ((symbol-function 'read-file-name)
          (lambda (prompt _dir default-filename &rest _)
            (setq path-prompt prompt)
            (setq path-default default-filename)
            "/tmp/next.rs"))
         ((symbol-function 'file-directory-p)
          (lambda (_path) nil))
         ((symbol-function 'difftron-magit--run-command)
          (lambda (_default-directory _args)
            difftron-magit-tests--sample-payload))
         ((symbol-function 'difftron-magit--display-buffer)
          (lambda (_default-directory args _payload)
            (setq displayed-args args))))
      (with-temp-buffer
        (difftron-magit-mode)
        (setq difftron-magit--default-directory "/tmp/repo/")
        (setq difftron-magit--command-args
              '("diff" "/tmp/old.rs" "HEAD" "--format" "json"))
        (setq difftron-magit--payload
              (copy-tree difftron-magit-tests--sample-payload))
        (plist-put
         difftron-magit--payload
         :lhs (difftron-magit-tests--file-snapshot "/tmp/old.rs"))
        (difftron-magit-select-left)))
    (should (equal snapshot-prompt "Left snapshot: "))
    (should (equal path-prompt "Left path: "))
    (should (equal path-default "/tmp/old.rs"))
    (should
     (equal
      displayed-args
      '("diff" "/tmp/next.rs" "HEAD" "--format" "json")))))

(ert-deftest difftron-magit-side-selection-requires-payload ()
  (with-temp-buffer
    (difftron-magit-mode)
    (should-error (difftron-magit-select-left) :type 'user-error)
    (should-error (difftron-magit-select-right) :type 'user-error)))

(ert-deftest difftron-magit-previous-commit-preserves-path-filters ()
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
         ((symbol-function 'difftron-magit--run-command)
          (lambda (_default-directory _args)
            difftron-magit-tests--sample-payload))
         ((symbol-function 'difftron-magit--display-buffer)
          (lambda (default-directory args _payload)
            (setq displayed-directory default-directory)
            (setq displayed-args args))))
      (with-temp-buffer
        (difftron-magit-mode)
        (setq difftron-magit--default-directory "/tmp/repo/")
        (setq difftron-magit--command-args
              '
              ("diff"
               "commit-b"
               "commit-c"
               "--format"
               "json"
               "--path"
               "src/lib.rs"))
        (setq difftron-magit--payload
              (difftron-magit-tests--diff-payload
               :lhs-rev "commit-b"
               :rhs-rev "commit-c"))
        (difftron-magit-previous-commit)))
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

(ert-deftest difftron-magit-next-commit-walks-head-first-parent ()
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
         ((symbol-function 'difftron-magit--run-command)
          (lambda (_default-directory _args)
            difftron-magit-tests--sample-payload))
         ((symbol-function 'difftron-magit--display-buffer)
          (lambda (_default-directory args _payload)
            (setq displayed-args args))))
      (with-temp-buffer
        (difftron-magit-mode)
        (setq difftron-magit--default-directory "/tmp/repo/")
        (setq difftron-magit--command-args
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
        (setq difftron-magit--payload
              (difftron-magit-tests--diff-payload
               :lhs-rev "commit-a"
               :rhs-rev "commit-b"))
        (difftron-magit-next-commit)))
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

(ert-deftest difftron-magit-commit-navigation-requires-git-rhs ()
  (with-temp-buffer
    (difftron-magit-mode)
    (setq difftron-magit--payload
	  (list
           :command "diff"
           :rhs (list :kind "path" :label "/tmp/repo")))
    (should-error (difftron-magit-previous-commit) :type 'user-error)
    (should-error (difftron-magit-next-commit) :type 'user-error)))

(ert-deftest difftron-magit-previous-commit-errors-at-root ()
  (cl-letf
      (
       ((symbol-function 'magit-git-lines)
        (lambda (&rest args)
          (pcase args
            (`("rev-list" "-1" "--parents" "commit-a") '("commit-a"))
            (_ (error "Unexpected git args: %S" args))))))
    (with-temp-buffer
      (difftron-magit-mode)
      (setq difftron-magit--payload
            (difftron-magit-tests--diff-payload
             :lhs-rev "commit-a^"
             :rhs-rev "commit-a"))
      (should-error
       (difftron-magit-previous-commit)
       :type 'user-error))))

(ert-deftest difftron-magit-next-commit-errors-at-head ()
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
      (difftron-magit-mode)
      (setq difftron-magit--payload
            (difftron-magit-tests--diff-payload
             :lhs-rev "commit-b"
             :rhs-rev "commit-c"))
      (should-error
       (difftron-magit-next-commit)
       :type 'user-error))))

(ert-deftest difftron-magit-refresh-preserves-magit-display-state ()
  (let ((difftron-magit-default-grouping 'file))
    (with-temp-buffer
      (rename-buffer difftron-magit-buffer-name t)
      (difftron-magit-mode)
      (setq difftron-magit--default-directory "/tmp/repo/")
      (setq difftron-magit--command-args '("diff" "HEAD~1" "HEAD"))
      (setq difftron-magit--payload
            difftron-magit-tests--refresh-payload)
      (setq difftron-magit--grouping 'kind)
      (let ((inhibit-read-only t))
        (difftron-magit--insert-payload
         difftron-magit-tests--refresh-payload))
      (let*
          (
           (root magit-root-section)
           (kind-section
            (difftron-magit-tests--first-child-section
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
               ((symbol-function 'difftron-magit--run-command)
                (lambda (_default-directory _args)
                  difftron-magit-tests--refresh-payload))
               ((symbol-function 'pop-to-buffer)
                (lambda (&rest _) nil)))
            (difftron-magit-refresh))
          (let*
              (
               (new-root magit-root-section)
               (new-kind-section
                (difftron-magit-tests--first-child-section
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
            (should (eq difftron-magit--grouping 'kind))
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

(ert-deftest difftron-magit-git-snapshots-are-expandable-sections ()
  (cl-letf
      (((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
    (difftron-magit--display-buffer
     "/tmp/repo/"
     '("diff" "HEAD~1" "HEAD")
     difftron-magit-tests--sample-payload))
  (with-current-buffer difftron-magit-buffer-name
    (let ((lhs-section (difftron-magit-tests--snapshot-section 'lhs)))
      (should lhs-section)
      (should (oref lhs-section hidden))
      (should
       (seq-some
        (lambda (overlay)
          (overlay-get overlay 'magit-vis-indicator))
        (overlays-in
         (oref lhs-section start)
         (oref lhs-section content)))))))

(ert-deftest difftron-magit-tab-toggles-revision-details-at-point ()
  (difftron-magit-tests--with-revision-repo
   (lambda (repo parent child parent-subject child-subject)
     (let
         (
          (payload
           (difftron-magit-tests--payload-with-revisions
            repo
            child
            child
            child-subject
            child-subject)))
       (with-temp-buffer
         (difftron-magit-mode)
         (setq difftron-magit--default-directory repo)
         (let ((inhibit-read-only t))
           (difftron-magit--insert-payload payload))
         (should-not (string-match-p "AuthorDate:" (buffer-string)))
         (goto-char (point-min))
         (search-forward "lhs: ")
         (difftron-magit-toggle-section-or-message)
         (should-not
          (oref (difftron-magit-tests--snapshot-section 'lhs) hidden))
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
         (difftron-magit-toggle-section-or-message)
         (should
          (oref (difftron-magit-tests--snapshot-section 'lhs) hidden)))))))

(ert-deftest difftron-magit-m-toggles-all-revision-details ()
  (difftron-magit-tests--with-revision-repo
   (lambda (repo parent child parent-subject child-subject)
     (let
         (
          (payload
           (difftron-magit-tests--payload-with-revisions
            repo
            parent
            child
            parent-subject
            child-subject)))
       (with-temp-buffer
         (difftron-magit-mode)
         (setq difftron-magit--default-directory repo)
         (let ((inhibit-read-only t))
           (difftron-magit--insert-payload payload))
         (difftron-magit-toggle-commit-messages)
         (should-not
          (oref (difftron-magit-tests--snapshot-section 'lhs) hidden))
         (should-not
          (oref (difftron-magit-tests--snapshot-section 'rhs) hidden))
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
         (difftron-magit-toggle-commit-messages)
         (should
          (oref (difftron-magit-tests--snapshot-section 'lhs) hidden))
         (should
          (oref (difftron-magit-tests--snapshot-section 'rhs) hidden)))))))

(ert-deftest difftron-magit-faces-added-and-deleted-entities ()
  (let*
      (
       (payload
        (difftron-magit-tests--diff-payload
         :added
         (list
          (difftron-magit-tests--entity
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
          (difftron-magit-tests--entity
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
      (difftron-magit-mode)
      (let ((inhibit-read-only t))
        (difftron-magit--insert-payload payload))
      (goto-char (point-min))
      (search-forward "+ demo::added")
      (should
       (eq
        (get-text-property (match-beginning 0) 'font-lock-face)
        'difftron-magit-level-2-heading))
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
        'difftron-magit-level-2-heading))
      (search-forward "fn deleted() {}")
      (should
       (eq
        (get-text-property (match-beginning 0) 'font-lock-face)
        'magit-diff-removed)))))

(ert-deftest difftron-magit-renders-structured-modified-diff-faces ()
  (with-temp-buffer
    (difftron-magit-mode)
    (let ((inhibit-read-only t))
      (difftron-magit--insert-payload
       difftron-magit-tests--sample-payload))
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

(ert-deftest difftron-magit-diff-omits-width-for-json-output ()
  (cl-letf
      (
       ((symbol-function 'difftron-magit--repo-root)
        (lambda () "/tmp/repo/"))
       ((symbol-function 'difftron-magit--run-command)
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
          difftron-magit-tests--sample-payload))
       ((symbol-function 'difftron-magit--display-buffer)
        (lambda (_default-directory _args _payload) nil)))
    (difftron-magit-diff "HEAD~1" "HEAD" '("src/lib.rs"))))

(ert-deftest difftron-magit-diff-interactive-does-not-read-paths ()
  (let (prompts defaults ran-args)
    (cl-letf
        (
         ((symbol-function 'difftron-magit--repo-root)
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
         ((symbol-function 'difftron-magit--run-command)
          (lambda (_default-directory args)
            (setq ran-args args)
            difftron-magit-tests--sample-payload))
         ((symbol-function 'difftron-magit--display-buffer)
          (lambda (_default-directory _args _payload) nil)))
      (call-interactively #'difftron-magit-diff))
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

(ert-deftest difftron-magit-cycle-grouping-redraws-buffer ()
  (with-temp-buffer
    (difftron-magit-mode)
    (setq difftron-magit--default-directory "/tmp/repo/")
    (setq difftron-magit--command-args '("diff" "HEAD~1" "HEAD"))
    (setq difftron-magit--payload
	  difftron-magit-tests--multi-file-payload)
    (setq difftron-magit--grouping 'kind)
    (cl-letf
	(((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (difftron-magit-cycle-grouping))
    (should (eq difftron-magit-default-grouping 'file))
    (should (eq difftron-magit--grouping 'file))
    (with-current-buffer difftron-magit-buffer-name
      (let*
          (
           (root magit-root-section)
           (file-section
            (difftron-magit-tests--first-child-section
             root
             'difftron-file))
           (kind-section (car (oref file-section children)))
           (entity-section (car (oref kind-section children)))
           (text (buffer-string)))
        (should-not (string-match-p "Grouping:" text))
        (should-not (oref file-section hidden))
        (should-not (oref kind-section hidden))
        (should (oref entity-section hidden))))))

(ert-deftest difftron-magit-shortens-path-backed-diff-labels ()
  (with-temp-buffer
    (difftron-magit-mode)
    (let ((inhibit-read-only t))
      (difftron-magit--insert-payload
       (difftron-magit-tests--diff-payload
        :lhs-label "/Users/dev/work/incubator/2026-04-21-diff@5767f35^"
        :rhs-label "/Users/dev/work/incubator/2026-04-21-diff@5767f35")))
    (should
     (string-prefix-p
      (concat
       "lhs: 2026-04-21-diff@5767f35^  Commit HEAD~1\n"
       "rhs: 2026-04-21-diff@5767f35  Commit HEAD\n\n")
      (buffer-string)))))

(ert-deftest difftron-magit-renders-clickable-diff-snapshots ()
  (with-temp-buffer
    (difftron-magit-mode)
    (let ((inhibit-read-only t))
      (difftron-magit--insert-payload
       difftron-magit-tests--sample-payload))
    (goto-char (point-min))
    (search-forward "repo@HEAD~1")
    (should (button-at (1- (point))))
    (search-forward "repo@HEAD")
    (should (button-at (1- (point))))))

(ert-deftest difftron-magit-visits-git-revision-snapshot ()
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
      (difftron-magit--visit-snapshot
       (difftron-magit-tests--git-revision "repo@HEAD~1" "HEAD~1")))
    (should (equal visited-rev "HEAD~1"))
    (should (equal visited-directory "/tmp/repo"))))

(ert-deftest difftron-magit-ret-visits-diff-snapshot ()
  (let (visited-rev)
    (cl-letf
	(
         ((symbol-function 'magit-show-commit)
          (lambda (rev &rest _) (setq visited-rev rev))))
      (with-temp-buffer
        (difftron-magit-mode)
        (let ((inhibit-read-only t))
          (difftron-magit--insert-payload
           difftron-magit-tests--sample-payload))
        (goto-char (point-min))
        (search-forward "rhs: ")
        (search-forward "repo@HEAD")
        (difftron-magit-visit-thing)))
    (should (equal visited-rev "HEAD"))))

(ert-deftest difftron-magit-dwim-endpoints-from-commit ()
  (should
   (equal
    (difftron-magit--dwim-endpoints
     '(commit . "HEAD~2")
     "/tmp/repo")
    '("HEAD~2^" "HEAD~2"))))

(ert-deftest difftron-magit-dwim-endpoints-from-range ()
  (should
   (equal
    (difftron-magit--dwim-endpoints "main..feature" "/tmp/repo")
    '("main" "feature")))
  (should
   (equal
    (difftron-magit--dwim-endpoints "HEAD" "/tmp/repo")
    '("HEAD" "/tmp/repo"))))

(ert-deftest difftron-magit-dwim-endpoints-from-worktree-context ()
  (should
   (equal
    (difftron-magit--dwim-endpoints 'unstaged "/tmp/repo")
    '("HEAD" "/tmp/repo")))
  (should
   (equal
    (difftron-magit--dwim-endpoints nil "/tmp/repo")
    '("HEAD" "/tmp/repo"))))

(ert-deftest difftron-magit-bindings-mode-registers-magit-suffix ()
  (require 'magit-diff)
  (unwind-protect
      (progn
	(difftron-magit-bindings-mode 1)
	(should (transient-get-suffix 'magit-diff "D")))
    (difftron-magit-bindings-mode -1)))

(ert-deftest difftron-magit-bindings-mode-registers-magit-diff-key ()
  (require 'magit-diff)
  (unwind-protect
      (progn
	(difftron-magit-bindings-mode 1)
	(should
         (eq
          (lookup-key magit-diff-mode-map (kbd "D"))
          #'difftron-magit-diff-at-point))
	(should
         (eq
          (lookup-key magit-diff-section-map (kbd "D"))
          #'difftron-magit-diff-at-point)))
    (difftron-magit-bindings-mode -1)))

(ert-deftest difftron-magit-diff-at-point-jumps-to-current-entity ()
  (let (ran-args)
    (cl-letf
	(
         ((symbol-function 'difftron-magit--repo-root)
          (lambda () "/tmp/repo/"))
         ((symbol-function 'magit-diff-arguments)
          (lambda (&rest _) (list '("--stat") nil)))
         ((symbol-function 'magit-diff--dwim)
          (lambda () "HEAD~1..HEAD"))
         ((symbol-function 'difftron-magit--magit-diff-path-at-point)
          (lambda () "src/lib.rs"))
         ((symbol-function 'difftron-magit--magit-diff-line-at-point)
          (lambda () 10))
         ((symbol-function 'difftron-magit--run-command)
          (lambda (_default-directory args)
            (setq ran-args args)
            difftron-magit-tests--sample-payload))
         ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (difftron-magit-diff-at-point))
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
    (with-current-buffer difftron-magit-buffer-name
      (let ((section (magit-current-section)))
        (should (equal (oref section type) 'difftron-entity))
        (should
         (equal
          (plist-get (oref section value) :summary)
          "+ demo::added"))
        (should-not (oref section hidden))))))

(ert-deftest difftron-magit-diff-dwim-obeys-magit-path-toggle ()
  (let (selected-paths)
    (cl-letf
        (
         ((symbol-function 'difftron-magit--repo-root)
          (lambda () "/tmp/repo/"))
         ((symbol-function 'magit-diff-arguments)
          (lambda (&rest _) (list nil '("src/lib.rs"))))
         ((symbol-function 'magit-diff--dwim)
          (lambda () "HEAD~1..HEAD"))
         ((symbol-function 'difftron-magit-diff)
          (lambda (_lhs _rhs paths)
            (setq selected-paths paths))))
      (let ((difftron-magit-use-magit-paths t))
        (difftron-magit-diff-dwim))
      (should (equal selected-paths '("src/lib.rs")))
      (let ((difftron-magit-use-magit-paths nil))
        (difftron-magit-diff-dwim))
      (should-not selected-paths))))

(ert-deftest difftron-magit-diff-at-point-omits-path-when-toggle-off ()
  (let (ran-args)
    (cl-letf
        (
         ((symbol-function 'difftron-magit--repo-root)
          (lambda () "/tmp/repo/"))
         ((symbol-function 'magit-diff-arguments)
          (lambda (&rest _) (list nil '("src/other.rs"))))
         ((symbol-function 'magit-diff--dwim)
          (lambda () "HEAD~1..HEAD"))
         ((symbol-function 'difftron-magit--magit-diff-path-at-point)
          (lambda () "src/lib.rs"))
         ((symbol-function 'difftron-magit--magit-diff-line-at-point)
          (lambda () 10))
         ((symbol-function 'difftron-magit--run-command)
          (lambda (_default-directory args)
            (setq ran-args args)
            difftron-magit-tests--sample-payload))
         ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (let ((difftron-magit-use-magit-paths nil))
        (difftron-magit-diff-at-point)))
    (should
     (equal ran-args '("diff" "HEAD~1" "HEAD" "--format" "json")))
    (with-current-buffer difftron-magit-buffer-name
      (let ((section (magit-current-section)))
        (should (equal (oref section type) 'difftron-entity))
        (should-not (oref section hidden))))))

(ert-deftest difftron-magit-bindings-mode-registers-after-magit-load
    ()
  (when (featurep 'magit-diff)
    (unload-feature 'magit-diff t))
  (unwind-protect
      (progn
	(difftron-magit-bindings-mode 1)
	(should-not (featurep 'magit-diff))
	(require 'magit-diff)
	(should (transient-get-suffix 'magit-diff "D")))
    (difftron-magit-bindings-mode -1)))

(ert-deftest difftron-magit-bindings-mode-unregisters-magit-suffix ()
  (require 'magit-diff)
  (difftron-magit-bindings-mode 1)
  (difftron-magit-bindings-mode -1)
  (should-not
   (ignore-errors
     (transient-get-suffix 'magit-diff "D")))
  (should-not (difftron-magit--magit-diff-suffix-p "D")))

(ert-deftest difftron-magit-bindings-mode-unregisters-magit-diff-key
    ()
  (require 'magit-diff)
  (difftron-magit-bindings-mode 1)
  (difftron-magit-bindings-mode -1)
  (should-not
   (eq
    (lookup-key magit-diff-mode-map (kbd "D"))
    #'difftron-magit-diff-at-point))
  (should-not
   (eq
    (lookup-key magit-diff-section-map (kbd "D"))
    #'difftron-magit-diff-at-point)))

(provide 'difftron-magit-tests)

;;; difftron-magit-tests.el ends here
