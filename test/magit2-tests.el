;;; magit2-tests.el --- tests for Magit

;; Copyright (C) 2011-2022  The Magit Project Contributors
;;
;; License: GPLv3

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'ert)
(require 'tramp)
(require 'tramp-sh)

(require 'magit2)

(defun magit2-test-init-repo (dir &rest args)
  (let ((magit2-git-global-arguments
         (nconc (list "-c" "init.defaultBranch=master")
                magit2-git-global-arguments)))
    (magit2-git "init" args dir)))

(defmacro magit2-with-test-directory (&rest body)
  (declare (indent 0) (debug t))
  (let ((dir (make-symbol "dir")))
    `(let ((,dir (file-name-as-directory (make-temp-file "magit2-" t)))
           (process-environment process-environment))
       (push "GIT_AUTHOR_NAME=A U Thor" process-environment)
       (push "GIT_AUTHOR_EMAIL=a.u.thor@example.com" process-environment)
       (condition-case err
           (cl-letf (((symbol-function #'message) (lambda (&rest _))))
             (let ((default-directory (file-truename ,dir)))
               ,@body))
         (error (message "Keeping test directory:\n  %s" ,dir)
                (signal (car err) (cdr err))))
       (delete-directory ,dir t))))

(defmacro magit2-with-test-repository (&rest body)
  (declare (indent 0) (debug t))
  `(magit2-with-test-directory (magit2-test-init-repo ".") ,@body))

(defmacro magit2-with-bare-test-repository (&rest body)
  (declare (indent 1) (debug t))
  `(magit2-with-test-directory (magit2-test-init-repo "." "--bare") ,@body))

;;; Git

(ert-deftest magit2--with-safe-default-directory ()
  (magit2-with-test-directory
    (let ((find-file-visit-truename nil))
      (should (equal (magit2-toplevel "repo/")
                     (magit2-toplevel (expand-file-name "repo/"))))
      (should (equal (magit2-toplevel "repo")
                     (magit2-toplevel (expand-file-name "repo/")))))))

(ert-deftest magit2-toplevel:basic ()
  (let ((find-file-visit-truename nil))
    (magit2-with-test-directory
      (magit2-test-init-repo "repo")
      (magit2-test-magit2-toplevel)
      (should (equal (magit2-toplevel   "repo/.git/")
                     (expand-file-name "repo/")))
      (should (equal (magit2-toplevel   "repo/.git/objects/")
                     (expand-file-name "repo/")))
      (should (equal (magit2-toplevel   "repo-link/.git/")
                     (expand-file-name "repo-link/")))
      (should (equal (magit2-toplevel   "repo-link/.git/objects/")
                     ;; We could theoretically return "repo-link/"
                     ;; here by going up until `--git-dir' gives us
                     ;; "." .  But that would be a bit risky and Magit
                     ;; never goes there anyway, so it's not worth it.
                     ;; But in the doc-string we say we cannot do it.
                     (expand-file-name "repo/"))))))

(ert-deftest magit2-toplevel:tramp ()
  (cl-letf* ((find-file-visit-truename nil)
             ;; Override tramp method so that we don't actually
             ;; require a functioning `sudo'.
             (sudo-method (cdr (assoc "sudo" tramp-methods)))
             ((cdr (assq 'tramp-login-program sudo-method))
              (list (if (file-executable-p "/bin/sh")
                        "/bin/sh"
                      shell-file-name)))
             ((cdr (assq 'tramp-login-args sudo-method)) nil))
    (magit2-with-test-directory
     (setq default-directory
           (concat (format "/sudo:%s@localhost:" (user-login-name))
                   default-directory))
     (magit2-test-init-repo "repo")
     (magit2-test-magit2-toplevel)
     (should (equal (magit2-toplevel   "repo/.git/")
                    (expand-file-name "repo/")))
     (should (equal (magit2-toplevel   "repo/.git/objects/")
                    (expand-file-name "repo/")))
     (should (equal (magit2-toplevel   "repo-link/.git/")
                    (expand-file-name "repo-link/")))
     (should (equal (magit2-toplevel   "repo-link/.git/objects/")
                    (expand-file-name "repo/"))))))

(ert-deftest magit2-toplevel:submodule ()
  (let ((find-file-visit-truename nil))
    (magit2-with-test-directory
      (magit2-test-init-repo "remote")
      (let ((default-directory (expand-file-name "remote/")))
        (magit2-git "commit" "-m" "init" "--allow-empty"))
      (magit2-test-init-repo "super")
      (setq default-directory (expand-file-name "super/"))
      (magit2-git "submodule" "add" "../remote" "repo/")
      (magit2-test-magit2-toplevel)
      (should (equal (magit2-toplevel   ".git/modules/repo/")
                     (expand-file-name "repo/")))
      (should (equal (magit2-toplevel   ".git/modules/repo/objects/")
                     (expand-file-name "repo/"))))))

(defun magit2-test-magit2-toplevel ()
  ;; repo
  (make-directory "repo/subdir/subsubdir" t)
  (should (equal (magit2-toplevel   "repo/")
                 (expand-file-name "repo/")))
  (should (equal (magit2-toplevel   "repo/")
                 (expand-file-name "repo/")))
  (should (equal (magit2-toplevel   "repo/subdir/")
                 (expand-file-name "repo/")))
  (should (equal (magit2-toplevel   "repo/subdir/subsubdir/")
                 (expand-file-name "repo/")))
  ;; repo-link
  (make-symbolic-link "repo" "repo-link")
  (should (equal (magit2-toplevel   "repo-link/")
                 (expand-file-name "repo-link/")))
  (should (equal (magit2-toplevel   "repo-link/subdir/")
                 (expand-file-name "repo-link/")))
  (should (equal (magit2-toplevel   "repo-link/subdir/subsubdir/")
                 (expand-file-name "repo-link/")))
  ;; *subdir-link
  (make-symbolic-link "repo/subdir"           "subdir-link")
  (make-symbolic-link "repo/subdir/subsubdir" "subsubdir-link")
  (should (equal (magit2-toplevel   "subdir-link/")
                 (expand-file-name "repo/")))
  (should (equal (magit2-toplevel   "subdir-link/subsubdir/")
                 (expand-file-name "repo/")))
  (should (equal (magit2-toplevel   "subsubdir-link")
                 (expand-file-name "repo/")))
  ;; subdir-link-indirect
  (make-symbolic-link "subdir-link" "subdir-link-indirect")
  (should (equal (magit2-toplevel   "subdir-link-indirect")
                 (expand-file-name "repo/")))
  ;; wrap/*link
  (magit2-test-init-repo "wrap")
  (make-symbolic-link "../repo"                  "wrap/repo-link")
  (make-symbolic-link "../repo/subdir"           "wrap/subdir-link")
  (make-symbolic-link "../repo/subdir/subsubdir" "wrap/subsubdir-link")
  (should (equal (magit2-toplevel   "wrap/repo-link/")
                 (expand-file-name "wrap/repo-link/")))
  (should (equal (magit2-toplevel   "wrap/subdir-link")
                 (expand-file-name "repo/")))
  (should (equal (magit2-toplevel   "wrap/subsubdir-link")
                 (expand-file-name "repo/"))))

(defun magit2-test-magit2-get ()
  (should (equal (magit2-get-all "a.b") '("val1" "val2")))
  (should (equal (magit2-get "a.b") "val2"))
  (let ((default-directory (expand-file-name "../remote/")))
    (should (equal (magit2-get "a.b") "remote-value")))
  (should (equal (magit2-get "CAM.El.Case.VAR") "value"))
  (should (equal (magit2-get "a.b2") "line1\nline2")))

(ert-deftest magit2-get ()
  (magit2-with-test-directory
   (magit2-test-init-repo "remote")
   (let ((default-directory (expand-file-name "remote/")))
     (magit2-git "commit" "-m" "init" "--allow-empty")
     (magit2-git "config" "a.b" "remote-value"))
   (magit2-test-init-repo "super")
   (setq default-directory (expand-file-name "super/"))
   ;; Some tricky cases:
   ;; Multiple config values.
   (magit2-git "config" "a.b" "val1")
   (magit2-git "config" "--add" "a.b" "val2")
   ;; CamelCase variable names.
   (magit2-git "config" "Cam.El.Case.Var" "value")
   ;; Values with newlines.
   (magit2-git "config" "a.b2" "line1\nline2")
   ;; Config variables in submodules.
   (magit2-git "submodule" "add" "../remote" "repo/")

   (magit2-test-magit2-get)
   (let ((magit2--refresh-cache (list (cons 0 0))))
     (magit2-test-magit2-get))))

(ert-deftest magit2-get-boolean ()
  (magit2-with-test-repository
    (magit2-git "config" "a.b" "true")
    (should     (magit2-get-boolean "a.b"))
    (should     (magit2-get-boolean "a" "b"))
    (magit2-git "config" "a.b" "false")
    (should-not (magit2-get-boolean "a.b"))
    (should-not (magit2-get-boolean "a" "b"))
    ;; Multiple values, last one wins.
    (magit2-git "config" "--add" "a.b" "true")
    (should     (magit2-get-boolean "a.b"))
    (let ((magit2--refresh-cache (list (cons 0 0))))
     (should    (magit2-get-boolean "a.b")))))

(ert-deftest magit2-get-{current|next}-tag ()
  (magit2-with-test-repository
    (magit2-git "commit" "-m" "1" "--allow-empty")
    (should (equal (magit2-get-current-tag) nil))
    (should (equal (magit2-get-next-tag)    nil))
    (magit2-git "tag" "1")
    (should (equal (magit2-get-current-tag) "1"))
    (should (equal (magit2-get-next-tag)    nil))
    (magit2-git "commit" "-m" "2" "--allow-empty")
    (magit2-git "tag" "2")
    (should (equal (magit2-get-current-tag) "2"))
    (should (equal (magit2-get-next-tag)    nil))
    (magit2-git "commit" "-m" "3" "--allow-empty")
    (should (equal (magit2-get-current-tag) "2"))
    (should (equal (magit2-get-next-tag)    nil))
    (magit2-git "commit" "-m" "4" "--allow-empty")
    (magit2-git "tag" "4")
    (magit2-git "reset" "HEAD~")
    (should (equal (magit2-get-current-tag) "2"))
    (should (equal (magit2-get-next-tag)    "4"))))

(ert-deftest magit2-list-{|local-|remote-}branch-names ()
  (magit2-with-test-repository
    (magit2-git "commit" "-m" "init" "--allow-empty")
    (magit2-git "update-ref" "refs/remotes/foobar/master" "master")
    (magit2-git "update-ref" "refs/remotes/origin/master" "master")
    (should (equal (magit2-list-branch-names)
                   (list "master" "foobar/master" "origin/master")))
    (should (equal (magit2-list-local-branch-names)
                   (list "master")))
    (should (equal (magit2-list-remote-branch-names)
                   (list "foobar/master" "origin/master")))
    (should (equal (magit2-list-remote-branch-names "origin")
                   (list "origin/master")))
    (should (equal (magit2-list-remote-branch-names "origin" t)
                   (list "master")))))

(ert-deftest magit2-process:match-prompt-nil-when-no-match ()
  (should (null (magit2-process-match-prompt '("^foo: ?$") "bar: "))))

(ert-deftest magit2-process:match-prompt-non-nil-when-match ()
  (should (magit2-process-match-prompt '("^foo: ?$") "foo: ")))

(ert-deftest magit2-process:match-prompt-match-non-first-prompt ()
  (should (magit2-process-match-prompt '("^bar: ?$ " "^foo: ?$") "foo: ")))

(ert-deftest magit2-process:match-prompt-suffixes-prompt ()
  (let ((prompts '("^foo: ?$")))
    (should (equal (magit2-process-match-prompt prompts "foo:")  "foo: "))
    (should (equal (magit2-process-match-prompt prompts "foo: ") "foo: "))))

(ert-deftest magit2-process:match-prompt-preserves-match-group ()
  (let* ((prompts '("^foo '\\(?99:.*\\)': ?$"))
         (prompt (magit2-process-match-prompt prompts "foo 'bar':")))
    (should (equal prompt "foo 'bar': "))
    (should (equal (match-string 99 "foo 'bar':") "bar"))))

(ert-deftest magit2-process:password-prompt ()
  (let ((magit2-process-find-password-functions
         (list (lambda (host) (when (string= host "www.host.com") "mypasswd")))))
    (cl-letf (((symbol-function 'process-send-string)
               (lambda (process string) string)))
      (should (string-equal (magit2-process-password-prompt
                             nil "Password for 'www.host.com':")
                            "mypasswd\n")))))

(ert-deftest magit2-process:password-prompt-observed ()
  (with-temp-buffer
    (cl-letf* ((test-proc (start-process
                           "dummy-proc" (current-buffer)
                           (concat invocation-directory invocation-name)
                           "-Q" "--batch" "--eval" "(read-string \"\")"))
               ((symbol-function 'read-passwd)
                (lambda (_) "mypasswd"))
               (sent-strings nil)
               ((symbol-function 'process-send-string)
                (lambda (_proc string) (push string sent-strings))))
      ;; Don't get stuck when we close the buffer.
      (set-process-query-on-exit-flag test-proc nil)
      ;; Try some example passphrase prompts, reported by users.
      (dolist (prompt '("
Enter passphrase for key '/home/user/.ssh/id_rsa': "
                        ;; Openssh 8.0 sends carriage return.
                        "\
\rEnter passphrase for key '/home/user/.ssh/id_ed25519': "))
        (magit2-process-filter test-proc prompt)
        (should (equal (pop sent-strings) "mypasswd\n")))
      (should (null sent-strings)))))

;;; Status

(defun magit2-test-get-section (list file)
  (magit2-status-internal default-directory)
  (--first (equal (oref it value) file)
           (oref (magit2-get-section `(,list (status)))
                 children)))

(ert-deftest magit2-status:file-sections ()
  (magit2-with-test-repository
    (cl-flet ((modify (file) (with-temp-file file
                               (insert (make-temp-name "content")))))
      (modify "file")
      (modify "file with space")
      (modify "file with äöüéλ")
      (should (magit2-test-get-section '(untracked) "file"))
      (should (magit2-test-get-section '(untracked) "file with space"))
      (should (magit2-test-get-section '(untracked) "file with äöüéλ"))
      (magit2-stage-modified t)
      (should (magit2-test-get-section '(staged) "file"))
      (should (magit2-test-get-section '(staged) "file with space"))
      (should (magit2-test-get-section '(staged) "file with äöüéλ"))
      (magit2-git "add" ".")
      (modify "file")
      (modify "file with space")
      (modify "file with äöüéλ")
      (should (magit2-test-get-section '(unstaged) "file"))
      (should (magit2-test-get-section '(unstaged) "file with space"))
      (should (magit2-test-get-section '(unstaged) "file with äöüéλ")))))

(ert-deftest magit2-status:log-sections ()
  (magit2-with-test-repository
    (magit2-git "commit" "-m" "common" "--allow-empty")
    (magit2-git "commit" "-m" "unpulled" "--allow-empty")
    (magit2-git "remote" "add" "origin" "/origin")
    (magit2-git "update-ref" "refs/remotes/origin/master" "master")
    (magit2-git "branch" "--set-upstream-to=origin/master")
    (magit2-git "reset" "--hard" "HEAD~")
    (magit2-git "commit" "-m" "unpushed" "--allow-empty")
    (should (magit2-test-get-section
             '(unpulled . "..@{upstream}")
             (magit2-rev-parse "--short" "origin/master")))
    (should (magit2-test-get-section
             '(unpushed . "@{upstream}..")
             (magit2-rev-parse "--short" "master")))))

;;; libgit2

(ert-deftest magit2-in-bare-repo ()
  "Test `magit2-bare-repo-p' in a bare repository."
  (magit2-with-bare-test-repository
    (should (magit2-bare-repo-p))))

(ert-deftest magit2-in-non-bare-repo ()
  "Test `magit2-bare-repo-p' in a non-bare repository."
  (magit2-with-test-repository
    (should-not (magit2-bare-repo-p))))

;;; Utils

(ert-deftest magit2-utils:add-face-text-property ()
  (let ((str (concat (propertize "ab" 'font-lock-face 'highlight) "cd")))
    (magit2--add-face-text-property 0 (length str) 'bold nil str)
    (should (equal (get-text-property 0 'font-lock-face str) '(bold highlight)))
    (should (equal (get-text-property 2 'font-lock-face str) '(bold)))))

;;; magit2-tests.el ends soon
(provide 'magit2-tests)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; magit2-tests.el ends here
