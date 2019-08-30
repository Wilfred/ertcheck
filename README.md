# propcheck [![Build Status](https://travis-ci.org/Wilfred/propcheck.svg?branch=master)](https://travis-ci.org/Wilfred/propcheck)

propcheck brings property based testing to elisp.

It's similar to the excellent [Hypothesis](https://hypothesis.works/)
library for Python.

Status: beta. It works, but expect rough edges.

## Usage

Tests are defined with `propcheck-deftest`, which defines an ERT test
just like `ert-deftest`.

Your test should generate input values with the propcheck generator
functions, then call `propcheck-should` to make assertions about the
result.

```emacs-lisp
(require 'propcheck)

(defun buggy-zerop (num)
  ;; Return t for all values >= 0, so our minimal example should be 1.
  (>= num 0))

(propcheck-deftest buggy-zerop-should-match-zerop ()
  (let* ((i (propcheck-generate-integer "i"))
         (result (buggy-zerop i)))
    (propcheck-should
     ;; If `zerop' returns t, we should also return t, otherwise we
     ;; should return false.
     (if (zerop i) result (not result)))))
```

## Generators

propcheck provides the following generators:

* `propcheck-generate-bool`
* `propcheck-generate-integer`
* `propcheck-generate-ascii-char`
* `propcheck-generate-proper-list`
* `propcheck-generate-vector`
* `propcheck-generate-string`
