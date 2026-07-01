;;; minibuf-ext.el --- Enhanced minibuffer interaction  -*- lexical-binding: t -*-
;;
;; Reusable minibuffer helpers with no package-specific dependencies.
;; All public symbols use the `minibuf-ext-' prefix per Emacs convention.
;;
;; Provided:
;;   `minibuf-ext-with-live-prompt'    macro — live-refreshing prompt overlay
;;   `minibuf-ext-with-protection'     macro — timed keystroke suppression window
;;   `minibuf-ext-completing-read'     fn    — completing-read with eager key exit
;;   `minibuf-ext-prop-affixation'     fn    — affixation from text properties

(require 'cl-lib)

;;; ─── Live prompt ──────────────────────────────────────────────────────────────

(defmacro minibuf-ext-with-live-prompt (prompt-fn interval &rest body)
  "Execute BODY with the minibuffer prompt refreshed every INTERVAL seconds.

PROMPT-FN is a zero-argument function returning the current prompt string.
An overlay covers the static prompt region; its `display' property is
updated by a repeating timer so the user sees live text without needing to
press anything.

Both the overlay and timer are cleaned up when the minibuffer exits, whether
by completion, `exit-minibuffer', or `abort-recursive-edit'.

INTERVAL is evaluated once to avoid double-evaluation of a side-effectful
or expensive expression.

Composes naturally with `minibuf-ext-completing-read' by nesting:

  (minibuf-ext-with-live-prompt prompt-fn 1
    (minibuf-ext-completing-read prompt candidates ...))"
  `(minibuffer-with-setup-hook
       (lambda ()
         (let* ((--interval ,interval)
                (--ov      (make-overlay (point-min) (minibuffer-prompt-end)))
                (--refresh (lambda ()
                             (when (overlay-buffer --ov)
                               (overlay-put --ov 'display (funcall ,prompt-fn)))))
                (--timer   (run-at-time --interval --interval --refresh)))
           ;; Paint immediately before the first tick fires.
           (funcall --refresh)
           (add-hook 'minibuffer-exit-hook
                     (lambda ()
                       (cancel-timer --timer)
                       (delete-overlay --ov))
                     nil 'local)))
     ,@body))

;;; ─── Keystroke suppression window ────────────────────────────────────────────

(cl-defmacro minibuf-ext-with-protection ((&key (seconds 2)
                                                (max-seconds 5)
                                                (min-idle 60))
                                          &rest body)
  "Execute BODY with keystroke suppression for an initial protection window.

Options are supplied as a keyword list in the first argument:

  :seconds     Inactivity seconds before the window expires.  nil disables
               protection entirely.  Default: 2.
  :max-seconds Hard cap on total protection regardless of resets.  Default: 5.
  :min-idle    Idle seconds at which protection is bypassed when the frame
               has focus — the user has been away long enough to read before
               typing.  nil disables the bypass.  Default: 60.

When active, a catch-all keymap is installed via `overriding-local-map' in
the minibuffer.  Each suppressed keystroke rings the bell, briefly applies
`warning' face to the minibuffer prompt, and resets the inactivity timer.
Once MAX-SECONDS have elapsed from the first keystroke, the next keystroke
releases protection immediately rather than resetting.

C-g is never suppressed; it always calls `abort-recursive-edit'.

Once the window expires `overriding-local-map' is cleared and normal key
handling resumes.  If BODY involves a loop that reopens the minibuffer
(e.g. a task picker with a toggle key), protection is not reinstalled on
subsequent iterations.

Composes with `minibuf-ext-with-live-prompt':

  (minibuf-ext-with-live-prompt prompt-fn 1
    (minibuf-ext-with-protection (:seconds 2)
      (completing-read ...)))"
  (let ((g-seconds (make-symbol "seconds"))
        (g-max     (make-symbol "max-seconds"))
        (g-minidle (make-symbol "min-idle"))
        (g-start   (make-symbol "start"))
        (g-timer   (make-symbol "timer")))
    `(let* ((,g-seconds ,seconds)
            (,g-max     ,max-seconds)
            (,g-minidle ,min-idle)
            (,g-start   (float-time))
            (,g-timer   nil))
       (minibuffer-with-setup-hook
           (lambda ()
             (when (and ,g-seconds
                        (not (and ,g-minidle
                                  (when-let* ((idle (current-idle-time)))
                                    (>= (float-time idle) ,g-minidle))
                                  (fboundp 'frame-focus-state)
                                  (frame-focus-state))))
               (let* ((buf     (current-buffer))
                      (flash   (lambda ()
                                 (ding t)
                                 (let ((ov (make-overlay (point-min)
                                                         (minibuffer-prompt-end))))
                                   (overlay-put ov 'face 'warning)
                                   (run-at-time 0.15 nil #'delete-overlay ov))))
                      (release (lambda ()
                                 (when (buffer-live-p buf)
                                   (with-current-buffer buf
                                     (setq overriding-local-map nil)))))
                      (pmap    (make-sparse-keymap)))
                 (define-key pmap [t]
                             (lambda ()
                               (interactive)
                               (funcall flash)
                               (when (timerp ,g-timer) (cancel-timer ,g-timer))
                               (setq ,g-timer
                                     (run-at-time
                                      (if (< (float-time) (+ ,g-start ,g-max))
                                          ,g-seconds
                                        0)
                                      nil release))))
                 (define-key pmap (kbd "C-g") #'abort-recursive-edit)
                 (setq-local overriding-local-map pmap)
                 (setq ,g-timer (run-at-time ,g-seconds nil release)))))
         ,@body))))



(defun minibuf-ext-completing-read (prompt collection &rest args)
  "Like `completing-read' but candidates with a `key' text property exit
immediately when the minibuffer content exactly equals that key.

The `key' property should be a short string on each candidate:

  (propertize \"continue\" \\='key \"c\")

When the user types a string that exactly matches a `key' value, that
candidate is selected and `exit-minibuffer' is called — no RET needed.
For alist collections the `key' is read from the car (the display string).

Checked via `post-command-hook' at depth -1 so single-character keys are
intercepted before completion frameworks (e.g. vertico, ivy) act on input.

PROMPT and COLLECTION are as for `completing-read'.
Remaining ARGS are forwarded to `completing-read' unchanged."
  (let ((cands (cond ((listp collection)     collection)
                     ((functionp collection) (funcall collection "" nil t))
                     (t                      nil))))
    (minibuffer-with-setup-hook
        (lambda ()
          (add-hook 'post-command-hook
                    (lambda ()
                      (let ((input (minibuffer-contents-no-properties)))
                        (catch 'matched
                          (dolist (cand cands)
                            (let ((cand-str (if (consp cand) (car cand) cand)))
                              (when (and (not (string-empty-p input))
                                         (equal input
                                                (get-text-property 0 'key cand-str)))
                                (delete-minibuffer-contents)
                                (insert cand-str)
                                (exit-minibuffer)
                                (throw 'matched nil)))))))
                    -1 'local))
      (apply #'completing-read prompt collection args))))

;;; ─── Text-property affixation ─────────────────────────────────────────────────

(defun minibuf-ext-prop (str key annotation)
  "Return a string with a KEY prefix and ANNOTATION suffix."
  (propertize
   str
   'prefix (if (string-empty-p key)
               "    "
             (propertize (format "[%s] " key) 'face 'minibuffer-prompt))
   'suffix (when annotation
             (propertize (format " [%s]" annotation) 'face 'completions-annotations))
   'key (unless (or (not key) (string-empty-p key)) key)))

(defun minibuf-ext-prop-affixation (completions)
  "Affixation function that reads `prefix' and `suffix' text properties.

Intended as the value of `:affixation-function' in
`completion-extra-properties'.  Each candidate in COMPLETIONS is expected
to carry optional text properties:

  `prefix'  string prepended before the candidate (e.g. a key hint \"[1] \")
  `suffix'  string appended after the candidate   (e.g. a category label)

Both properties are optional; absent ones produce empty strings.  The
suffix is propertized with `completions-annotations' face so it appears
visually distinct from the candidate text.

Example — building a candidate with both properties:

  (propertize \"Fix the bug\"
              \\='prefix (propertize \"[1] \" \\='face \\='minibuffer-prompt)
              \\='suffix \"my-project\")"
  (mapcar (lambda (c)
            (list c
                  (or (get-text-property 0 'prefix c) "")
                  (or (get-text-property 0 'suffix c) "")))
          completions))

(defmacro minibuf-ext-when-inactive (&rest body)
  "Execute BODY once no minibuffer is active.
If a minibuffer is active, polls every 0.1 seconds using a single
repeating timer that cancels itself when the depth reaches zero."
  `(if (= (minibuffer-depth) 0)
       (progn ,@body)
     (cl-labels ((poll (timer)
                   (when (= (minibuffer-depth) 0)
                     (cancel-timer timer)
                     ,@body)))
       (let ((timer nil))
         (setq timer (run-at-time 0.1 0.1
                                  (lambda () (poll timer))))))))

(provide 'minibuf-ext)
;;; minibuf-ext.el ends here
