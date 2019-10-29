;;; propcheck.el --- quickcheck/hypothesis style testing for elisp         -*- lexical-binding: t; -*-

;; Copyright (C) 2019  Wilfred Hughes
;; Version: 0.1
;; Package-Requires: ((emacs "25.1") (dash "2.11.0") (dash-functional "1.2.0"))

;; Author: Wilfred Hughes <me@wilfred.me.uk>
;; Keywords: testing

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Property based testing for Emacs Lisp. Heavily influenced by the
;; wonderful Hypothesis project.

;; References:

;; https://hypothesis.works/articles/how-hypothesis-works/
;; https://hypothesis.readthedocs.io/en/latest/details.html#how-good-is-assume
;; https://github.com/HypothesisWorks/hypothesis/blob/master/guides/internals.rst

;;; Code:

(require 'dash)
(require 'dash-functional)
(eval-when-compile
  (require 'cl))

(defvar propcheck-max-examples 100)

;; Hypothesis-java uses 2000 for maxShrinks. You need to be generating
;; large (e.g. several lists) amounts of data before you can hit this
;; limit.
(defvar propcheck-max-shrinks 200)
(defvar propcheck--shrinks-remaining nil)
(defvar propcheck--replay nil)

(defvar propcheck-seed
  nil
  "The current seed being used to generate values.
This is a global variable so users aren't force to pass it to
generate functions.")

;; The value used to generate sample data. This is a list of bytes,
;; along with an index. When regenerating data, resetting the index to
;; 0 and calling the same generate functions will produce the same
;; values.
;;
;; Hypothesis calls this 'TestData'.
(defstruct
    (propcheck-seed
     :named
     (:constructor propcheck-seed
                   (&optional
                    (bytes nil)
                    (i 0)
                    (intervals nil))))
  bytes
  i
  intervals)

(defun propcheck--draw-bytes (seed num-bytes)
  "Get NUM-BYTES of random data from SEED, generating if necessary.
This function modifies SEED and returns the generated bytes."
  ;; Don't draw more bytes than the original seed if we're shrinking.
  (when (propcheck--shrinking-p)
    (when (>=
           (propcheck-seed-i seed)
           (length (propcheck-seed-bytes seed)))
      (throw 'propcheck--overrun t)))

  (propcheck--sanity-check seed)
  (let* ((i (propcheck-seed-i seed))
         (bytes (propcheck-seed-bytes seed))
         (new-i (+ i num-bytes)))
    ;; Update i to record our position in the bytes.
    (setf (propcheck-seed-i seed) new-i)

    ;; Record the intervals of bytes generated.
    (push (list i new-i) (propcheck-seed-intervals seed))

    (if (<= new-i (length bytes))
        ;; SEED already has sufficient bytes, just return the
        ;; previously generated bytes.
        (->> (propcheck-seed-bytes seed)
             (-drop i)
             (-take num-bytes))

      ;; We're currently generating data, add it to the existing
      ;; bytes.
      (let (rand-bytes)
        (dotimes (_ num-bytes)
          (push (random 255) rand-bytes))
        (setf (propcheck-seed-bytes seed) (-concat bytes rand-bytes))
        rand-bytes))))

(defun propcheck--draw-byte (seed)
  (car (propcheck--draw-bytes seed 1)))

(defun propcheck--shrinking-p ()
  "Are we currently shrinking after finding a seed that gives a
counterexample?"
  (or propcheck--shrinks-remaining propcheck--replay))

(defun propcheck--debug (&rest _)
  "Debugging helper function"
  ;; Deliberately don't do anything with the arguments. Instead, use
  ;; M-x trace-function to see values passed to this function when
  ;; also tracing shrinking logic.
  nil)

(defun propcheck--seek-start (seed)
  "Return a copy of SEED with i set to the beginning."
  (let ((i (propcheck-seed-i seed))
        (bytes (propcheck-seed-bytes seed))
        (intervals (propcheck-seed-intervals seed)))
    (propcheck--debug "remaining" propcheck--shrinks-remaining)
    (propcheck-seed
     (-take i bytes)
     0
     intervals)))

(defun propcheck--no-intervals (seed)
  "Return a copy of SEED with no intervals"
  (let ((i (propcheck-seed-i seed))
        (bytes (propcheck-seed-bytes seed)))
    (propcheck-seed
     bytes
     i
     nil)))

(defun propcheck--sanity-check (seed)
  (unless seed
    (error "seed must not be nil"))
  (unless (propcheck--shrinking-p)
    (unless (=
             (propcheck-seed-i seed)
             (length (propcheck-seed-bytes seed)))
      (error "Data should be growing when finding counterexamples"))))

;;; Generators

;; These functions generate a random value, updating `propcheck-seed'.
;; Wherever possible, generators should:
;;
;; * Produce smaller inputs on smaller seeds. If not, we report
;;   unnecessarily large counterexamples.
;; 
;; * Consume fewer bytes when given a smaller seed. If not, shrinking
;;   is less effective (see `propcheck--overrun' usage).

(defmacro propcheck-remember (name &rest body)
  "Evaluate BODY as `progn', but save the returned value in
`propcheck--replay' if we're replaying."
  (declare (indent 1) (debug t))
  (let ((name-sym (gensym "propcheck-name"))
        (val-sym (gensym "propcheck-val")))
    `(let ((,name-sym ,name)
           (,val-sym
            (progn
              ,@body)))
       (when (and ,name-sym propcheck--replay)
         (push (cons ,name-sym ,val-sym)
               propcheck--replay))
       ,val-sym)))

(defun propcheck-generate-bool (name)
  "Generate either nil or t."
  (propcheck-generate-one-of name :values '(nil t)))

;; Assume these are unsigned numbers. Generate an integer using as
;; many bits as necessary to generate a (MAX - MIN) number. Add MIN.

(defun propcheck--num-bits (num)
  "Return the number of BITS required for NUM."
  (let ((res 0))
    (while (not (zerop num))
      (setq num (lsh num -1))
      (cl-incf res))
    res))

(defun propcheck--generate-integer-up-to (max)
  "Generate an integer between 0 and MAX (inclusive).
Treats MAX as an unsigned integer."
  (let* ((num-bits (propcheck--num-bits max))
         (num-bytes (ceiling (/ num-bits 8.0)))
         (high-bits-needed (- num-bits
                              (* (1- num-bytes) 8)))
         (bytes (propcheck--draw-bytes propcheck-seed num-bytes))
         (num 0))
    (--each-indexed bytes
      ;; Avoid overflow for the bits in the highest byte.
      (when (zerop it-index)
        (setq it (lsh it (- high-bits-needed 8))))

      (setq num
            (+ (* num 256)
               it)))
    ;; We've generated a number up to 2^N, but that might exceed
    ;; MAX. Take a modulus.
    ;;
    ;; This ensures we draw numbers uniformly if MAX is a power 2. If
    ;; it isn't, lower numbers may occur up to 2x more often (due to
    ;; the modulus).
    (when (or
           (and (> max 0) (> num max))
           ;; Treating negative numbers as large positive numbers here.
           (and (< max 0) (< num max)))
      (setq num (- num max)))
    num))

(cl-defun propcheck-generate-integer (name &key min &key max)
  "Generate an interger between MIN and MAX (both inclusive).
Integers should be chosen fairly uniformly from the range.

If no limits are specified, values may be anywhere between
`most-positive-fixnum' and `most-negative-fixnum'."
  (when (and min max)
    (unless (< min max)
      (user-error "min %d is not less than max %d" min max)))
  (propcheck-remember name
    (let* ((num-min (or min most-negative-fixnum))
           (num-max (or max most-positive-fixnum))
           (range (- num-max num-min))
           (num (propcheck--generate-integer-up-to range)))
      (if (or min max)
          ;; If the user specified MIN or MAX, ensure our smallest
          ;; value is MIN. This means we shrink towards MIN.
          (+ num min)
        ;; If we weren't given a range, NUM will already cover the
        ;; whole range of integers. Don't add MIN, so we shrink towards zero.
        num))))

(defun propcheck--whole-num-p (num)
  "Return t if NUM is a whole number, even if it's a float."
  (= num (ceiling num)))

(defun propcheck--power-of-p (num base)
  "Return t if NUM is a power of BASE."
  (propcheck--whole-num-p (log num base)))

(cl-defun propcheck-generate-one-of (name &key values)
  "Generate a single item from the list VALUES."
  (let ((num-choices (length values)))
    (when (> (length values) 256)
      (user-error "propcheck-generate-one-of is limited to 256 choices."))
    (propcheck-remember name
      (let ((byte (propcheck--draw-byte propcheck-seed)))
        (if (propcheck--power-of-p num-choices 2)
            ;; Uniformly choose an item from the list, ensuring that
            ;; smaller bytes produce earlier numbers.
            ;; E.g. for 4 items:
            ;; 1-63: 0
            ;; 64-127: 1
            ;; 128-191: 2
            ;; 192-255: 3
            (nth (/ (* byte num-choices) 256) values)
          ;; Sadly this isn't uniform, it will choose items from
          ;; earlier in the list more often.
          (nth (mod byte num-choices) values))))))

(defun propcheck-generate-float (name)
  "Generate a floating point value."
  ;; TODO: nan, inf, cover the full floating point range.
  ;; TODO: this shrinks really poorly, favouring values near powers of
  ;; 2.
  (propcheck-remember name
    (let* ((significand-offset
            (propcheck-generate-integer nil :min 0 :max 10000))
           (significand
            ;; Significands can be 0.5 to 1.0, -0.5 to -1.0 or
            ;; 0.0. See info manual for `frexp'.
            (if (zerop significand-offset)
                0.0
              (+ 0.5 (/ significand-offset 10000.0))))
           (exponent
            (propcheck-generate-integer nil :min 0 :max 1000))
           (num
            (ldexp significand exponent)))
      (if (propcheck-generate-bool nil)
          num
        (- num)))))

(defun propcheck-generate-ascii-char (name)
  "Generate a number that's an ASCII char.
Note that elisp does not have a separate character type."
  (propcheck-remember name
    ;; between 32 and 126
    (let* ((byte (propcheck--draw-byte propcheck-seed))
           (min-ascii 32)
           (max-ascii 126)
           (ascii-range (- max-ascii min-ascii)))
      (+ min-ascii (mod byte ascii-range)))))

;; TODO: circular lists, improprer lists/trees.
(cl-defun propcheck-generate-proper-list (name &key value-fn)
  "Generate a list whose values are drawn from VALUE-FN."
  (propcheck-remember name
    (let ((result nil))
      ;; Make the list bigger most of the time. 50 is the threshold used
      ;; in ListStrategy.java in hypothesis-java.
      ;; See utils.py/more in Hypothesis for a smarter approach.
      (while (> (propcheck--draw-byte propcheck-seed) 50)
        (push (funcall value-fn nil) result))
      result)))

(defun propcheck-generate-vector (name &key value-fn)
  "Generate a vector whose values are drawn from VALUE-FN."
  (propcheck-remember name
    (apply #'vector
           (propcheck-generate-proper-list nil :value-fn value-fn))))

(defun propcheck-generate-string (name)
  "Generate a string."
  (propcheck-remember name
    (let ((chars nil))
      ;; 90% chance of making the string bigger on each loop. This
      ;; means 10% of outputs will be the empty string.
      ;; 
      ;; TODO: see what hypothesis does
      ;; TODO: multibyte support, key sequence support
      (while (>= (propcheck--draw-byte propcheck-seed) 26)
        (push
         (propcheck-generate-ascii-char nil)
         chars))
      (concat chars))))

(defun propcheck-should (valid-p)
  (propcheck--debug "valid" valid-p)
  (unless valid-p
    (throw 'propcheck--counterexample
           propcheck-seed)))

(defun propcheck--funcall-with-seed (fun seed)
  "Call FUN with SEED used to generate inputs.
If a counterexample is found, return the final seed."
  (let ((propcheck-seed
         ;; Discard the interval data before calling FUN, so we can
         ;; see if it uses different intervals in this run.
         (propcheck--no-intervals seed)))
    (catch 'propcheck--counterexample
      (catch 'propcheck--overrun
        (condition-case nil
            (funcall fun)
          (error
           ;; Consider an error to be another counterexample.
           (throw 'propcheck--counterexample propcheck-seed))))
      nil)))

(defun propcheck--find-counterexample (fun)
  "Call FUN until it finds a counterexample.

Returns the seed that produced the counterexample, or
nil if no counterexamples were found after
`propcheck-max-examples' attempts."
  (catch 'found
    (dotimes (_ propcheck-max-examples)
      ;; Generate a fresh seed and try the function.
      (let ((seed (propcheck--funcall-with-seed fun (propcheck-seed))))
        (when seed
          (throw 'found (propcheck--seek-start seed)))))))

(defun propcheck--list-< (x y)
  "Return t if X is less than Y, using a lexicographic ordering.
E.g. we consider (1 3) to be less than (2 2).

Assumes X and Y are the same length."
  (let ((result nil))
    (catch 'done
      (dotimes (i (length x))
        (let ((x-item (nth i x))
              (y-item (nth i y)))
          ;; List is definitely less, the most significant number is
          ;; less.
          (when (< x-item y-item)
            (setq result t)
            (throw 'done nil))
          ;; List is definitely greater, the most significant number
          ;; is greater.
          (when (> x-item y-item)
            (throw 'done nil))
          ;; Otherwise the two numbers are equal, carry on.
          )))
    result))

(defun propcheck--swap-intervals (seed i j)
  "Swap the bytes at interval I with inteval J in SEED,
if interval J is less than I.

Assumes I < J."
  (-let* ((bytes (propcheck-seed-bytes seed))
          (intervals (reverse (propcheck-seed-intervals seed)))
          ((i-start i-end) (nth i intervals))
          ((j-start j-end) (nth j intervals))
          (i-bytes (-slice bytes i-start i-end))
          (j-bytes (-slice bytes j-start j-end)))
    (when (and
           (= (length i-bytes) (length j-bytes))
           (propcheck--list-< j-bytes i-bytes))
      (dotimes (index (- i-end i-start))
        ;; Copy a byte from J to I.
        (setq seed
              (propcheck--set-byte
               seed
               (+ i-start index)
               (nth (+ j-start index) bytes)))
        ;; Write the old byte value of I into J.
        (setq seed
              (propcheck--set-byte
               seed
               (+ j-start index)
               (nth index i-bytes))))
      seed)))

(defun propcheck--shrink-swapping-intervals (test-fn seed)
  "Attempt to shrink SEED by reordering intervals and calling TEST-FN."
  (let ((i 0)
        (j 0)
        (changed t))
    ;; Keep going until we run out of shrinks, or we stop finding
    ;; intervals that we can swap.
    (catch 'out-of-shrinks
      (while changed
        (setq changed nil)
        (setq i 0)

        ;; The seed might shrink during iteration, so keep checking
        ;; the length.
        (while (< i (1- (length (propcheck-seed-intervals seed))))
          (setq j (1+ i))
          (while (< j (length (propcheck-seed-intervals seed)))
            (let ((shrunk-seed (propcheck--swap-intervals seed i j))
                  new-seed)
              (when shrunk-seed
                (setq new-seed
                      (propcheck--funcall-with-seed test-fn shrunk-seed))
                (when new-seed
                  (setq changed t)
                  (setq seed (propcheck--seek-start new-seed)))

                (cl-decf propcheck--shrinks-remaining)
                (unless (> propcheck--shrinks-remaining 0)
                  (throw 'out-of-shrinks t))))
            (cl-incf j))

          (cl-incf i)))))
  seed)

(defun propcheck--shrink-interval-by (test-fn shrink-fn seed)
  "Attempt to shrink SEED by calling TEST-FN with smaller values.
Reduce the size of SEED by applying SHRINK-FN."
  (let ((i 0)
        (changed t))
    ;; Keep going until we run out of shrinks, or we stop finding
    ;; bytes that we can shrink.
    (catch 'out-of-shrinks
      (while changed
        (setq changed nil)
        (setq i 0)

        ;; The seed might shrink during iteration, so keep checking
        ;; the length.
        (while (< i (length (propcheck-seed-intervals seed)))
          (let ((shrunk-seed (funcall shrink-fn seed i))
                new-seed)
            (when shrunk-seed
              (setq new-seed
                    (propcheck--funcall-with-seed test-fn shrunk-seed))
              (when new-seed
                (setq changed t)
                (setq seed (propcheck--seek-start new-seed)))

              (cl-decf propcheck--shrinks-remaining)
              (unless (> propcheck--shrinks-remaining 0)
                (throw 'out-of-shrinks t))))

          (cl-incf i)))))
  seed)

(defun propcheck--shrink-byte-by (test-fn shrink-fn seed)
  "Attempt to shrink SEED by calling TEST-FN with smaller values.
Reduce the size of SEED by applying SHRINK-FN."
  (let ((i 0)
        (changed t))
    ;; Keep going until we run out of shrinks, or we stop finding
    ;; bytes that we can shrink.
    (catch 'out-of-shrinks
      (while changed
        (setq changed nil)
        (setq i 0)

        ;; The seed might shrink during iteration, so keep checking
        ;; the length.
        (while (< i (length (propcheck-seed-bytes seed)))
          (let ((shrunk-seed (funcall shrink-fn seed i))
                new-seed)
            (when shrunk-seed
              (setq new-seed
                    (propcheck--funcall-with-seed test-fn shrunk-seed))
              (when new-seed
                (setq changed t)
                (setq seed (propcheck--seek-start new-seed)))

              (cl-decf propcheck--shrinks-remaining)
              (unless (> propcheck--shrinks-remaining 0)
                (throw 'out-of-shrinks t))))

          (cl-incf i)))))
  seed)

(defun propcheck--set-byte (seed i value)
  "Return a copy of SEED with byte I set to VALUE."
  (let ((bytes (propcheck-seed-bytes seed))
        (intervals (propcheck-seed-intervals seed)))
    (propcheck-seed
     (-replace-at i value bytes)
     (propcheck-seed-i seed)
     intervals)))

(defun propcheck--zero-byte (seed i)
  "Set byte at I in SEED to zero if it isn't already."
  (let* ((bytes (propcheck-seed-bytes seed))
         (byte (nth i bytes)))
    (unless (zerop byte)
      (propcheck--set-byte seed i 0))))

(defun propcheck--decrement-and-carry (bytes start-i)
  ;; Given a sequence X Y Z, convert to
  ;; X-1 Y+255 Z+255
  (--map-indexed
   (cond
    ((< it-index start-i)
     it)
    ((= it-index start-i)
     (1- it))
    (t
     (+ it 255)))
   bytes))

(defun propcheck--subtract-interval (seed i amount)
  "Subtract AMOUNT at I in SEED. If the result would be a seed of all zeroes,
return nil.

AMOUNT must be less than 255. Saturates at zero rather than
underflowing."
  (-let* ((seed-bytes (propcheck-seed-bytes seed))
          ((interval-start interval-end)
           (nth i (reverse (propcheck-seed-intervals seed))))
          (interval-bytes
           (-slice seed-bytes interval-start interval-end))
          (last-byte (-last-item interval-bytes)))
    (-when-let* ((first-nonzero-i
                  (--find-index (not (zerop it)) interval-bytes))
                 ;; Ensure that we won't end up with a zero seed afterwards.
                 (nonzero-result
                  (or (< first-nonzero-i (1- (length interval-bytes)))
                      (> last-byte amount))))
      (if (> last-byte amount)
          ;; It's sufficient to just decrement the last byte.
          (propcheck--set-byte seed (1- interval-end) (- last-byte amount))
        ;; The last byte isn't big enough, so find an earlier nonzero
        ;; byte, carry it to the later bytes, then do the subtraction.
        (let* ((carry-byte-i
                (--find-last-index (not (zerop it)) (-butlast interval-bytes)))
               (new-bytes (propcheck--decrement-and-carry interval-bytes carry-byte-i)))
          (--each-indexed new-bytes
            (setq seed
                  (propcheck--set-byte seed (+ interval-start it-index) it)))
          seed)))))

(defun propcheck--zero-interval (seed n)
  "Set interval N in SEED to zero. Returns a copy of SEED."
  (-let* ((seed-bytes (propcheck-seed-bytes seed))
          ((interval-start interval-end)
           (nth n (reverse (propcheck-seed-intervals seed))))
          (interval-bytes
           (-slice seed-bytes interval-start interval-end)))
    (unless (-all-p #'zerop interval-bytes)
      (dotimes (i (- interval-end interval-start))
        (setq seed
              (propcheck--set-byte seed (+ interval-start i) 0)))
      seed)))

(defun propcheck--shift-right-interval (seed n amount)
  "Shift right by AMOUNT in interval N in SEED.
Returns a copy of SEED.
Assumes AMOUNT is not greater than 8."
  (-let* ((seed-bytes (propcheck-seed-bytes seed))
          ((interval-start interval-end)
           (nth n (reverse (propcheck-seed-intervals seed))))
          (interval-bytes
           (-slice seed-bytes interval-start interval-end))
          (new-bytes nil)
          (carry 0))
    ;; Return nil if shifting right would give us the same seed.
    (unless (--all-p (zerop it) interval-bytes)

      (dolist (byte interval-bytes)
        ;; Given byte 0xN, we build 2 byte number 0xN0,
        ;; shift to produce 0xPQ, then P is our new byte and Q is
        ;; the carry.
        (let* ((padded-byte (lsh byte 8)))
          ;; Do the shift.
          (setq padded-byte (lsh padded-byte (- amount)))
          ;; Extract the new byte and new carry.
          (setq byte (+ (logand (lsh padded-byte -8) 255)
                        carry))
          (setq carry (logand padded-byte 255))
          (push byte new-bytes)))

      (-each-indexed (nreverse new-bytes)
        (lambda (i byte)
          (setq seed
                (propcheck--set-byte seed (+ interval-start i) byte))))
      seed)))

(defun propcheck--shrink-counterexample (fun seed shrinks)
  "Call FUN up to SHRINKS times, to find a smaller version of SEED that still
fails."
  (let* ((propcheck--shrinks-remaining shrinks))
    (->> seed
         (propcheck--shrink-interval-by fun #'propcheck--zero-interval)
         (propcheck--shrink-byte-by fun #'propcheck--zero-byte)
         (propcheck--shrink-swapping-intervals fun)
         (propcheck--shrink-interval-by fun (-rpartial #'propcheck--shift-right-interval 1))
         (propcheck--shrink-interval-by fun (-rpartial #'propcheck--subtract-interval 10))
         (propcheck--shrink-interval-by fun (-rpartial #'propcheck--subtract-interval 1)))))

(defun propcheck--find-small-counterexample (fun)
  (let ((seed
         (propcheck--find-counterexample fun)))
    (when seed
      (propcheck--shrink-counterexample fun seed propcheck-max-shrinks))))

(defmacro propcheck-deftest (name args &rest body)
  "Define NAME (a symbol) as a propcheck test.

BODY is repeatedly evaluated. It should use `propcheck-should'
for assertions.

If a counterexample is found, the test will fail and the smallest
inputs found will be reported."
  (declare (doc-string 3) (indent 2)
           (debug (&define :name test
                           name sexp [&optional stringp]
			   def-body)))
  (let ((fun-sym (gensym "propcheck-fun")))
    `(ert-deftest ,name ,args
       (let* ((,fun-sym (lambda ,args ,@body))
              (found-seed
               (propcheck--find-small-counterexample ,fun-sym)))
         (when found-seed
           (let ((propcheck--replay '(())))
             (propcheck--funcall-with-seed ,fun-sym found-seed)
             (ert-fail (list "Found counterexample" (car propcheck--replay)))))))))

(provide 'propcheck)
;;; propcheck.el ends here
