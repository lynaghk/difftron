;;; rust-dive-magit-tests.el --- Tests for rust-dive-magit  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'json)

(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'rust-dive-magit)

(defconst rust-dive-magit-tests--sample-payload
  (json-parse-string
   "{
      \"command\": \"diff\",
      \"lhs\": {\"label\": \"repo@HEAD~1\", \"kind\": \"git_revision\", \"root\": \"/tmp/repo\", \"rev\": \"HEAD~1\"},
      \"rhs\": {\"label\": \"repo@HEAD\", \"kind\": \"git_revision\", \"root\": \"/tmp/repo\", \"rev\": \"HEAD\"},
      \"added\": [
        {\"name\": \"demo::added\", \"kind\": \"function\", \"rendered_summary\": \"function demo::added() @ /tmp/repo/src/lib.rs:10:1-12:2\", \"file_path\": \"/tmp/repo/src/lib.rs\", \"snapshot_path\": \"src/lib.rs\", \"start_line\": 10, \"start_col\": 1, \"end_line\": 12, \"end_col\": 2, \"source_text\": \"fn added() {}\"}
      ],
      \"deleted\": [],
      \"modified\": [
        {
          \"path\": \"src/lib.rs\",
          \"lhs\": {\"name\": \"demo::meaning\", \"kind\": \"function\", \"rendered_summary\": \"function demo::meaning() @ /tmp/repo/src/lib.rs:1:1-1:10\", \"file_path\": \"/tmp/repo/src/lib.rs\", \"snapshot_path\": \"src/lib.rs\", \"start_line\": 1, \"start_col\": 1, \"end_line\": 1, \"end_col\": 10, \"source_text\": \"fn meaning() -> u32 { 41 }\"},
          \"rhs\": {\"name\": \"demo::meaning\", \"kind\": \"function\", \"rendered_summary\": \"function demo::meaning() @ /tmp/repo/src/lib.rs:1:1-1:10\", \"file_path\": \"/tmp/repo/src/lib.rs\", \"snapshot_path\": \"src/lib.rs\", \"start_line\": 1, \"start_col\": 1, \"end_line\": 1, \"end_col\": 10, \"source_text\": \"fn meaning() -> u32 { 42 }\"},
          \"difftastic_display\": \"ANSI-DIFF\"
        }
      ]
    }"
   :object-type 'plist
   :array-type 'list))

(defconst rust-dive-magit-tests--multi-file-payload
  (json-parse-string
   "{
      \"command\": \"diff\",
      \"lhs\": {\"label\": \"repo@HEAD~1\", \"kind\": \"git_revision\", \"root\": \"/tmp/repo\", \"rev\": \"HEAD~1\"},
      \"rhs\": {\"label\": \"repo@HEAD\", \"kind\": \"git_revision\", \"root\": \"/tmp/repo\", \"rev\": \"HEAD\"},
      \"added\": [
        {\"name\": \"demo::added\", \"kind\": \"function\", \"rendered_summary\": \"function demo::added()\", \"file_path\": \"/tmp/repo/src/a.rs\", \"snapshot_path\": \"src/a.rs\", \"start_line\": 10, \"start_col\": 1, \"end_line\": 12, \"end_col\": 2, \"source_text\": \"fn added() {}\"}
      ],
      \"deleted\": [
        {\"name\": \"demo::old_struct\", \"kind\": \"struct\", \"rendered_summary\": \"struct demo::old_struct\", \"file_path\": \"/tmp/repo/src/b.rs\", \"snapshot_path\": \"src/b.rs\", \"start_line\": 20, \"start_col\": 1, \"end_line\": 22, \"end_col\": 2, \"source_text\": \"struct Old;\"}
      ],
      \"modified\": [
        {
          \"path\": \"src/b.rs\",
          \"lhs\": {\"name\": \"demo::meaning\", \"kind\": \"function\", \"rendered_summary\": \"function demo::meaning()\", \"file_path\": \"/tmp/repo/src/b.rs\", \"snapshot_path\": \"src/b.rs\", \"start_line\": 1, \"start_col\": 1, \"end_line\": 1, \"end_col\": 10, \"source_text\": \"fn meaning() -> u32 { 41 }\"},
          \"rhs\": {\"name\": \"demo::meaning\", \"kind\": \"function\", \"rendered_summary\": \"function demo::meaning()\", \"file_path\": \"/tmp/repo/src/b.rs\", \"snapshot_path\": \"src/b.rs\", \"start_line\": 1, \"start_col\": 1, \"end_line\": 1, \"end_col\": 10, \"source_text\": \"fn meaning() -> u32 { 42 }\"},
          \"difftastic_display\": \"ANSI-DIFF\"
        }
      ]
    }"
   :object-type 'plist
   :array-type 'list))

(ert-deftest rust-dive-magit-groups-items-by-kind ()
  (let* ((items (rust-dive-magit--diff-items rust-dive-magit-tests--sample-payload))
         (grouped (rust-dive-magit--group-items-by-kind items)))
    (should (equal (caar grouped) "function"))
    (should (equal (length grouped) 1))
    (should (equal (sort (mapcar (lambda (item)
                                   (plist-get (plist-get item :entity) :name))
                                 (copy-sequence (cdar grouped)))
                         #'string<)
                   '("demo::added" "demo::meaning")))))

(ert-deftest rust-dive-magit-groups-items-by-file ()
  (let* ((items (rust-dive-magit--diff-items rust-dive-magit-tests--multi-file-payload))
         (grouped (rust-dive-magit--group-items-by-file items)))
    (should (equal (mapcar #'car grouped) '("src/a.rs" "src/b.rs")))))

(ert-deftest rust-dive-magit-renders-diff-buffer ()
  (with-temp-buffer
    (rust-dive-magit-mode)
    (let ((inhibit-read-only t))
      (rust-dive-magit--insert-payload rust-dive-magit-tests--sample-payload))
    (let* ((text (buffer-string))
           (root magit-root-section)
           (kind-section (car (oref root children)))
           (file-section (car (oref kind-section children)))
           (entity-section (car (oref file-section children))))
      (should (string-match-p "rust_dive diff repo@HEAD~1 -> repo@HEAD" text))
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
      (should (string-match-p "ANSI-DIFF" text))
      (should-not (string-match-p "Location:" text))
      (should-not (string-match-p "function demo::added() @ /tmp/repo/src/lib.rs:10:1-12:2"
                                  text)))))

(ert-deftest rust-dive-magit-renders-kind-grouping-with-files ()
  (with-temp-buffer
    (rust-dive-magit-mode)
    (setq rust-dive-magit--grouping 'kind)
    (let ((inhibit-read-only t))
      (rust-dive-magit--insert-payload rust-dive-magit-tests--multi-file-payload))
    (let* ((root magit-root-section)
           (kind-section (car (oref root children)))
           (file-section (car (oref kind-section children)))
           (entity-section (car (oref file-section children))))
      (should (equal (oref kind-section type) 'rust-dive-kind))
      (should (equal (oref file-section type) 'rust-dive-file))
      (should (equal (oref entity-section type) 'rust-dive-entity))
      (goto-char (point-min))
      (search-forward "src/a.rs (1)")
      (should (eq (get-text-property (match-beginning 0) 'font-lock-face)
                  'rust-dive-magit-level-1-heading))
      (should (string-match-p "Grouping: Entity -> File" (buffer-string))))))

(ert-deftest rust-dive-magit-renders-file-grouping ()
  (with-temp-buffer
    (rust-dive-magit-mode)
    (setq rust-dive-magit--grouping 'file)
    (let ((inhibit-read-only t))
      (rust-dive-magit--insert-payload rust-dive-magit-tests--multi-file-payload))
    (let* ((root magit-root-section)
           (file-section (car (oref root children)))
           (entity-section (car (oref file-section children))))
      (should (equal (oref file-section type) 'rust-dive-file))
      (should (equal (oref entity-section type) 'rust-dive-entity))
      (goto-char (point-min))
      (search-forward "src/a.rs (1)")
      (should (eq (get-text-property (match-beginning 0) 'font-lock-face)
                  'magit-section-heading))
      (should (string-match-p "^src/a\\.rs (1)$" (buffer-string)))
      (should (string-match-p "^  \\+ demo::added$" (buffer-string)))
      (should (string-match-p "Grouping: File -> Entity" (buffer-string))))))

(ert-deftest rust-dive-magit-display-buffer-uses-default-grouping ()
  (let ((rust-dive-magit-default-grouping 'file))
    (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (rust-dive-magit--display-buffer
       "/tmp/repo/"
       '("diff" "HEAD~1" "HEAD")
       rust-dive-magit-tests--multi-file-payload))
    (with-current-buffer rust-dive-magit-buffer-name
      (let* ((root magit-root-section)
             (file-section (car (oref root children)))
             (entity-section (car (oref file-section children))))
        (should (eq rust-dive-magit--grouping 'file))
        (should (string-match-p "Grouping: File -> Entity" (buffer-string)))
        (should-not (oref file-section hidden))
        (should (oref entity-section hidden))))))    

(ert-deftest rust-dive-magit-faces-added-and-deleted-entities ()
  (let* ((payload (json-parse-string
                   "{
                      \"command\": \"diff\",
                      \"lhs\": {\"label\": \"repo@HEAD~1\", \"kind\": \"git_revision\", \"root\": \"/tmp/repo\", \"rev\": \"HEAD~1\"},
                      \"rhs\": {\"label\": \"repo@HEAD\", \"kind\": \"git_revision\", \"root\": \"/tmp/repo\", \"rev\": \"HEAD\"},
                      \"added\": [
                        {\"name\": \"demo::added\", \"kind\": \"function\", \"rendered_summary\": \"function demo::added()\", \"file_path\": \"/tmp/repo/src/lib.rs\", \"snapshot_path\": \"src/lib.rs\", \"start_line\": 10, \"start_col\": 1, \"end_line\": 12, \"end_col\": 2, \"source_text\": \"fn added() {}\"}
                      ],
                      \"deleted\": [
                        {\"name\": \"demo::deleted\", \"kind\": \"function\", \"rendered_summary\": \"function demo::deleted()\", \"file_path\": \"/tmp/repo/src/lib.rs\", \"snapshot_path\": \"src/lib.rs\", \"start_line\": 20, \"start_col\": 1, \"end_line\": 22, \"end_col\": 2, \"source_text\": \"fn deleted() {}\"}
                      ],
                      \"modified\": []
                    }"
                   :object-type 'plist
                   :array-type 'list)))
    (with-temp-buffer
      (rust-dive-magit-mode)
      (let ((inhibit-read-only t))
        (rust-dive-magit--insert-payload payload))
      (goto-char (point-min))
      (search-forward "+ demo::added")
      (should (eq (get-text-property (match-beginning 0) 'font-lock-face)
                  'rust-dive-magit-level-2-heading))
      (search-forward "fn added() {}")
      (should (eq (get-text-property (match-beginning 0) 'font-lock-face)
                  'magit-diff-added))
      (goto-char (point-min))
      (search-forward "- demo::deleted")
      (should (eq (get-text-property (match-beginning 0) 'font-lock-face)
                  'rust-dive-magit-level-2-heading))
      (search-forward "fn deleted() {}")
      (should (eq (get-text-property (match-beginning 0) 'font-lock-face)
                  'magit-diff-removed)))))

(ert-deftest rust-dive-magit-splits-path-input ()
  (should (equal (rust-dive-magit--split-paths "src/lib.rs, src/main.rs ,")
                 '("src/lib.rs" "src/main.rs")))
  (should-not (rust-dive-magit--split-paths "")))

(ert-deftest rust-dive-magit-diff-includes-current-width ()
  (cl-letf (((symbol-function 'rust-dive-magit--repo-root)
             (lambda () "/tmp/repo/"))
            ((symbol-function 'rust-dive-magit--current-display-width)
             (lambda () 123))
            ((symbol-function 'rust-dive-magit--run-command)
             (lambda (_default-directory args)
               (should (equal args
                              '("diff" "HEAD~1" "HEAD"
                                "--format" "json"
                                "--width" "123"
                                "--path" "src/lib.rs")))
               rust-dive-magit-tests--sample-payload))
            ((symbol-function 'rust-dive-magit--display-buffer)
             (lambda (_default-directory _args _payload) nil)))
    (rust-dive-magit-diff "HEAD~1" "HEAD" '("src/lib.rs"))))

(ert-deftest rust-dive-magit-cycle-grouping-redraws-buffer ()
  (with-temp-buffer
    (rust-dive-magit-mode)
    (setq rust-dive-magit--default-directory "/tmp/repo/")
    (setq rust-dive-magit--command-args '("diff" "HEAD~1" "HEAD"))
    (setq rust-dive-magit--payload rust-dive-magit-tests--multi-file-payload)
    (setq rust-dive-magit--grouping 'kind)
    (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (rust-dive-magit-cycle-grouping))
    (should (eq rust-dive-magit-default-grouping 'file))
    (should (eq rust-dive-magit--grouping 'file))
    (with-current-buffer rust-dive-magit-buffer-name
      (let* ((root magit-root-section)
             (file-section (car (oref root children)))
             (entity-section (car (oref file-section children)))
             (text (buffer-string)))
        (should (string-match-p "Grouping: File -> Entity" text))
        (should-not (oref file-section hidden))
        (should (oref entity-section hidden))))))

(ert-deftest rust-dive-magit-dwim-endpoints-from-commit ()
  (should (equal (rust-dive-magit--dwim-endpoints '(commit . "HEAD~2") "/tmp/repo")
                 '("HEAD~2^" "HEAD~2"))))

(ert-deftest rust-dive-magit-dwim-endpoints-from-range ()
  (should (equal (rust-dive-magit--dwim-endpoints "main..feature" "/tmp/repo")
                 '("main" "feature")))
  (should (equal (rust-dive-magit--dwim-endpoints "HEAD" "/tmp/repo")
                 '("HEAD" "/tmp/repo"))))

(ert-deftest rust-dive-magit-dwim-endpoints-from-worktree-context ()
  (should (equal (rust-dive-magit--dwim-endpoints 'unstaged "/tmp/repo")
                 '("HEAD" "/tmp/repo")))
  (should (equal (rust-dive-magit--dwim-endpoints nil "/tmp/repo")
                 '("HEAD" "/tmp/repo"))))

(ert-deftest rust-dive-magit-bindings-mode-registers-magit-suffix ()
  (require 'magit-diff)
  (unwind-protect
      (progn
        (rust-dive-magit-bindings-mode 1)
        (should (transient-get-suffix 'magit-diff "D")))
    (rust-dive-magit-bindings-mode -1)))

(ert-deftest rust-dive-magit-bindings-mode-unregisters-magit-suffix ()
  (require 'magit-diff)
  (rust-dive-magit-bindings-mode 1)
  (rust-dive-magit-bindings-mode -1)
  (should-not (ignore-errors (transient-get-suffix 'magit-diff "D"))))

(provide 'rust-dive-magit-tests)

;;; rust-dive-magit-tests.el ends here
