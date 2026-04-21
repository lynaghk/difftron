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
        {\"name\": \"demo::added\", \"kind\": \"function\", \"rendered_summary\": \"function demo::added() @ /tmp/repo/src/lib.rs:10:1-12:2\", \"file_path\": \"/tmp/repo/src/lib.rs\", \"relative_path\": \"src/lib.rs\", \"start_line\": 10, \"start_col\": 1, \"end_line\": 12, \"end_col\": 2, \"source_text\": \"fn added() {}\"}
      ],
      \"deleted\": [],
      \"modified\": [
        {
          \"path\": \"src/lib.rs\",
          \"lhs\": {\"name\": \"demo::meaning\", \"kind\": \"function\", \"rendered_summary\": \"function demo::meaning() @ /tmp/repo/src/lib.rs:1:1-1:10\", \"file_path\": \"/tmp/repo/src/lib.rs\", \"relative_path\": \"src/lib.rs\", \"start_line\": 1, \"start_col\": 1, \"end_line\": 1, \"end_col\": 10, \"source_text\": \"fn meaning() -> u32 { 41 }\"},
          \"rhs\": {\"name\": \"demo::meaning\", \"kind\": \"function\", \"rendered_summary\": \"function demo::meaning() @ /tmp/repo/src/lib.rs:1:1-1:10\", \"file_path\": \"/tmp/repo/src/lib.rs\", \"relative_path\": \"src/lib.rs\", \"start_line\": 1, \"start_col\": 1, \"end_line\": 1, \"end_col\": 10, \"source_text\": \"fn meaning() -> u32 { 42 }\"}
        }
      ]
    }"
   :object-type 'plist
   :array-type 'list))

(ert-deftest rust-dive-magit-groups-entities-by-path ()
  (let* ((entities (plist-get rust-dive-magit-tests--sample-payload :added))
         (grouped (rust-dive-magit--group-by-path entities)))
    (should (equal (caar grouped) "src/lib.rs"))
    (should (equal (length grouped) 1))
    (should (equal (plist-get (cadar grouped) :name) "demo::added"))))

(ert-deftest rust-dive-magit-renders-diff-buffer ()
  (with-temp-buffer
    (rust-dive-magit-mode)
    (let ((inhibit-read-only t))
      (rust-dive-magit--insert-payload rust-dive-magit-tests--sample-payload))
    (let ((text (buffer-string)))
      (should (string-match-p "rust_dive diff repo@HEAD~1 -> repo@HEAD" text))
      (should (string-match-p "Added" text))
      (should (string-match-p "Modified" text))
      (should (string-match-p "demo::meaning" text)))))

(ert-deftest rust-dive-magit-splits-path-input ()
  (should (equal (rust-dive-magit--split-paths "src/lib.rs, src/main.rs ,")
                 '("src/lib.rs" "src/main.rs")))
  (should-not (rust-dive-magit--split-paths "")))

(provide 'rust-dive-magit-tests)

;;; rust-dive-magit-tests.el ends here
