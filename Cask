(source melpa)

(package-descriptor "lisp/magit2-pkg.el")
(files ("lisp/magit2"
        "lisp/magit2*.el"
        "lisp/git-rebase.el"
        "docs/magit2.texi"
        "docs/AUTHORS.md"
        "LICENSE"
        (:exclude "lisp/magit2-libgit2.el"
                  "lisp/magit2-section.el"
                  "lisp/magit2-section-pkg.el")
        ;; temporarily for stable:
        "Documentation/magit2.texi"
        "Documentation/AUTHORS.md"))

(development
 (depends-on "libgit2" :git "https://github.com/dickmao/libgit2-el.git"
             :files ("CMakeLists.txt" "libgit2.el" "src")))
