;; -*- lisp -*-

;; this file is part of stmx.
;; copyright (c) 2013 massimiliano ghilardi
;;
;; this library is free software: you can redistribute it and/or
;; modify it under the terms of the lisp lesser general public license
;; (http://opensource.franz.com/preamble.html), known as the llgpl.
;;
;; this library is distributed in the hope that it will be useful,
;; but without any warranty; without even the implied warranty
;; of merchantability or fitness for a particular purpose.
;; see the lisp lesser general public license for more details.


(in-package :stmx)


(enable-#?-syntax)

;;;; ** global clock - exact, atomic counter for transaction validation:
;;;; used to ensure transactional read consistency.


(defconstant +global-clock-delta+ 2
  "+global-clock+ is incremented by 2 each time: the lowest bit
is reserved as \"locked\" flag in TVARs versioning - used if TVAR-LOCK
feature is equal to :BIT.")


;;;; ** definitions common to more than one global-clock implementation

(deftype global-clock-gv156/version-type () 'atomic-counter-num)

(eval-always
  (defstruct (global-clock-gv156 (:include atomic-counter))
    (sw-commits 0 :type atomic-counter-slot-type)
    (commit-percentage 0 :type (integer -100 100))))

           
(declaim (type atomic-counter +global-clock-gv156+))
(define-constant-eval-once +global-clock-gv156+ (make-global-clock-gv156))

(eval-always
  (let1 stmx-package (find-package 'stmx)
    (defun %gvx-expand0-f (prefix suffix)
      (declare (type symbol prefix suffix))
      (intern (concatenate 'string
                           (symbol-name prefix)
                           "/"
                           (symbol-name suffix))
              stmx-package)))

  (defun %gv-expand0-f (name)
    (declare (type symbol name))
    (%gvx-expand0-f (stmx.lang::get-feature 'global-clock) name)))


(defmacro %gvx-expand (gvx name &rest args)
  (declare (type symbol gvx name))
  (let ((full-name (%gvx-expand0-f gvx name)))
    `(,full-name ,@args)))

(defmacro %gv-expand (name &rest args)
  (declare (type symbol name))
  (let ((full-name (%gv-expand0-f name)))
    `(,full-name ,@args)))


(defmacro gvx-add-missing (gvx)
  (let1 newline (make-string 1 :initial-element (code-char 10))
    `(progn
       ,@(loop for suffix in '(get-sw-commits incf-sw-commits decf-sw-commits
                               stat-committed stat-aborted)
            for name = (%gvx-expand0-f gvx suffix)
            unless (fboundp name)
            collect
              `(defmacro ,name ()
                 ,(concatenate 'string "This is " (symbol-name gvx) " implementation of "
                               (symbol-name name) "." newline "It does nothing and returns zero.")
                 '0))


       ;; if any macro GV<X>/{HW,SW}/{START-READ,START-WRITE,WRITE,AFTER-ABORT} is missing,
       ;; define it from the generic version without {HW,SW}/
       ,@(let ((macros nil))
           (loop for infix in '(hw sw) do
                (loop for (suffix . args) in '((start-read) (start-write write-version)
                                             (write write-version) (after-abort))
                   for infix+suffix = (%gvx-expand0-f infix suffix)
                   for name = (%gvx-expand0-f gvx infix+suffix)
                   for fallback-name = (%gvx-expand0-f gvx suffix)
                   unless (fboundp name)
                   do
                     (push 
                      `(defmacro ,name (,@args)
                         ,(concatenate 'string "This is " (symbol-name gvx)
                                       " implementation of GLOBAL-CLOCK/" (symbol-name infix+suffix)
                                       "." newline "Calls " (symbol-name fallback-name) ".")
                         (list ',fallback-name ,@args))
                      macros)))
           macros))))
      






;;;; ** This is global-clock version GV1

(deftype gv1/version-type () 'global-clock-gv156/version-type)

(define-symbol-macro +gv1+   +global-clock-gv156+)


(defmacro gv1/features ()
  "This is GV1 implementation of GLOBAL-CLOCK/FEATURES.

Return nil, i.e. not '(:suitable-for-hw-transactions) because
\(GV1/START-WRITE ...) increments the global clock, which causes conflicts
and aborts when multiple hardware transactions are running simultaneously."
  'nil)


(defmacro gv1/start-read ()
  "This is GV1 implementation of GLOBAL-CLOCK/START-READ.
Return the current +gv1+ value."
  `(get-atomic-counter +gv1+))


(defmacro gv1/valid-read? (tvar-version read-version)
  "This is GV1 implementation of GLOBAL-CLOCK/VALID-READ?
Return (<= tvar-version read-version)"
  `(<= (the gv1/version-type ,tvar-version) (the gv1/version-type ,read-version)))


(defmacro gv1/start-write (read-version)
  "This is GV1 implementation of GLOBAL-CLOCK/START-WRITE.
Atomically increment +gv1+ and return its new value."
  (declare (ignore read-version))

  `(incf-atomic-counter +gv1+ +global-clock-delta+))


(defmacro gv1/write (write-version)
  "This is GV1 implementation of GLOBAL-CLOCK/WRITE.
Return WRITE-VERSION."
  write-version)


(defmacro gv1/after-abort ()
  "This is GV1 implementation of GLOBAL-CLOCK/AFTER-ABORT.
Return the current +gv1+ value."
  `(gv1/start-read))


;; define stub macros (GV5/STAT-COMMITTED) (GV5/STAT-ABORTED)
;; (GV1/GET-SW-COMMITS) (GV1/INCF-SW-COMMITS) and (GV1/DECF-SW-COMMITS) 
(gvx-add-missing gv1)






;;;; ** This is global-clock version GV5

(deftype gv5/version-type () 'global-clock-gv156/version-type)

(define-symbol-macro +gv5+   +global-clock-gv156+)


(defmacro gv5/features ()
  "This is GV5 implementation of GLOBAL-CLOCK/FEATURES.

Return '(:SUITABLE-FOR-HW-TRANSACTIONS :SPURIOUS-FAILURES-IN-SINGLE-THREAD)
because the global clock is incremented only by GV5/AFTER-ABORT, which avoids
incrementing it in GV5/START-WRITE (it would cause hardware transactions
to conflict with each other and abort) but also causes a 50% abort rate (!) even
in a single, isolated thread reading and writing its own transactional memory."

 ''(:suitable-for-hw-transactions :spurious-failures-in-single-thread))


(defmacro gv5/start-read ()
  "This is GV5 implementation of GLOBAL-CLOCK/START-READ.
Return the current +gv5+ value."
  `(get-atomic-counter +gv5+))


(defmacro gv5/valid-read? (tvar-version read-version)
  "This is GV5 implementation of GLOBAL-CLOCK/VALID-READ?
Return (<= tvar-version read-version)"
  `(<= (the gv5/version-type ,tvar-version) (the gv5/version-type ,read-version)))


(defmacro gv5/start-write (read-version)
  "This is GV5 implementation of GLOBAL-CLOCK/START-WRITE.
Return (1+ +gv5+) without incrementing it."
  (declare (ignore read-version))

  `(get-atomic-counter-plus-delta +gv5+ +global-clock-delta+))


(defmacro gv5/hw/write (write-version)
  "This is GV5 implementation of GLOBAL-CLOCK/HW/WRITE.
Return WRITE-VERSION."
  write-version)


(defmacro gv5/sw/write (write-version)
  "This is GV5 implementation of GLOBAL-CLOCK/SW/WRITE.
Return (1+ +gv5+) without incrementing it."
  (declare (ignore write-version))

  `(get-atomic-counter-plus-delta +gv5+ +global-clock-delta+))


(defmacro gv5/after-abort ()
  "This is GV5 implementation of GLOBAL-CLOCK/AFTER-ABORT.
Increment +gv5+ and return its new value."
  `(incf-atomic-counter +gv5+ +global-clock-delta+))


(defmacro gv5/get-sw-commits ()
  "This is GV5 implementation of GLOBAL-CLOCK/GET-SW-COMMITS.
Return the number of software-only transaction commits currently running."
  `(get-atomic-place (global-clock-gv156-sw-commits +gv5+)))


(defmacro gv5/incf-sw-commits ()
  "This is GV5 implementation of GLOBAL-CLOCK/INCF-SW-COMMITS.
Increment by two the slot SW-COMMITS of +gv5+ and return its new value."
  `(incf-atomic-place (global-clock-gv156-sw-commits +gv5+)
                      2
                      #?+atomic-counter-mutex :place-mutex
                      #?+atomic-counter-mutex (atomic-counter-mutex +gv5+)))


(defmacro gv5/decf-sw-commits ()
  "This is GV5 implementation of GLOBAL-CLOCK/DECF-SW-COMMITS.
Decrement by two the slot SW-COMMITS of +gv5+ and return its new value."
  `(incf-atomic-place (global-clock-gv156-sw-commits +gv5+)
                      -2
                      #?+atomic-counter-mutex :place-mutex
                      #?+atomic-counter-mutex (atomic-counter-mutex +gv5+)))


;; define stub macros (GV5/STAT-COMMITTED) and (GV5/STAT-ABORTED)
(gvx-add-missing gv5)







;;;; ** This is global-clock version GV6

(deftype gv6/version-type () 'global-clock-gv156/version-type)

(define-symbol-macro +gv6+   +global-clock-gv156+)


(defmacro gv6/features ()
  "This is GV6 implementation of GLOBAL-CLOCK/FEATURES.

Return '(:SUITABLE-FOR-HW-TRANSACTIONS :SPURIOUS-FAILURES-IN-SINGLE-THREAD)
just like GV5 because the global clock is based on GV5: it is usually not
incremented by GV6/START-WRITE, to prevent hardware transactions from
conflicting with each other.
This can cause very high abort rates of software transactions, so
GV6 adaptively switches to GV1 algorithm in the following cases:
a) software-only commits are in progress
b) abort rate is very high
in order to try to reduce the abort rates."

  `(gv5/features))


(defmacro gv6/is-gv5-mode? ()
  "Return T if GV6 is currently in GV5 mode.
Return NIL if GV6 is currently in GV1 mode."
  `(zerop (gv5/get-sw-commits)))


(defmacro gv6/hw/start-read ()
  "This is GV6 implementation of GLOBAL-CLOCK/HW/START-READ.
Calls (GV5/HW/START-READ), since GV1 mode is not used for hardware transactions."
  `(gv5/hw/start-read))


(defmacro gv6/sw/start-read ()
  "This is GV6 implementation of GLOBAL-CLOCK/SW/START-READ.
Calls either (GV5/SW/START-READ) or (GV1/SW/START-READ), depending on the current mode."
  `(if (gv6/is-gv5-mode?)
       (gv5/sw/start-read)
       (gv1/sw/start-read)))


(defmacro gv6/valid-read? (tvar-version read-version)
  "This is GV6 implementation of GLOBAL-CLOCK/VALID-READ?
Return (<= tvar-version read-version)"
  `(<= (the gv6/version-type ,tvar-version) (the gv6/version-type ,read-version)))


(defmacro gv6/hw/start-write (read-version)
  "This is GV6 implementation of GLOBAL-CLOCK/HW/START-WRITE.
Calls (GV5/HW/START-WRITE), since GV1 mode is not used for hardware transactions."
  `(gv5/hw/start-write ,read-version))


(defmacro gv6/sw/start-write (read-version)
  "This is GV6 implementation of GLOBAL-CLOCK/SW/START-WRITE.
Calls either (GV5/START-WRITE) or (GV1/START-WRITE), depending on the current mode."
  `(if (gv6/is-gv5-mode?)
       (gv5/sw/start-write ,read-version)
       (gv1/sw/start-write ,read-version)))


(defmacro gv6/hw/write (write-version)
  "This is GV6 implementation of GLOBAL-CLOCK/SW/WRITE.
Calls (GV5/HW/START-WRITE), since GV1 mode is not used for hardware transactions."
  (declare (ignorable write-version))
  `(gv5/hw/write ,write-version))


(defmacro gv6/sw/write (write-version)
  "This is GV6 implementation of GLOBAL-CLOCK/HW/WRITE.
Calls either (GV5/SW/WRITE) or (GV1/WRITE), depending on the current mode."
  `(if (gv6/is-gv5-mode?)
       (gv5/sw/write ,write-version)
       (gv1/sw/write ,write-version)))


(defmacro gv6/hw/after-abort ()
  "This is GV6 implementation of GLOBAL-CLOCK/HW/AFTER-ABORT.
Calls (GV5/AFTER-ABORT), since GV1 mode is not used for hardware transactions."
  `(gv5/hw/after-abort))


(defmacro gv6/sw/after-abort ()
  "This is GV6 implementation of GLOBAL-CLOCK/SW/AFTER-ABORT.
Calls either (GV5/AFTER-ABORT) or (GV1/AFTER-ABORT), depending on the current mode."
  `(if (gv6/is-gv5-mode?)
       (gv5/sw/after-abort)
       (gv1/sw/after-abort)))


(defmacro gv6/get-sw-commits ()
  "This is GV6 implementation of GLOBAL-CLOCK/GET-SW-COMMITS.
Calls (GV5/GET-SW-COMMITS)."
  `(gv5/get-sw-commits))


(defmacro gv6/incf-sw-commits ()
  "This is GV6 implementation of GLOBAL-CLOCK/INCF-SW-COMMITS.
Calls (GV5/INCF-SW-COMMITS)."
  `(gv5/incf-sw-commits))


(defmacro gv6/decf-sw-commits ()
  "This is GV6 implementation of GLOBAL-CLOCK/DECF-SW-COMMITS.
Calls (GV5/DECF-SW-COMMITS)."
  `(gv5/decf-sw-commits))


(defmacro gv6/stat-committed ()
  "This is GV6 implementation of GLOBAL-CLOCK/STAT-COMMITTED.
It does nothing and returns zero."
  `0)

(defmacro gv6/stat-aborted ()
  "This is GV5 implementation of GLOBAL-CLOCK/STAT-COMMITTED.
It does nothing and returns zero."
  `0)



(gvx-add-missing gv6)












;;;; ** choose which global-clock implementation to use


(deftype global-clock/version-type () (%gv-expand0-f 'version-type))
(deftype              version-type () (%gv-expand0-f 'version-type))


(defmacro global-clock/features ()
  "Return the features of the GLOBAL-CLOCK algorithm, i.e. a list
containing zero or more of :SUITABLE-FOR-HW-TRANSACTIONS and
:SPURIOUS-FAILURES-IN-SINGLE-THREAD. The list of possible features
will be expanded as more GLOBAL-CLOCK algorithms are implemented."
  `(%gv-expand features))


(defmacro global-clock/hw/start-read ()
  "Return the value to use as hardware transaction \"read version\".

This function must be invoked once upon starting a hardware transaction for the first time.
In case the transaction just aborted and is being re-executed, invoke instead
\(GLOBAL-CLOCK/HW/AFTER-ABORT)."
  `(%gv-expand hw/start-read))


(defmacro global-clock/sw/start-read ()
  "Return the value to use as software transaction \"read version\".

This function must be invoked once upon starting a software transaction for the first time.
In case the transaction just aborted and is being re-executed, invoke instead
\(GLOBAL-CLOCK/SW/AFTER-ABORT)."
  `(%gv-expand sw/start-read))


(defmacro global-clock/valid-read? (tvar-version read-version)
  "Return T if TVAR-VERSION is compatible with transaction \"read version\".
If this function returns NIL, the transaction must be aborted.

During software transactions, this function must be invoked after every
TVAR read and before returning the TVAR value to the application code.
During hardware transactions, this function is not used."
  `(%gv-expand valid-read? ,tvar-version ,read-version))


(defmacro global-clock/hw/start-write (read-version)
  "Return the value to use as hardware transaction \"write version\",
given the transaction current READ-VERSION that was assigned at transaction start.

During hardware transactions - and also during hardware-based commits of software
transactions - this function must be called once before writing the first TVAR."
  `(%gv-expand hw/start-write ,read-version))


(defmacro global-clock/sw/start-write (read-version)
  "Return the value to use as softarw transaction \"write version\", given the
software transaction current READ-VERSION that was assigned at transaction start.

During software-only commits, this function must be called once before
committing the first TVAR write."
  `(%gv-expand sw/start-write ,read-version))


(defmacro global-clock/hw/write (write-version)
  "Return the value to use as TVAR \"write version\", given the hardware
transaction current WRITE-VERSION that was assigned by GLOBAL-CLOCK/HW/START-WRITE
before the transaction started writing to TVARs.

This function must be called for **each** TVAR being written during
hardware-assisted commit phase of software transactions
and during pure hardware transactions."
  `(%gv-expand hw/write ,write-version))


(defmacro global-clock/sw/write (write-version)
  "Return the value to use as TVAR \"write version\", given the software
transaction current WRITE-VERSION that was assigned by GLOBAL-CLOCK/SW/START-WRITE
before the transaction started writing to TVARs.

Fhis function must be called for **each** TVAR being written
during software-only commit phase of software transactions."
  `(%gv-expand sw/write ,write-version))


(defmacro global-clock/hw/after-abort ()
  "Return the value to use as new transaction \"read version\",

This function must be called after a hardware transaction failed/aborted
and before rerunning it."
  `(%gv-expand hw/after-abort))


(defmacro global-clock/sw/after-abort ()
  "Return the value to use as new transaction \"read version\",

This function must be called after a software transaction failed/aborted
and before rerunning it."
  `(%gv-expand sw/after-abort))


(defmacro global-clock/get-sw-commits ()
  "Return the number of software-only transaction commits currently running.

This function must be called at the beginning of each hardware transaction
in order to detect if a software-only transaction is started during
the hardware transaction, since their current implementations are incompatible."
  `(%gv-expand get-sw-commits))


(defmacro global-clock/incf-sw-commits ()
  "Increment by one the number of software-only transaction commits currently running.

This function must be called at the beginning of each software-only transaction commit
in order to abort any running hardware transaction, since their current implementations
are mutually incompatible."
  `(%gv-expand incf-sw-commits))


(defmacro global-clock/decf-sw-commits ()
  "Decrement by one the number of software-only transaction commits currently running.

This function must be called at the end of each software-only transaction commit
\(both if the commits succeeds and if it fails) in order to allow again hardware
transactions, since their current implementations are mutually incompatible."
  `(%gv-expand decf-sw-commits))


(defmacro global-clock/stat-committed ()
  `(%gv-expand stat-committed))

(defmacro global-clock/stat-aborted ()
  `(%gv-expand stat-aborted))
  





(eval-always
  (defun global-clock/publish-features ()
    "Publish (GLOBAL-CLOCK/FEATURES) to stmx.lang::*feature-list*
so they can be tested with #?+ and #?- reader macros."
    (loop for pair in (global-clock/features) do
         (let* ((feature (if (consp pair) (first pair) pair))
                (value   (if (consp pair) (rest  pair) t))
                (gv-feature (%gvx-expand0-f 'global-clock feature)))

           (stmx.lang::add-feature gv-feature value))))

  (global-clock/publish-features))
     