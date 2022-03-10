(source melpa)

(package-descriptor "lisp/magit-pkg.el")
(files ("lisp/magit"
        "lisp/magit*.el"
        "lisp/git-rebase.el"
        "docs/magit.texi"
        "docs/AUTHORS.md"
        "LICENSE"
        (:exclude "lisp/magit-libgit2.el"
                  "lisp/magit-section.el"
                  "lisp/magit-section-pkg.el")
        ;; temporarily for stable:
        "Documentation/magit.texi"
        "Documentation/AUTHORS.md"))

(development
 (depends-on "libgit2" :git "https://github.com/dickmao/libgit2-el.git"
             :files ("CMakeLists.txt" "libgit2.el" "src")))
