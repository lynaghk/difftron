;;; rust-dive-magit-tests.el --- Tests for rust-dive-magit  -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)

(add-to-list
  'load-path
  (file-name-directory (or load-file-name buffer-file-name)))
(require 'rust-dive-magit)

(defconst rust-dive-magit-tests--entity-kind-order
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

(defconst rust-dive-magit-tests--entity-kinds
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

(defun rust-dive-magit-tests--git-revision (label rev)
  (list
    :label label
    :kind "git_revision"
    :root "/tmp/repo"
    :rev rev
    :summary (format "Commit %s" rev)))

(defun rust-dive-magit-tests--directory-snapshot (path)
  (list :label path :kind "directory" :root path))

(defun rust-dive-magit-tests--file-snapshot (path)
  (list :label path :kind "file" :root path))

(cl-defun
  rust-dive-magit-tests--entity
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

(defun rust-dive-magit-tests--segments (text novel)
  (let ((match (string-match (regexp-quote novel) text)))
    (list
      (list :text (substring text 0 match) :kind "context")
      (list :text novel :kind "novel")
      (list
        :text (substring text (+ match (length novel)))
        :kind "context"))))

(defun rust-dive-magit-tests--side (text novel)
  (list
    :line_number 1
    :text text
    :segments (rust-dive-magit-tests--segments text novel)))

(defun rust-dive-magit-tests--modified-change
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
          (rust-dive-magit-tests--side
            (plist-get lhs :source_text)
            lhs-novel)
          :right
          (rust-dive-magit-tests--side
            (plist-get rhs :source_text)
            rhs-novel))))))

(defun rust-dive-magit-tests--moved-change (lhs rhs)
  (list :lhs lhs :rhs rhs))

(defun rust-dive-magit-tests--moved-modified-change (lhs rhs)
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
          (rust-dive-magit-tests--side
            (plist-get lhs :source_text)
            "old_location")
          :right
          (rust-dive-magit-tests--side
            (plist-get rhs :source_text)
            "new_location"))))))

(cl-defun
  rust-dive-magit-tests--diff-payload
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
    :entity_kind_order rust-dive-magit-tests--entity-kind-order
    :entity_kinds rust-dive-magit-tests--entity-kinds
    :lhs (rust-dive-magit-tests--git-revision lhs-label lhs-rev)
    :rhs (rust-dive-magit-tests--git-revision rhs-label rhs-rev)
    :added added
    :deleted deleted
    :moved moved
    :moved_modified moved-modified
    :modified modified))

(defconst rust-dive-magit-tests--sample-payload
  (let*
    (
      (added
        (rust-dive-magit-tests--entity
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
        (rust-dive-magit-tests--entity
          "demo::meaning"
          "function"
          "/tmp/repo/src/lib.rs"
          "src/lib.rs"
          "fn meaning() -> u32 { 41 }"
          :rendered-summary "function demo::meaning() @ /tmp/repo/src/lib.rs:1:1-1:10"))
      (rhs
        (rust-dive-magit-tests--entity
          "demo::meaning"
          "function"
          "/tmp/repo/src/lib.rs"
          "src/lib.rs"
          "fn meaning() -> u32 { 42 }"
          :rendered-summary "function demo::meaning() @ /tmp/repo/src/lib.rs:1:1-1:10")))
    (rust-dive-magit-tests--diff-payload
      :added (list added)
      :deleted nil
      :modified
      (list
        (rust-dive-magit-tests--modified-change
          "src/lib.rs"
          lhs
          rhs
          "41"
          "42")))))

(defconst rust-dive-magit-tests--multi-file-payload
  (let*
    (
      (added
        (rust-dive-magit-tests--entity
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
        (rust-dive-magit-tests--entity
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
        (rust-dive-magit-tests--entity
          "demo::meaning"
          "function"
          "/tmp/repo/src/b.rs"
          "src/b.rs"
          "fn meaning() -> u32 { 41 }"
          :rendered-summary "function demo::meaning()"))
      (rhs
        (rust-dive-magit-tests--entity
          "demo::meaning"
          "function"
          "/tmp/repo/src/b.rs"
          "src/b.rs"
          "fn meaning() -> u32 { 42 }"
          :rendered-summary "function demo::meaning()")))
    (rust-dive-magit-tests--diff-payload
      :added (list added)
      :deleted (list deleted)
      :modified
      (list
        (rust-dive-magit-tests--modified-change
          "src/b.rs"
          lhs
          rhs
          "41"
          "42")))))

(defconst rust-dive-magit-tests--refresh-payload
  (let*
    (
      (added
        (rust-dive-magit-tests--entity
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
        (rust-dive-magit-tests--entity
          "demo::beta"
          "function"
          "/tmp/repo/src/b.rs"
          "src/b.rs"
          "fn beta() -> u32 { 41 }"
          :rendered-summary "function demo::beta()"))
      (beta-rhs
        (rust-dive-magit-tests--entity
          "demo::beta"
          "function"
          "/tmp/repo/src/b.rs"
          "src/b.rs"
          "fn beta() -> u32 { 42 }"
          :rendered-summary "function demo::beta()"))
      (gamma-lhs
        (rust-dive-magit-tests--entity
          "demo::gamma"
          "function"
          "/tmp/repo/src/c.rs"
          "src/c.rs"
          "fn gamma() -> u32 { 7 }"
          :rendered-summary "function demo::gamma()"))
      (gamma-rhs
        (rust-dive-magit-tests--entity
          "demo::gamma"
          "function"
          "/tmp/repo/src/c.rs"
          "src/c.rs"
          "fn gamma() -> u32 { 8 }"
          :rendered-summary "function demo::gamma()")))
    (rust-dive-magit-tests--diff-payload
      :added (list added)
      :deleted nil
      :modified
      (list
        (rust-dive-magit-tests--modified-change
          "src/b.rs"
          beta-lhs
          beta-rhs
          "41"
          "42")
        (rust-dive-magit-tests--modified-change
          "src/c.rs"
          gamma-lhs
          gamma-rhs
          "7"
          "8")))))

(ert-deftest rust-dive-magit-groups-items-by-kind ()
  (let*
    (
      (items
        (rust-dive-magit--diff-items
          rust-dive-magit-tests--sample-payload))
      (grouped (rust-dive-magit--group-items-by-kind items)))
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

(ert-deftest rust-dive-magit-groups-items-by-file ()
  (let*
    (
      (items
        (rust-dive-magit--diff-items
          rust-dive-magit-tests--multi-file-payload))
      (grouped (rust-dive-magit--group-items-by-file items)))
    (should (equal (mapcar #'car grouped) '("src/a.rs" "src/b.rs")))))

(ert-deftest rust-dive-magit-renders-moved-items ()
  (let*
    (
      (lhs
        (rust-dive-magit-tests--entity
          "demo::old::moved"
          "function"
          "/tmp/repo/src/old.rs"
          "src/old.rs"
          "fn moved() { old_location(); }"))
      (rhs
        (rust-dive-magit-tests--entity
          "demo::new::moved"
          "function"
          "/tmp/repo/src/new.rs"
          "src/new.rs"
          "fn moved() { new_location(); }"))
      (payload
        (rust-dive-magit-tests--diff-payload
          :moved (list (rust-dive-magit-tests--moved-change lhs rhs)))))
    (with-temp-buffer
      (rust-dive-magit-mode)
      (setq rust-dive-magit--grouping 'file)
      (let ((inhibit-read-only t))
        (rust-dive-magit--insert-payload payload))
      (let*
        (
          (text (buffer-string))
          (items (rust-dive-magit--diff-items payload))
          (grouped (rust-dive-magit--group-items-by-file items)))
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

(ert-deftest rust-dive-magit-renders-moved-modified-items ()
  (let*
    (
      (lhs
        (rust-dive-magit-tests--entity
          "demo::old::moved"
          "function"
          "/tmp/repo/src/old.rs"
          "src/old.rs"
          "fn moved() { old_location(); }"))
      (rhs
        (rust-dive-magit-tests--entity
          "demo::new::moved"
          "function"
          "/tmp/repo/src/new.rs"
          "src/new.rs"
          "fn moved() { new_location(); }"))
      (payload
        (rust-dive-magit-tests--diff-payload
          :moved-modified
          (list
            (rust-dive-magit-tests--moved-modified-change lhs rhs)))))
    (with-temp-buffer
      (rust-dive-magit-mode)
      (setq rust-dive-magit--grouping 'file)
      (let ((inhibit-read-only t))
        (rust-dive-magit--insert-payload payload))
      (let*
        (
          (text (buffer-string))
          (items (rust-dive-magit--diff-items payload))
          (grouped (rust-dive-magit--group-items-by-file items)))
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

(ert-deftest rust-dive-magit-renders-diff-buffer ()
  (with-temp-buffer
    (rust-dive-magit-mode)
    (let ((inhibit-read-only t))
      (rust-dive-magit--insert-payload
        rust-dive-magit-tests--sample-payload))
    (let*
      (
        (text (buffer-string))
        (root magit-root-section)
        (kind-section (car (oref root children)))
        (file-section (car (oref kind-section children)))
        (entity-section (car (oref file-section children))))
      (should
        (string-match-p
          "^lhs: repo@HEAD~1  Commit HEAD~1\nrhs: repo@HEAD  Commit HEAD\n\n"
          text))
      (should (string-match-p "repo@HEAD~1  Commit HEAD~1" text))
      (should (string-match-p "repo@HEAD  Commit HEAD" text))
      (should-not (string-match-p "rust_dive diff" text))
      (should-not (string-match-p "Grouping:" text))
      (should (derived-mode-p 'magit-section-mode))
      (should (equal (oref kind-section type) 'rust-dive-kind))
      (should (equal (oref file-section type) 'rust-dive-file))
      (should (equal (oref entity-section type) 'rust-dive-entity))
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

(ert-deftest rust-dive-magit-renders-kind-grouping-with-files ()
  (with-temp-buffer
    (rust-dive-magit-mode)
    (setq rust-dive-magit--grouping 'kind)
    (let ((inhibit-read-only t))
      (rust-dive-magit--insert-payload
        rust-dive-magit-tests--multi-file-payload))
    (let*
      (
        (root magit-root-section)
        (kind-section (car (oref root children)))
        (file-section (car (oref kind-section children)))
        (entity-section (car (oref file-section children))))
      (should (equal (oref kind-section type) 'rust-dive-kind))
      (should (equal (oref file-section type) 'rust-dive-file))
      (should (equal (oref entity-section type) 'rust-dive-entity))
      (goto-char (point-min))
      (search-forward "src/a.rs (1)")
      (should
        (eq
          (get-text-property (match-beginning 0) 'font-lock-face)
          'rust-dive-magit-level-1-heading))
      (should-not (string-match-p "Grouping:" (buffer-string))))))

(ert-deftest rust-dive-magit-renders-file-grouping ()
  (with-temp-buffer
    (rust-dive-magit-mode)
    (setq rust-dive-magit--grouping 'file)
    (let ((inhibit-read-only t))
      (rust-dive-magit--insert-payload
        rust-dive-magit-tests--multi-file-payload))
    (let*
      (
        (root magit-root-section)
        (file-section (car (oref root children)))
        (kind-section (car (oref file-section children)))
        (entity-section (car (oref kind-section children))))
      (should (equal (oref file-section type) 'rust-dive-file))
      (should (equal (oref kind-section type) 'rust-dive-kind))
      (should (equal (oref entity-section type) 'rust-dive-entity))
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

(ert-deftest rust-dive-magit-renders-kind-labels-from-payload ()
  (with-temp-buffer
    (rust-dive-magit-mode)
    (let ((inhibit-read-only t))
      (rust-dive-magit--insert-payload
        (rust-dive-magit-tests--diff-payload
          :added
          (list
            (rust-dive-magit-tests--entity
              "demo.core::message"
              "var"
              "/tmp/repo/src/demo/core.clj"
              "src/demo/core.clj"
              "(def message \"hello\")")))))
    (should (string-match-p "^Vars (1)$" (buffer-string)))))

(ert-deftest rust-dive-magit-default-grouping-is-file ()
  (should
    (eq
      (eval
        (car (get 'rust-dive-magit-default-grouping 'standard-value))
        t)
      'file)))

(ert-deftest rust-dive-magit-display-buffer-uses-default-grouping ()
  (let ((rust-dive-magit-default-grouping 'file))
    (cl-letf
      (((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (rust-dive-magit--display-buffer
        "/tmp/repo/"
        '("diff" "HEAD~1" "HEAD")
        rust-dive-magit-tests--multi-file-payload))
    (with-current-buffer rust-dive-magit-buffer-name
      (let*
        (
          (root magit-root-section)
          (file-section (car (oref root children)))
          (kind-section (car (oref file-section children)))
          (entity-section (car (oref kind-section children))))
        (should (eq rust-dive-magit--grouping 'file))
        (should-not (string-match-p "Grouping:" (buffer-string)))
        (should-not (oref file-section hidden))
        (should-not (oref kind-section hidden))
        (should (oref entity-section hidden))))))

(ert-deftest rust-dive-magit-inherits-magit-all-level-bindings ()
  (should
    (eq
      (lookup-key rust-dive-magit-mode-map (kbd "M-1"))
      #'magit-section-show-level-1-all))
  (should
    (eq
      (lookup-key rust-dive-magit-mode-map (kbd "M-2"))
      #'magit-section-show-level-2-all))
  (should
    (eq
      (lookup-key rust-dive-magit-mode-map (kbd "M-3"))
      #'magit-section-show-level-3-all))
  (should
    (eq
      (lookup-key rust-dive-magit-mode-map (kbd "M-4"))
      #'magit-section-show-level-4-all)))

(ert-deftest rust-dive-magit-binds-commit-navigation ()
  (should
    (eq
      (lookup-key rust-dive-magit-mode-map (kbd "N"))
      #'rust-dive-magit-next-commit))
  (should
    (eq
      (lookup-key rust-dive-magit-mode-map (kbd "P"))
      #'rust-dive-magit-previous-commit))
  (should
    (eq
      (lookup-key rust-dive-magit-mode-map (kbd "n"))
      #'magit-section-forward))
  (should
    (eq
      (lookup-key rust-dive-magit-mode-map (kbd "p"))
      #'magit-section-backward)))

(ert-deftest rust-dive-magit-binds-side-selection ()
  (should
    (eq
      (lookup-key rust-dive-magit-mode-map (kbd "l"))
      #'rust-dive-magit-select-left))
  (should
    (eq
      (lookup-key rust-dive-magit-mode-map (kbd "r"))
      #'rust-dive-magit-select-right)))

(ert-deftest rust-dive-magit-binds-commit-message-toggle ()
  (should
    (eq
      (lookup-key rust-dive-magit-mode-map (kbd "m"))
      #'rust-dive-magit-toggle-commit-messages))
  (should
    (eq
      (lookup-key rust-dive-magit-mode-map (kbd "TAB"))
      #'rust-dive-magit-toggle-section-or-message)))

(ert-deftest rust-dive-magit-selects-left-git-revision ()
  (let
    (
      displayed-args
      read-prompt
      read-default)
    (cl-letf
      (
        ((symbol-function 'magit-read-branch-or-commit)
          (lambda (prompt &optional secondary-default _exclude)
            (setq read-prompt prompt)
            (setq read-default secondary-default)
            "feature"))
        ((symbol-function 'rust-dive-magit--run-command)
          (lambda (_default-directory _args)
            rust-dive-magit-tests--sample-payload))
        ((symbol-function 'rust-dive-magit--display-buffer)
          (lambda (_default-directory args _payload)
            (setq displayed-args args))))
      (with-temp-buffer
        (rust-dive-magit-mode)
        (setq rust-dive-magit--default-directory "/tmp/repo/")
        (setq rust-dive-magit--command-args
          '
          ("diff"
            "HEAD~1"
            "HEAD"
            "--format"
            "json"
            "--path"
            "src/lib.rs"))
        (setq rust-dive-magit--payload
          (copy-tree rust-dive-magit-tests--sample-payload))
        (rust-dive-magit-select-left)))
    (should (equal read-prompt "Left ref"))
    (should (equal read-default "HEAD~1"))
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

(ert-deftest rust-dive-magit-selects-right-directory ()
  (let
    (
      displayed-args
      read-prompt
      read-default)
    (cl-letf
      (
        ((symbol-function 'read-directory-name)
          (lambda (prompt _dir default-directory &rest _)
            (setq read-prompt prompt)
            (setq read-default default-directory)
            "/tmp/new-root"))
        ((symbol-function 'rust-dive-magit--run-command)
          (lambda (_default-directory _args)
            rust-dive-magit-tests--sample-payload))
        ((symbol-function 'rust-dive-magit--display-buffer)
          (lambda (_default-directory args _payload)
            (setq displayed-args args))))
      (with-temp-buffer
        (rust-dive-magit-mode)
        (setq rust-dive-magit--default-directory "/tmp/repo/")
        (setq rust-dive-magit--command-args
          '("diff" "HEAD~1" "/tmp/old-root" "--format" "json"))
        (setq rust-dive-magit--payload
          (rust-dive-magit-tests--diff-payload :lhs-rev "HEAD~1"))
        (plist-put
          rust-dive-magit--payload
          :rhs (rust-dive-magit-tests--directory-snapshot "/tmp/old-root"))
        (rust-dive-magit-select-right)))
    (should (equal read-prompt "Right folder: "))
    (should (equal read-default "/tmp/old-root"))
    (should
      (equal
        displayed-args
        '("diff" "HEAD~1" "/tmp/new-root/" "--format" "json")))))

(ert-deftest rust-dive-magit-selects-left-file ()
  (let
    (
      displayed-args
      read-prompt
      read-default)
    (cl-letf
      (
        ((symbol-function 'read-file-name)
          (lambda (prompt _dir default-filename &rest _)
            (setq read-prompt prompt)
            (setq read-default default-filename)
            "/tmp/next.rs"))
        ((symbol-function 'rust-dive-magit--run-command)
          (lambda (_default-directory _args)
            rust-dive-magit-tests--sample-payload))
        ((symbol-function 'rust-dive-magit--display-buffer)
          (lambda (_default-directory args _payload)
            (setq displayed-args args))))
      (with-temp-buffer
        (rust-dive-magit-mode)
        (setq rust-dive-magit--default-directory "/tmp/repo/")
        (setq rust-dive-magit--command-args
          '("diff" "/tmp/old.rs" "HEAD" "--format" "json"))
        (setq rust-dive-magit--payload
          (copy-tree rust-dive-magit-tests--sample-payload))
        (plist-put
          rust-dive-magit--payload
          :lhs (rust-dive-magit-tests--file-snapshot "/tmp/old.rs"))
        (rust-dive-magit-select-left)))
    (should (equal read-prompt "Left file: "))
    (should (equal read-default "/tmp/old.rs"))
    (should
      (equal
        displayed-args
        '("diff" "/tmp/next.rs" "HEAD" "--format" "json")))))

(ert-deftest rust-dive-magit-side-selection-requires-payload ()
  (with-temp-buffer
    (rust-dive-magit-mode)
    (should-error (rust-dive-magit-select-left) :type 'user-error)
    (should-error (rust-dive-magit-select-right) :type 'user-error)))

(ert-deftest rust-dive-magit-previous-commit-preserves-path-filters ()
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
        ((symbol-function 'rust-dive-magit--run-command)
          (lambda (_default-directory _args)
            rust-dive-magit-tests--sample-payload))
        ((symbol-function 'rust-dive-magit--display-buffer)
          (lambda (default-directory args _payload)
            (setq displayed-directory default-directory)
            (setq displayed-args args))))
      (with-temp-buffer
        (rust-dive-magit-mode)
        (setq rust-dive-magit--default-directory "/tmp/repo/")
        (setq rust-dive-magit--command-args
          '
          ("diff"
            "commit-b"
            "commit-c"
            "--format"
            "json"
            "--path"
            "src/lib.rs"))
        (setq rust-dive-magit--payload
          (rust-dive-magit-tests--diff-payload
            :lhs-rev "commit-b"
            :rhs-rev "commit-c"))
        (rust-dive-magit-previous-commit)))
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

(ert-deftest rust-dive-magit-next-commit-walks-head-first-parent ()
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
        ((symbol-function 'rust-dive-magit--run-command)
          (lambda (_default-directory _args)
            rust-dive-magit-tests--sample-payload))
        ((symbol-function 'rust-dive-magit--display-buffer)
          (lambda (_default-directory args _payload)
            (setq displayed-args args))))
      (with-temp-buffer
        (rust-dive-magit-mode)
        (setq rust-dive-magit--default-directory "/tmp/repo/")
        (setq rust-dive-magit--command-args
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
        (setq rust-dive-magit--payload
          (rust-dive-magit-tests--diff-payload
            :lhs-rev "commit-a"
            :rhs-rev "commit-b"))
        (rust-dive-magit-next-commit)))
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

(ert-deftest rust-dive-magit-commit-navigation-requires-git-rhs ()
  (with-temp-buffer
    (rust-dive-magit-mode)
    (setq rust-dive-magit--payload
      (list
        :command "diff"
        :rhs (list :kind "path" :label "/tmp/repo")))
    (should-error (rust-dive-magit-previous-commit) :type 'user-error)
    (should-error (rust-dive-magit-next-commit) :type 'user-error)))

(ert-deftest rust-dive-magit-previous-commit-errors-at-root ()
  (cl-letf
    (
      ((symbol-function 'magit-git-lines)
        (lambda (&rest args)
          (pcase args
            (`("rev-list" "-1" "--parents" "commit-a") '("commit-a"))
            (_ (error "Unexpected git args: %S" args))))))
    (with-temp-buffer
      (rust-dive-magit-mode)
      (setq rust-dive-magit--payload
        (rust-dive-magit-tests--diff-payload
          :lhs-rev "commit-a^"
          :rhs-rev "commit-a"))
      (should-error
        (rust-dive-magit-previous-commit)
        :type 'user-error))))

(ert-deftest rust-dive-magit-next-commit-errors-at-head ()
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
      (rust-dive-magit-mode)
      (setq rust-dive-magit--payload
        (rust-dive-magit-tests--diff-payload
          :lhs-rev "commit-b"
          :rhs-rev "commit-c"))
      (should-error
        (rust-dive-magit-next-commit)
        :type 'user-error))))

(ert-deftest rust-dive-magit-refresh-preserves-magit-display-state ()
  (let ((rust-dive-magit-default-grouping 'file))
    (with-temp-buffer
      (rename-buffer rust-dive-magit-buffer-name t)
      (rust-dive-magit-mode)
      (setq rust-dive-magit--default-directory "/tmp/repo/")
      (setq rust-dive-magit--command-args '("diff" "HEAD~1" "HEAD"))
      (setq rust-dive-magit--payload
        rust-dive-magit-tests--refresh-payload)
      (setq rust-dive-magit--grouping 'kind)
      (let ((inhibit-read-only t))
        (rust-dive-magit--insert-payload
          rust-dive-magit-tests--refresh-payload))
      (let*
        (
          (root magit-root-section)
          (kind-section (car (oref root children)))
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
              ((symbol-function 'rust-dive-magit--run-command)
                (lambda (_default-directory _args)
                  rust-dive-magit-tests--refresh-payload))
              ((symbol-function 'pop-to-buffer)
                (lambda (&rest _) nil)))
            (rust-dive-magit-refresh))
          (let*
            (
              (new-root magit-root-section)
              (new-kind-section (car (oref new-root children)))
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
            (should (eq rust-dive-magit--grouping 'kind))
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

(ert-deftest rust-dive-magit-tab-toggles-commit-message-at-point ()
  (cl-letf
    (
      ((symbol-function 'magit-git-string)
        (lambda (&rest args)
          (pcase args
            (`("log" "-1" "--format=%B" "HEAD~1")
              "Subject line\n\nBody line")
            (_ (error "Unexpected git args: %S" args))))))
    (with-temp-buffer
      (rust-dive-magit-mode)
      (setq rust-dive-magit--default-directory "/tmp/repo/")
      (let ((inhibit-read-only t))
        (rust-dive-magit--insert-payload
          rust-dive-magit-tests--sample-payload))
      (should-not (string-match-p "Body line" (buffer-string)))
      (goto-char (point-min))
      (search-forward "lhs: ")
      (rust-dive-magit-toggle-section-or-message)
      (should
        (string-match-p
          "  Subject line\n\n  Body line\n"
          (buffer-string)))
      (rust-dive-magit-toggle-section-or-message)
      (should-not (string-match-p "Body line" (buffer-string))))))

(ert-deftest rust-dive-magit-m-toggles-both-commit-messages ()
  (cl-letf
    (
      ((symbol-function 'magit-git-string)
        (lambda (&rest args)
          (pcase args
            (`("log" "-1" "--format=%B" "HEAD~1") "Left subject")
            (`("log" "-1" "--format=%B" "HEAD") "Right subject")
            (_ (error "Unexpected git args: %S" args))))))
    (with-temp-buffer
      (rust-dive-magit-mode)
      (setq rust-dive-magit--default-directory "/tmp/repo/")
      (let ((inhibit-read-only t))
        (rust-dive-magit--insert-payload
          rust-dive-magit-tests--sample-payload))
      (rust-dive-magit-toggle-commit-messages)
      (should (string-match-p "  Left subject\n" (buffer-string)))
      (should (string-match-p "  Right subject\n" (buffer-string)))
      (rust-dive-magit-toggle-commit-messages)
      (should-not (string-match-p "Left subject" (buffer-string)))
      (should-not (string-match-p "Right subject" (buffer-string))))))

(ert-deftest rust-dive-magit-faces-added-and-deleted-entities ()
  (let*
    (
      (payload
        (rust-dive-magit-tests--diff-payload
          :added
          (list
            (rust-dive-magit-tests--entity
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
            (rust-dive-magit-tests--entity
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
      (rust-dive-magit-mode)
      (let ((inhibit-read-only t))
        (rust-dive-magit--insert-payload payload))
      (goto-char (point-min))
      (search-forward "+ demo::added")
      (should
        (eq
          (get-text-property (match-beginning 0) 'font-lock-face)
          'rust-dive-magit-level-2-heading))
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
          'rust-dive-magit-level-2-heading))
      (search-forward "fn deleted() {}")
      (should
        (eq
          (get-text-property (match-beginning 0) 'font-lock-face)
          'magit-diff-removed)))))

(ert-deftest rust-dive-magit-renders-structured-modified-diff-faces ()
  (with-temp-buffer
    (rust-dive-magit-mode)
    (let ((inhibit-read-only t))
      (rust-dive-magit--insert-payload
        rust-dive-magit-tests--sample-payload))
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

(ert-deftest rust-dive-magit-splits-path-input ()
  (should
    (equal
      (rust-dive-magit--split-paths "src/lib.rs, src/main.rs ,")
      '("src/lib.rs" "src/main.rs")))
  (should-not (rust-dive-magit--split-paths "")))

(ert-deftest rust-dive-magit-diff-omits-width-for-json-output ()
  (cl-letf
    (
      ((symbol-function 'rust-dive-magit--repo-root)
        (lambda () "/tmp/repo/"))
      ((symbol-function 'rust-dive-magit--run-command)
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
          rust-dive-magit-tests--sample-payload))
      ((symbol-function 'rust-dive-magit--display-buffer)
        (lambda (_default-directory _args _payload) nil)))
    (rust-dive-magit-diff "HEAD~1" "HEAD" '("src/lib.rs"))))

(ert-deftest rust-dive-magit-cycle-grouping-redraws-buffer ()
  (with-temp-buffer
    (rust-dive-magit-mode)
    (setq rust-dive-magit--default-directory "/tmp/repo/")
    (setq rust-dive-magit--command-args '("diff" "HEAD~1" "HEAD"))
    (setq rust-dive-magit--payload
      rust-dive-magit-tests--multi-file-payload)
    (setq rust-dive-magit--grouping 'kind)
    (cl-letf
      (((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (rust-dive-magit-cycle-grouping))
    (should (eq rust-dive-magit-default-grouping 'file))
    (should (eq rust-dive-magit--grouping 'file))
    (with-current-buffer rust-dive-magit-buffer-name
      (let*
        (
          (root magit-root-section)
          (file-section (car (oref root children)))
          (kind-section (car (oref file-section children)))
          (entity-section (car (oref kind-section children)))
          (text (buffer-string)))
        (should-not (string-match-p "Grouping:" text))
        (should-not (oref file-section hidden))
        (should-not (oref kind-section hidden))
        (should (oref entity-section hidden))))))

(ert-deftest rust-dive-magit-shortens-path-backed-diff-labels ()
  (with-temp-buffer
    (rust-dive-magit-mode)
    (let ((inhibit-read-only t))
      (rust-dive-magit--insert-payload
        (rust-dive-magit-tests--diff-payload
          :lhs-label "/Users/dev/work/incubator/2026-04-21-diff@5767f35^"
          :rhs-label "/Users/dev/work/incubator/2026-04-21-diff@5767f35")))
    (should
      (string-prefix-p
        (concat
          "lhs: 2026-04-21-diff@5767f35^  Commit HEAD~1\n"
          "rhs: 2026-04-21-diff@5767f35  Commit HEAD\n\n")
        (buffer-string)))))

(ert-deftest rust-dive-magit-renders-clickable-diff-snapshots ()
  (with-temp-buffer
    (rust-dive-magit-mode)
    (let ((inhibit-read-only t))
      (rust-dive-magit--insert-payload
        rust-dive-magit-tests--sample-payload))
    (goto-char (point-min))
    (search-forward "repo@HEAD~1")
    (should (button-at (1- (point))))
    (search-forward "repo@HEAD")
    (should (button-at (1- (point))))))

(ert-deftest rust-dive-magit-visits-git-revision-snapshot ()
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
      (rust-dive-magit--visit-snapshot
        (rust-dive-magit-tests--git-revision "repo@HEAD~1" "HEAD~1")))
    (should (equal visited-rev "HEAD~1"))
    (should (equal visited-directory "/tmp/repo"))))

(ert-deftest rust-dive-magit-ret-visits-diff-snapshot ()
  (let (visited-rev)
    (cl-letf
      (
        ((symbol-function 'magit-show-commit)
          (lambda (rev &rest _) (setq visited-rev rev))))
      (with-temp-buffer
        (rust-dive-magit-mode)
        (let ((inhibit-read-only t))
          (rust-dive-magit--insert-payload
            rust-dive-magit-tests--sample-payload))
        (goto-char (point-min))
        (search-forward "rhs: ")
        (search-forward "repo@HEAD")
        (rust-dive-magit-visit-thing)))
    (should (equal visited-rev "HEAD"))))

(ert-deftest rust-dive-magit-dwim-endpoints-from-commit ()
  (should
    (equal
      (rust-dive-magit--dwim-endpoints
        '(commit . "HEAD~2")
        "/tmp/repo")
      '("HEAD~2^" "HEAD~2"))))

(ert-deftest rust-dive-magit-dwim-endpoints-from-range ()
  (should
    (equal
      (rust-dive-magit--dwim-endpoints "main..feature" "/tmp/repo")
      '("main" "feature")))
  (should
    (equal
      (rust-dive-magit--dwim-endpoints "HEAD" "/tmp/repo")
      '("HEAD" "/tmp/repo"))))

(ert-deftest rust-dive-magit-dwim-endpoints-from-worktree-context ()
  (should
    (equal
      (rust-dive-magit--dwim-endpoints 'unstaged "/tmp/repo")
      '("HEAD" "/tmp/repo")))
  (should
    (equal
      (rust-dive-magit--dwim-endpoints nil "/tmp/repo")
      '("HEAD" "/tmp/repo"))))

(ert-deftest rust-dive-magit-bindings-mode-registers-magit-suffix ()
  (require 'magit-diff)
  (unwind-protect
    (progn
      (rust-dive-magit-bindings-mode 1)
      (should (transient-get-suffix 'magit-diff "D")))
    (rust-dive-magit-bindings-mode -1)))

(ert-deftest rust-dive-magit-bindings-mode-registers-magit-diff-key ()
  (require 'magit-diff)
  (unwind-protect
    (progn
      (rust-dive-magit-bindings-mode 1)
      (should
        (eq
          (lookup-key magit-diff-mode-map (kbd "D"))
          #'rust-dive-magit-diff-at-point))
      (should
        (eq
          (lookup-key magit-diff-section-map (kbd "D"))
          #'rust-dive-magit-diff-at-point)))
    (rust-dive-magit-bindings-mode -1)))

(ert-deftest rust-dive-magit-diff-at-point-jumps-to-current-entity ()
  (let (ran-args)
    (cl-letf
      (
        ((symbol-function 'rust-dive-magit--repo-root)
          (lambda () "/tmp/repo/"))
        ((symbol-function 'magit-diff-arguments)
          (lambda (&rest _) (list '("--stat") nil)))
        ((symbol-function 'magit-diff--dwim)
          (lambda () "HEAD~1..HEAD"))
        ((symbol-function 'rust-dive-magit--magit-diff-path-at-point)
          (lambda () "src/lib.rs"))
        ((symbol-function 'rust-dive-magit--magit-diff-line-at-point)
          (lambda () 10))
        ((symbol-function 'rust-dive-magit--run-command)
          (lambda (_default-directory args)
            (setq ran-args args)
            rust-dive-magit-tests--sample-payload))
        ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (rust-dive-magit-diff-at-point))
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
    (with-current-buffer rust-dive-magit-buffer-name
      (let ((section (magit-current-section)))
        (should (equal (oref section type) 'rust-dive-entity))
        (should
          (equal
            (plist-get (oref section value) :summary)
            "+ demo::added"))
        (should-not (oref section hidden))))))

(ert-deftest rust-dive-magit-bindings-mode-registers-after-magit-load
  ()
  (when (featurep 'magit-diff)
    (unload-feature 'magit-diff t))
  (unwind-protect
    (progn
      (rust-dive-magit-bindings-mode 1)
      (should-not (featurep 'magit-diff))
      (require 'magit-diff)
      (should (transient-get-suffix 'magit-diff "D")))
    (rust-dive-magit-bindings-mode -1)))

(ert-deftest rust-dive-magit-bindings-mode-unregisters-magit-suffix ()
  (require 'magit-diff)
  (rust-dive-magit-bindings-mode 1)
  (rust-dive-magit-bindings-mode -1)
  (should-not
    (ignore-errors
      (transient-get-suffix 'magit-diff "D"))))

(ert-deftest rust-dive-magit-bindings-mode-unregisters-magit-diff-key
  ()
  (require 'magit-diff)
  (rust-dive-magit-bindings-mode 1)
  (rust-dive-magit-bindings-mode -1)
  (should-not
    (eq
      (lookup-key magit-diff-mode-map (kbd "D"))
      #'rust-dive-magit-diff-at-point))
  (should-not
    (eq
      (lookup-key magit-diff-section-map (kbd "D"))
      #'rust-dive-magit-diff-at-point)))

(provide 'rust-dive-magit-tests)

;;; rust-dive-magit-tests.el ends here
