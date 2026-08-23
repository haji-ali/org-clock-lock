;;; org-clock-lock.el --- Mandatory task focus for org-mode  -*- lexical-binding: t -*-
;;
;; Requires minibuf-ext.el.
;; Enable with M-x org-clock-lock-mode.
;; Customise the task picker by overriding or advising `org-clock-lock-read-task'.

(require 'org)
(require 'org-clock)
(require 'org-agenda)
(require 'cl-lib)
(require 'seq)
(require 'minibuf-ext)

;;; Customization

(defgroup org-clock-lock nil
  "Block Emacs until an org task is chosen."
  :group 'org :prefix "org-clock-lock-")

(defcustom cl:default-duration 25
  "Default session length in minutes."
  :type 'natnum)

(defcustom cl:default-break 5
  "Default duration for break tasks (headings with a BREAK org property)."
  :type 'natnum)

(defcustom cl:session-limits '(2 . 120)
  "Cons (MIN . MAX) of allowed session lengths in minutes."
  :type '(cons natnum natnum))

(defcustom cl:session-warn-seconds 120
  "Seconds before session end at which the header turns urgent.
When the remaining time drops to or below this threshold the header
symbol changes to ⚠⏱.  Has no effect on break sessions."
  :type 'natnum)

(defcustom cl:idle-warn-seconds 300
  "Idle detection threshold.
nil: disabled.
integer: seconds of silence before warning (no grace period)."
  :type '(choice (const  :tag "Disabled" nil)
                 (natnum :tag "Warn seconds (no grace)")))

(defcustom cl:show-header t
  "Non-nil to show a header-line countdown during active sessions."
  :type 'boolean)

(defcustom cl:log-min-gap-minutes 10
  "Minimum gap between sessions in minutes before a gap line is shown in the log."
  :type 'natnum)

(defcustom cl:prompt-protect-seconds 1
  "Keystroke suppression window in seconds when the interrupt prompt appears.
Each keystroke during this window flashes the prompt and resets the timer.
nil disables protection entirely."
  :type '(choice (const  :tag "Disabled" nil)
                 (natnum :tag "Seconds")))

(defcustom cl:prompt-protect-max-seconds 3
  "Hard cap on prompt protection time regardless of keystroke resets."
  :type 'natnum)

(defcustom cl:prompt-protect-min-idle 60
  "Idle seconds at which prompt protection is bypassed when the frame has focus.
nil disables the bypass."
  :type '(choice (const  :tag "Never bypass" nil)
                 (natnum :tag "Idle seconds")))

(defcustom cl:sleep-detect-seconds 10
  "Gap in seconds between tick firings that signals a sleep/wake cycle.
The tick timer fires every second; a gap larger than this threshold can
only be explained by the system having been suspended.  10 s is
conservative enough to survive heavy GC pauses on slow machines while
still catching even the briefest sleep."
  :type 'natnum)

(defcustom cl:lock-layout-function #'delete-other-windows
  "Function that arranges a frame's windows for the lock screen.
The function should create whatever window layout it wants. The caller
will switch the selected window to the lock buffer.

To reserve part of the frame for note-taking while locked, for example:

  (setq org-clock-lock-lock-layout-function
        (lambda ()
          (delete-other-windows)
          (split-window-right)
          (switch-to-buffer \"*scratch*\")
          (other-window 1)))"
  :type 'function)

(defcustom cl:clock-out-on-sleep nil
  "Non-nil to clock out automatically when a sleep/wake cycle is detected.
The clock entry is ended at the last known awake time (i.e. the tick
just before sleep) rather than at wake time, so no sleep time is
credited to the task.  On wake the lock screen is shown as normal.

When nil (default) the interrupt prompt is shown instead, giving the
same retroactive clock-out options as for keyboard idle."
  :type 'boolean)


;;; Faces

(defface cl:spent-face
  '((t :inherit org-time-stamp :underline nil))
  "Face for actual spent time values in the org-clock-lock log."
  :group 'org-clock-lock)

(defface cl:planned-face
  '((t :inherit org-time-stamp-inactive :underline nil))
  "Face for planned (target) time values in the org-clock-lock log."
  :group 'org-clock-lock)

;;; Keymaps ──

(defvar cl::agenda-map
  (let ((m (make-sparse-keymap)))
    (define-key m [remap save-buffer] #'ignore)
    (define-key m (kbd "t")   #'cl:new-session)
    (define-key m (kbd "TAB") #'cl::log-toggle-day)
    (define-key m (kbd "g")   #'cl::agenda-redo)
    (define-key m (kbd "r")   #'cl::agenda-redo)
    m)
  "Keymap layered over `org-agenda-mode-map' in the lock screen buffer.
Shadows the agenda's own \"t\"/\"TAB\" bindings, since in this buffer
they pick a task and toggle the day log instead.")

(define-minor-mode cl::agenda-lock-minor-mode
  "Provide org-clock-lock bindings in the agenda-based lock buffer.
Purely internal: turned on by `org-clock-lock--agenda-finalize' every
time the lock buffer is (re)rendered, since `org-agenda-mode' resets
buffer-local minor modes on each redo."
  :keymap cl::agenda-map)

(defvar cl:mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c f d") #'org-clock-out)
    (define-key m (kbd "C-c f t") #'cl:switch-task)
    m)
  "Keymap for `cl:mode' (active while unlocked).")

(defvar cl:locked-map
  (let ((map (make-sparse-keymap)))
    (dolist (cmd '(execute-extended-command
                   eval-expression
                   switch-to-buffer kill-current-buffer kill-buffer
                   switch-to-buffer-other-window
                   switch-to-buffer-other-frame
                   find-file find-file-other-window find-file-other-frame
                   find-alternate-file
                   split-window-below split-window-right
                   delete-window delete-other-windows
                   eval-last-sexp eval-buffer eval-region
                   org-agenda-quit org-agenda-Quit org-agenda-exit
                   org-agenda-kill-all-agenda-buffers))
      (define-key map (vector 'remap cmd) #'cl:blocked))
    (dolist (key '("C-h" "C-x 5" "C-x 4" "C-x t" "C-c p"))
      (define-key map (kbd key) #'cl:blocked))
    (define-key map [tab-bar mouse-1]      #'cl:blocked)
    (define-key map [tab-bar mouse-2]      #'cl:blocked)
    (define-key map [tab-bar down-mouse-1] #'cl:blocked)
    map)
  "Keymap active in locked mode.")

;;; Session struct

(cl-defstruct (cl::session
               (:constructor cl::make-session))
  "Active session state."
  marker title break-p planned-minutes timer-session timer-idle)

;;; Internal state

(defvar cl::locked-p nil
  "Nil when unlocked; `cl:locked-map' when locked.
Activation variable for `emulation-mode-map-alists'.")

(defvar cl::session nil
  "The active `cl::session' struct, or nil when locked.")

(defvar cl::tick-timer nil
  "Recurring 1-second timer that refreshes the header line.")

(defvar cl::saved-frame-wconfs nil
  "Alist of (FRAME . WCONF) saved before the lock screen was raised.")

(defvar cl::last-tick-time nil
  "Float-time of the most recent `cl::tick' call, or nil before the first tick.
Nil is reset by `cl::cancel-timers' so the first tick of a new session
does not false-positive against a stale pre-sleep timestamp.")


(defvar cl:session-start-hook nil
  "Hook run when a session starts (lock screen dismissed, clock running).
Called at the end of `cl::begin-session' with `cl::session' fully populated.")

(defvar cl:session-end-hook nil
  "Hook run when a session ends (lock screen shown, before teardown).
Called in `cl::end-session' while `cl::session' is still set, so callbacks
can read session data such as title, marker, and planned minutes.")

(defconst cl::buf " *org-clock-lock*"
  "Name of the full-frame lock buffer.")

(defvar cl::log-entries nil
  "List of completed session plists, oldest first.
Each entry is (:title :break-p :start :end :spent :planned :marker :date).
This is the log's sole source of truth: the lock buffer is an
`org-agenda' buffer, fully rebuilt on every redo/relock, so nothing
about the log can live in buffer text between renders.")

(defvar cl::log-collapsed-days nil
  "List of date strings (YYYY-MM-DD) whose log block renders collapsed.")



;;; Session lifecycle

(defun cl::cancel-timers ()
  "Cancel session timers, stop the tick timer, and clear the session."
  (when cl::session
    (let ((ts (cl::session-timer-session cl::session))
          (ti (cl::session-timer-idle    cl::session)))
      (when (timerp ts) (cancel-timer ts))
      (when (timerp ti) (cancel-timer ti))))
  (when (timerp cl::tick-timer)
    (cancel-timer cl::tick-timer))
  (setq cl::tick-timer    nil
        cl::last-tick-time nil))


;;; Session warn accessor

(defsubst cl::secs-remaining ()
  "Seconds left in the current session (negative when expired)."
  (round (- (float-time
             (timer--time (cl::session-timer-session cl::session)))
            (float-time))))

;;; Utility

(defsubst cl::fmt-hh-mm (minutes)
  "Format MINUTES as HH:MM."
  (format "%d:%02d" (/ minutes 60) (% minutes 60)))

(defun cl::apply-lock-layout (buf)
  "Run `cl:lock-layout-function' in the selected frame and switch to BUF."
  (with-demoted-errors
      (funcall cl:lock-layout-function))
  (switch-to-buffer buf t))

(defun cl::lockable-frame-p (frame)
  "Non-nil if FRAME is a normal frame that should show the lock screen.
Excludes invisible/iconified frames and child frames (e.g. those used
by posframe-style popups), since those aren't independent frames the
user interacts with directly."
  (and (eq (frame-visible-p frame) t)
       (not (frame-parameter frame 'parent-frame))))

(defun cl::enforce-lock-screen ()
  "Ensure every live, lockable frame's window layout includes the lock buffer.
Frames not yet in `cl::saved-frame-wconfs' have their window
configuration saved first.  See `cl::lockable-frame-p' for which frames
are considered."
  (when cl::locked-p
    (let ((buf (cl::ensure-lock-buffer)))
      (dolist (frame (frame-list))
        (when (and (frame-live-p frame) (cl::lockable-frame-p frame))
          (unless (assq frame cl::saved-frame-wconfs)
            (push (cons frame (with-selected-frame frame
                                (current-window-configuration)))
                  cl::saved-frame-wconfs))
          (unless (get-buffer-window buf frame)
            (with-selected-frame frame
              (cl::apply-lock-layout buf))))))))

(defun cl:blocked ()
  "Feedback for blocked commands on the lock screen."
  (interactive)
  (cl::enforce-lock-screen)
  (message
   (substitute-command-keys
    "LOCKED — \\[org-clock-lock-new-session] to pick a task.")))

;;; Org / task helpers

(defsubst cl::heading-at (marker)
  "Return plain heading text at MARKER."
  (org-with-point-at marker (org-get-heading t t t t)))

(defsubst cl::marker-is-break-p (marker)
  "Non-nil if the heading at MARKER has a BREAK property."
  (when (and marker (marker-buffer marker))
    (org-with-point-at marker (org-entry-get (point) "BREAK"))))

(defun cl::today-clocked-minutes (marker)
  "Return minutes clocked today on the task at MARKER, or nil if none or 0."
  (when (and marker (marker-buffer marker))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (save-restriction
          (org-narrow-to-subtree)
          (let ((range (org-clock-special-range 'today)))
            (org-clock-sum (car range) (cadr range)
                           nil :org-clock-minutes-today)
            (when (> org-clock-file-total-minutes 0)
              org-clock-file-total-minutes)))))))

(defun cl::effort-minutes (marker)
  "Return the EFFORT property at MARKER as minutes, or nil."
  (when (and marker (marker-buffer marker))
    (org-with-point-at marker
      (when-let* ((effort (org-entry-get (point) "EFFORT")))
        (condition-case nil
            (round (org-duration-to-minutes effort))
          (error nil))))))

(defcustom cl:capture-template-key nil
  "Key of the `org-capture-templates' entry used when creating a new task.
When non-nil, `cl::capture-org-task' fills the template with the task title
and finalises it immediately without any further user interaction.  The
template should be an `entry' type.  Use %i in the template string to
place the title (it is bound to the title via `org-capture-initial'); any
%^{Prompt} sequences are also replaced with the title so that no prompts
fire.  The `:immediate-finish' property is added automatically.
When nil, a plain TODO is appended to `org-default-notes-file'."
  :type '(choice (const  :tag "Built-in fallback" nil)
                 (string :tag "Capture template key")))

(defun cl::capture-org-task (title &optional properties)
  "Create an org task with TITLE and return a marker pointing at it.
If `cl:capture-template-key' is set, run that org-capture template with
TITLE substituted for all interactive placeholders, finalising immediately
without user interaction.
If `cl:capture-template-key' is nil, append a plain TODO to
`org-default-notes-file'.
PROPERTIES, an alist of (NAME . VALUE), is set on the resulting heading
in either case."
  (let ((marker
         (if cl:capture-template-key
             (let* ((entry   (cl::find-capture-template cl:capture-template-key))
                    ;; Substitute title into template string and force immediate-finish
                    (filled  (cl::capture-fill-template entry title))
                    (org-capture-templates (list filled))
                    ;; %i expands to org-capture-initial
                    (org-capture-initial title))
               (org-capture nil cl:capture-template-key)
               ;; org-capture with :immediate-finish stores the marker here
               (when (markerp org-capture-last-stored-marker)
                 (copy-marker org-capture-last-stored-marker)))
           ;; Built-in fallback: append to notes file
           (let ((file (or org-default-notes-file (expand-file-name "notes.org" "~"))))
             (unless (file-exists-p file)
               (make-directory (file-name-directory file) t)
               (write-region "" nil file))
             (with-current-buffer (find-file-noselect file)
               (goto-char (point-max))
               (unless (bolp) (insert "\n"))
               (let ((pos (point-marker)))
                 (insert "* TODO " title "\n")
                 (save-buffer)
                 pos))))))
    (when (and marker properties)
      (org-with-point-at marker
        (dolist (kv properties)
          (org-entry-put (point) (car kv) (cdr kv)))))
    marker))

(defun cl::capture-fill-template (entry title)
  "Return a copy of capture ENTRY ready for non-interactive use with TITLE.
Replaces all %^{Prompt} sequences in the template string with TITLE (so no
prompts fire) and ensures `:immediate-finish t' is set in the options plist."
  (let* ((copy  (copy-sequence entry))
         (tmpl  (nth 4 copy))
         (filled (when (stringp tmpl)
                   (replace-regexp-in-string
                    "%\\^{[^}]*}" (regexp-quote title) tmpl))))
    (when filled (setf (nth 4 copy) filled))
    ;; Add :immediate-finish to the options plist (starts at index 5)
    (unless (plist-get (nthcdr 5 copy) :immediate-finish)
      (plist-put (nthcdr 5 copy) :immediate-finish t))
    copy))

(defun cl::find-capture-template (key)
  "Return the org-capture template entry for KEY, or nil."
  (cl-find key org-capture-templates :key #'car :test #'equal))

(defun cl::read-minutes (prompt default &optional base)
  "Read a session duration in minutes, returning a positive integer.
PROMPT is displayed before the bracketed default value.
DEFAULT is returned when the user enters blank input or 0.
Values above `cl:session-limits' max are rejected with a message.
Values below `cl:session-limits' min trigger a y-or-n-p confirmation.
Signals `quit' if the user presses C-g.

When BASE is a non-nil, it is used as the base minutes:
  \"N\"  — Returned as is.
  \"+N\" — N minutes from now, so that BASE is added.
The prompt is extended with \", +N from now\" to advertise the syntax."
  (let (result)
    (while (null result)
      (let* ((raw    (read-string
                      (if base
                          (format "%s [default: %d min, >%d, +N from now]: "
                                  prompt default base)
                        (format "%s [default: %d min]: " prompt default))
                      nil nil (number-to-string default)))
             (rel-p  (and base (string-prefix-p "+" raw)))
             (n      (if (string-empty-p raw)
                         default
                       (string-to-number (if rel-p (substring raw 1) raw))))
             (val (if rel-p (+ base n) n)))
        (unless (and base
                     (<= val base)
                     (> n 0) ;; If the input is exactly 0, we know to clock out
                     (not (y-or-n-p
                           (format "%d minutes already passed — clock out? "
                                   val))))
          (cond
           ((> val (cdr cl:session-limits))
            (message "%d min exceeds maximum of %d — try again."
                     val (cdr cl:session-limits))
            (sit-for 1.5))
           ((and (> val 0) (< val (car cl:session-limits)))
            (when (y-or-n-p (format "%d min is very short — use anyway? " val))
              (setq result val)))
           (t (setq result val))))))
    result))

;;; Task picker

(defun cl:read-task (&optional prompt break-only expand-state break-state)
  "Interactively select an org task; return its marker or nil on cancel.
Candidates: current context, recent clock history, today's agenda.

PROMPT is an optional string used as the minibuffer prompt prefix in place
of the default \"Task\" or \"Break\" label.
BREAK-ONLY, when non-nil, opens the picker with the break filter active so
only headings carrying a BREAK property are shown.
EXPAND-STATE, when a one-element list, is updated in place with the current
expand state (t = full agenda shown) so a live prompt overlay can reflect it.
BREAK-STATE, when a one-element list, has its car set to the break-filter
state (t = break filter active) in effect when a result is committed, so
callers can tell whether a freshly typed title (a new task) was entered
while browsing breaks.

Key bindings inside the picker:
  <      toggle full candidate list
  C-c b  toggle break-only filter (headings with a BREAK property)"
  (let ((expand-all break-only)
        (breaks break-only)
        sub-cands)
    (catch 'done
      (while t
        (setq sub-cands (cl::candidate-markers breaks))
        (when expand-state (setcar expand-state expand-all))
        (let* ((repeat nil)
               (markers (if expand-all
                            (nreverse
                             (cl::all-task-markers t (nreverse
                                                      (seq-copy sub-cands))
                                                   breaks))
                          sub-cands))
               (cands   (cl::format-candidates markers t))
               (fprompt (concat
                         (or prompt (if breaks "Break" "Task"))
                         (cond ((and expand-all breaks) " (all breaks, C-c b all): ")
                               (expand-all              " (all, C-c b breaks): ")
                               (breaks                  " [< all, C-c b all]: ")
                               (t                       " [< all, C-c b breaks]: "))))
               (result
                (minibuffer-with-setup-hook
                    (lambda ()
                      (define-key (current-local-map) (kbd "<")
                                  (lambda ()
                                    (interactive)
                                    (setq expand-all (not expand-all) repeat t)
                                    (abort-recursive-edit)))
                      (define-key (current-local-map) (kbd "C-c b")
                                  (lambda ()
                                    (interactive)
                                    (setq breaks (not breaks) expand-all breaks repeat t)
                                    (abort-recursive-edit))))
                  (condition-case nil
                      (let ((completion-extra-properties
                             '(:affixation-function minibuf-ext-prop-affixation
                               :display-sort-function identity)))
                        (minibuf-ext-completing-read
                         fprompt cands nil nil nil nil (caar cands)))
                    (quit (unless repeat (signal 'quit nil)))))))
          (when result
            (when break-state (setcar break-state breaks))
            (throw 'done (or (cdr (assoc result cands #'string=)) result))))))))

(defun cl::all-task-markers (match &optional markers break-only)
  "Return markers for ALL not-done agenda tasks (no recency filter).
Existing MARKERS are preserved; new ones appended."
  ;; (setq markers (nreverse markers))
  (org-map-entries
   (lambda ()
     (let ((m (point-marker)))
       (unless (member m markers) (push m markers))))
   match 'agenda
   (lambda ()
     (or
      (and (progn
             (org-back-to-heading t)
             (org-agenda-skip-if-todo '(todo done) (org-entry-end-position)))
           (save-excursion
             (org-end-of-subtree t)
             (point)))
      (and break-only
           (when (not (org-entry-get (point) "BREAK"))
             (org-entry-end-position))))))
  markers)

(defun cl::candidate-markers (&optional break-only)
  "Collect candidate markers: context, clock history, today's agenda."
  (let (markers)
    (cl-flet ((add (m)
                (when (and m (marker-buffer m) (not (member m markers)))
                  (push m markers))))
      (when (derived-mode-p 'org-agenda-mode)
        (add (org-get-at-bol 'org-marker)))
      (when (derived-mode-p 'org-mode)
        (add (save-excursion (org-back-to-heading t) (point-marker))))
      (dolist (m org-clock-history) (add m))
      (setq markers
            (cl::all-task-markers
             "SCHEDULED<=\"<today>\"|DEADLINE<=\"<today>\""
             markers)))
    (let ((result (nreverse markers)))
      (if break-only
          (cl-remove-if-not #'cl::marker-is-break-p result)
        result))))

(defun cl::format-candidates (markers with-prefix)
  "Return alist of (PROPERTIZED-TITLE . MARKER) for MARKERS.
Suffix shows category, today's clocked time (HH:MM), and effort."
  (let ((i 0))
    (delq nil
          (mapcar
           (lambda (m)
             (when (marker-buffer m)
               (cl-incf i)
               (let* ((key-str (when with-prefix
                                 (if (< i 10)
                                     (string (+ i ?0))
                                   "")))
                      (heading (org-with-point-at m (org-get-heading t t t t)))
                      (cat     (org-with-point-at m (org-get-category)))
                      (effort  (cl::effort-minutes m))
                      (today   (cl::today-clocked-minutes m))
                      (time-str
                       (cond
                        ((and today effort)
                         (format "%s/%s" (cl::fmt-hh-mm today)
                                 (cl::fmt-hh-mm effort)))
                        (today  (format "%s today" (cl::fmt-hh-mm today)))
                        (effort (format "est. %s" (cl::fmt-hh-mm effort)))
                        (t nil)))
                      (suffix  (if time-str (format "%s -- %s" cat time-str) cat))
                      (display
                       (minibuf-ext-prop heading key-str suffix)))
                 (cons display m))))
           markers))))

;;; Interactive commands ─

(defun cl:new-session (&optional prompt switch)
  "Select and start a task session.
PROMPT is an optional string used as the task picker prompt prefix.
SWITCH, when non-nil, clocks out of the current task only after a
successful selection; C-g leaves the current clock running.
C-g at the duration prompt returns to the task picker."
  (interactive)
  (if (and (not switch) (org-clocking-p))
      (unless (cl::adopt-running-clock)
        (user-error "Can't clock another"))
    (let (done)
      (while (not done)
        (let ((break-state (list nil)))
          (when-let*
              ((marker (cl:read-task prompt nil nil break-state))
               (confirmed (or (markerp marker)
                              (ignore-error quit
                                (y-or-n-p "Create new task?")))))
            (let* ((title        (if (markerp marker)
                                     (cl::heading-at marker)
                                   marker))
                   (break-p      (if (markerp marker)
                                     (cl::marker-is-break-p marker)
                                   (car break-state)))
                   (default-mins (or (and (markerp marker)
                                          (cl::effort-minutes marker))
                                     (if break-p cl:default-break
                                       cl:default-duration)))
                   (mins         (ignore-error quit
                                   (cl::read-minutes
                                    (format "Work on \"%s\" for" title)
                                    default-mins))))
              (when mins
                (setq marker (if (markerp marker)
                                 (copy-marker marker)
                               (cl::capture-org-task
                                title (and break-p '(("BREAK" . "t"))))))
                (when switch
                  (cl::org-clock-out nil t))
                (cl::begin-session title (copy-marker marker) mins)
                (setq done t)))))))))

(defun cl:switch-task ()
  "Select a new task then clock out of current and clock in.
C-g at any prompt leaves the current clock running."
  (interactive)
  (cl:new-session nil t))

;;; Timers
(defun cl::tick ()
  "1-second heartbeat: refresh the header and detect sleep/wake cycles.
Compares the current wall-clock time to `cl::last-tick-time'.  A gap
larger than `cl:sleep-detect-seconds' can only result from the system
having been suspended between ticks, so `cl:on-sleep' is called with
the last-known awake timestamp as the sleep-start time.

`cl::last-tick-time' is nil on the first tick of each session (reset by
`cl::cancel-timers') so no false-positive fires at session start."
  (let ((now (float-time)))
    (if (and cl::last-tick-time
             cl::session
             (not cl::locked-p)
             (not (cl::session-break-p cl::session))
             (> (- now cl::last-tick-time) cl:sleep-detect-seconds))
        (cl:on-sleep (seconds-to-time cl::last-tick-time))
      (setq cl::last-tick-time now)))
  (force-mode-line-update t))

(defun cl:on-sleep (sleep-start)
  "Handle a sleep/wake cycle with SLEEP-START as the last-awake boundary time.
Can be called from a user-supplied system-sleep hook for a precise boundary;
the tick-timer time-jump detector calls this automatically as a fallback.

SLEEP-START is a time value representing the moment the system went to sleep.
Pass `(current-time)' from a pre-sleep hook; the tick path supplies the
timestamp of the last tick before the gap.

If `cl:clock-out-on-sleep' is non-nil the clock is ended immediately at
SLEEP-START.  Otherwise `cl::interrupt-prompt' is called."
  (setq cl::last-tick-time (float-time sleep-start))
  (when (and cl::session (not cl::locked-p)
             (not (cl::session-break-p cl::session)))
    (if cl:clock-out-on-sleep
        (cl::org-clock-out nil t sleep-start)
      (cl::interrupt-prompt))))

(defun cl::interrupt-boundary ()
  "Return the earliest relevant interrupt boundary as (KIND . TIME).
Considers sleep (`cl::last-tick-time'), idle (`current-idle-time'), and
session expiry (`timer--time'), and returns the earliest applicable one.
Resets `cl::last-tick-time' to now before returning."
  (let* ((sleep-float cl::last-tick-time)
         (_           (setq cl::last-tick-time (float-time)))
         (now-time    (current-time))
         (now-float   (float-time now-time))
         (sleep-b     (when (and sleep-float
                                 (> (- now-float sleep-float)
                                    cl:sleep-detect-seconds))
                        (cons 'sleep (seconds-to-time sleep-float))))
         (idle-dur    (current-idle-time))
         (idle-b      (when (and idle-dur cl:idle-warn-seconds
                                 (>= (float-time idle-dur) cl:idle-warn-seconds))
                        (cons 'idle (time-subtract now-time idle-dur))))
         (exp-time    (timer--time (cl::session-timer-session cl::session)))
         (exp-b       (when (<= (float-time exp-time) now-float)
                        (cons 'expired exp-time)))
         (candidates  (delq nil (list idle-b sleep-b exp-b))))
    (when candidates
      (cl-reduce (lambda (a b) (if (< (float-time (cdr a)) (float-time (cdr b))) a b))
                 candidates))))

(defun cl::interrupt-pick (kind-label break-p boundary prev-marker prev-title
                                      expand-state protect-seconds)
  "Interactively collect the user's full interrupt response.

KIND-LABEL is the display string for what triggered the interrupt
\(\"Idle\", \"Asleep\", or \"Expired\").
BREAK-P is non-nil when the interrupted session was a break task.
BOUNDARY is the interrupt boundary time value; used both to compute the
live elapsed display and to cap the keep-minutes sub-prompt.
PREV-MARKER is the marker for the task that was running at interrupt time.
PREV-TITLE is its heading string, used in the duration prompt.
EXPAND-STATE is a one-element list whose car reflects whether the full
candidate list is currently shown; updated in place for the live prompt.
PROTECT-SECONDS is the keystroke suppression window (seconds) for the
very first call to the task picker; nil or zero disables it.

Returns a plist (:marker M :keep K :duration D :break-p B) where:
  :marker   — task to clock into (a marker), or nil (stay locked, no new session)
  :keep     — minutes of the old session to retain, or \\='all (keep everything)
  :duration — minutes for the new session, or nil (no new session, stay locked)
  :break-p  — break-filter state in effect when :marker was committed; used
              to tag a freshly typed title (a new task) with a BREAK property

Special case: when :marker equals PREV-MARKER and :keep is \\='all, the old
session is resumed for :duration minutes without clocking out.

C-g at any sub-prompt (keep-minutes, duration) returns to the task picker.
The function loops until the user commits a fully resolved choice."
  (let (result (break-state (list break-p)))
    (while (null result)
      (let* ((keep-all nil)
             (marker
              (condition-case nil
                  (minibuf-ext-with-live-prompt
                   (lambda ()
                     (let* ((secs (max 0 (round (float-time
                                                 (time-subtract (current-time) boundary)))))
                            (mm (/ secs 60))
                            (ss (% secs 60))
                            (since-str (format-time-string "%H:%M" boundary)))
                       (format "%s since %s (for %d:%02d) — %s%s"
                               kind-label since-str mm ss
                               (if break-p "Break" "Task")
                               (if (car expand-state)
                                   " (all, C-c C-e keep): "
                                 " [< all, C-c C-e keep]: "))))
                   1
                   (minibuf-ext-with-protection
                    (:seconds     protect-seconds
                                  :max-seconds cl:prompt-protect-max-seconds
                                  :min-idle    cl:prompt-protect-min-idle)
                    (minibuffer-with-setup-hook
                        (lambda ()
                          (define-key (current-local-map)
                                      (kbd "C-c C-e")
                                      (lambda ()
                                        (interactive)
                                        (setq keep-all t)
                                        (abort-recursive-edit))))
                      (cl:read-task nil break-p expand-state break-state))))
                (quit nil))))
        ;; Protection only applies on the first invocation of the picker
        (setq protect-seconds nil)
        (cond
         ;; ── C-c C-e: keep everything, stay locked ──────────────────────
         (keep-all
          (setq result (list :marker nil :keep 'all :duration nil)))

         ;; ── C-g at picker: open keep-minutes prompt recursively ─────────
         ((null marker)
          (let* ((max-mins (max 0 (round (/ (float-time
                                             (time-subtract (current-time) boundary))
                                            60))))
                 (keep (if (= max-mins 0)
                           0
                         (ignore-error quit
                           (max 0 (min max-mins
                                       (string-to-number
                                        (read-string
                                         (format "Minutes to keep (0–%d) [0]: " max-mins)
                                         nil nil "0"))))))))
            ;; nil keep = C-g at sub-prompt → loop back to task picker
            (when keep
              (setq result (list :marker nil :keep keep :duration nil)))))

         ;; ── Task selected: open duration prompt recursively ─────────────
         (t
          (let* ((same-p  (cl::markers-equal-p marker prev-marker))
                 (title   (if (markerp marker) (cl::heading-at marker) marker))
                 (remaining (cl::secs-remaining))
                 (silent-resume-p
                  (and same-p
                       (> remaining 0)
                       (or (not cl:idle-warn-seconds)
                           (>= remaining cl:idle-warn-seconds))))
                 (default-mins
                  (cond
                   (silent-resume-p (round (/ remaining 60)))
                   (same-p (or (and (> remaining 0) (round (/ remaining 60)))
                               (cl::effort-minutes prev-marker)
                               cl:default-duration))
                   (t (or (and (markerp marker) (cl::effort-minutes marker))
                          (if break-p cl:default-break cl:default-duration))))))
            (if silent-resume-p
                (setq result (list :marker marker :keep 'all
                                   :duration (round (/ remaining 60))
                                   :break-p (car break-state)))
              (let* ((base (max 0 (round
                                   (/ (float-time
                                       (time-subtract (current-time) boundary))
                                      60))))
                     (mins (ignore-error quit
                             (cl::read-minutes
                              (format (if same-p "Continue \"%s\" for" "Work on \"%s\" for")
                                      title)
                              default-mins
                              (and same-p base)))))
                ;; nil mins = C-g at duration prompt → loop back to task picker
                (when mins
                  (setq result
                        (if (and same-p (<= mins base))
                            ;; Clock-out
                            (list :marker nil :keep mins :duration nil)
                          (list :marker marker :keep base
                                :duration (if same-p (- mins base) mins)
                                :break-p (car break-state))))))))))))
    result))

(defun cl::interrupt-prompt ()
  "Unified session interrupt handler for idle/sleep/expiry.

Defers until no minibuffer is active.  Determines the earliest boundary,
cancels timers, locks, then calls `cl::interrupt-pick' once to collect the
user's fully committed choice.  Dispatches the result:

  :marker nil, :keep K      — clock out at boundary+K (or now if K=\\='all),
                               stay locked.
  Same marker, :keep \\='all  — resume: re-arm the session for :duration minutes
                               without clocking out.
  Otherwise               — clock out at boundary+K (or now), clock into
                             :marker for :duration minutes."
  (when (and cl::session (not cl::locked-p))
    (minibuf-ext-when-inactive
     (when (and cl::session (not cl::locked-p))
       (let* ((kbnd       (or (cl::interrupt-boundary)
                              (cons 'expired (current-time))))
              (kind       (car kbnd))
              (boundary   (cdr kbnd))
              (kind-label (pcase kind
                            ('idle    "Idle")
                            ('sleep   "Asleep")
                            ('expired "Expired"))))
         (let ((ts (cl::session-timer-session cl::session))
               (ti (cl::session-timer-idle    cl::session)))
           (when (timerp ts) (cancel-timer ts))
           (when (timerp ti) (cancel-timer ti)))
         (cl::end-session t)
         (let* ((prev-marker  (cl::session-marker  cl::session))
                (prev-title   (cl::session-title   cl::session))
                (break-p      (cl::session-break-p cl::session))
                (expand-state (list nil))
                (choice       (cl::interrupt-pick
                               kind-label break-p boundary
                               prev-marker prev-title
                               expand-state cl:prompt-protect-seconds))
                (marker   (plist-get choice :marker))
                (keep     (plist-get choice :keep))
                (duration (plist-get choice :duration))
                (resume-p (and marker
                               (cl::markers-equal-p marker prev-marker)
                               duration)))
           (if resume-p
               ;; Resume: same task, no absent time discarded — continue=t
               ;; so planned minutes accumulate correctly.
               (cl::begin-session prev-title
                                  (copy-marker prev-marker)
                                  duration
                                  (or keep 0))
             ;; Clock out the previous task at the appropriate time.
             (if (eq keep 'all)
                 (cl::org-clock-out nil t)
               (cl::org-clock-out nil t
                                  (time-add boundary
                                            (seconds-to-time (* keep 60)))))
             ;; Start a new session if a task and duration were chosen.
             (when (and marker duration)
               (let* ((title (if (markerp marker) (cl::heading-at marker) marker))
                      (new-marker (if (markerp marker)
                                      (copy-marker marker)
                                    (cl::capture-org-task
                                     title (and (plist-get choice :break-p)
                                                '(("BREAK" . "t")))))))
                 (cl::begin-session title new-marker duration))))))))))

;;; Org-clock integration

(defun cl::adopt-running-clock (&optional force)
  "If org is clocked in, offer to adopt it as a session.
With FORCE non-nil the initial yes/no is skipped and minute-reading
starts immediately; a quit from minutes falls back to the yes/no prompt.
Without FORCE a quit from minutes also falls back to the yes/no prompt.
Returns non-nil if the clock was adopted, nil if the user declined."
  (when (org-clocking-p)
    (let* ((marker    org-clock-marker)
           (title     (cl::heading-at marker))
           (confirmed force))
      (catch 'result
        (while t
          (if confirmed
              ;; Try to read minutes; quit loops back to the yes/no.
              (let ((mins (ignore-error quit
                            (cl::read-minutes
                             (format "Session length for \"%s\"" title)
                             cl:default-duration))))
                (if mins
                    (progn
                      (cl::begin-session title (copy-marker marker) mins)
                      (throw 'result t))
                  (setq confirmed nil)))
            ;; Yes/no prompt — quit here propagates upward.
            (if (y-or-n-p (format "Adopt clock in: \"%s\"?" title))
                (setq confirmed t)
              (throw 'result nil))))))))

(defun cl::on-clock-out ()
  "Handle `org-clock-out-hook'.
If still clocked in (task switched), adopt the new clock immediately."
  (unless
      (if (org-clocking-p)
          (cl::adopt-running-clock t)
        cl::locked-p)
    (cl::end-session)))

;;; State transitions

(defun cl::begin-session (title marker minutes &optional continue)
  "Transition to unlocked state for TITLE (at MARKER) for MINUTES.
With CONTINUE non-nil, this is a continuation of the previous session:
:planned-minutes accumulates the additional minutes on top of the
previous planned total."
  (cl-block nil
    (setq cl::locked-p nil)
    (let* ((prev-planned (and continue cl::session
                              (cl::session-planned-minutes cl::session)))
           (planned    (+ (or prev-planned 0) minutes
                          (if (numberp continue)
                              continue
                            0)))
           (break-p    (if (and continue cl::session)
                           (cl::session-break-p cl::session)
                         (cl::marker-is-break-p marker))))
      (cl::cancel-timers)
      ;; Clock-in first, then save in cl::session. We might clock out an older
      ;; session which calls cl::end-session, which then resets cl::session
      (unless (org-clocking-p)
        (condition-case err
            (org-with-point-at marker (org-clock-in))
          (error
           (message "org-clock-lock: failed to clock in to \"%s\": %s"
                    title (error-message-string err))
           (setq cl::session nil)
           (cl::end-session)
           (cl-return))))
      (setq cl::session
            (cl::make-session
             :marker          marker
             :title           title
             :break-p         break-p
             :planned-minutes planned
             :timer-session   (if (and cl::session continue)
                                  (cl::session-timer-session cl::session)
                                (timer-create))
             :timer-idle      (if (and cl::session continue)
                                  (cl::session-timer-idle cl::session)
                                (timer-create))))
      (cl::hide-lock-screen)
      (cl::install-header)
      (let ((ts (cl::session-timer-session cl::session)))
        (timer-set-function ts #'cl::interrupt-prompt)
        (timer-set-time ts (timer-relative-time nil (* minutes 60)))
        (timer-activate ts))
      (setq cl::tick-timer
            (or cl::tick-timer
                (run-at-time 1 1 #'cl::tick)))
      (when (and (not (cl::session-break-p cl::session))
                 cl:idle-warn-seconds
                 (> (* minutes 60) cl:idle-warn-seconds))
        (let ((ti (cl::session-timer-idle cl::session)))
          (timer-set-function ti #'cl::interrupt-prompt)
          (timer-set-idle-time ti cl:idle-warn-seconds)
          (timer-activate-when-idle ti)))
      (message "%s: \"%s\" (%d min)"
               (if (cl::session-break-p cl::session) "Break" "Session")
               title minutes)
      (run-hooks 'cl:session-start-hook))))

(defun cl::end-session (&optional keep-state)
  "Transition to locked state.
Also end current session, unless KEEP-STATE is non-nil."
  (when (and (not keep-state) cl::session)
    (unwind-protect
        (progn
          (run-hooks 'cl:session-end-hook)
          (cl:ui--log-session-entry))
      (cl::cancel-timers)
      (setq cl::session nil)))
  (unless cl::locked-p
    (cl::remove-header)
    (setq cl::locked-p cl:locked-map)
    (cl::show-lock-screen)))

(defun cl::org-clock-out (&rest args)
  "Clock-out and enter locked state, even if clock-out errored."
  (unwind-protect
      (when (org-clocking-p)
        (apply #'org-clock-out args))
    (cl::end-session)))

(defun cl::markers-equal-p (m1 m2)
  "Non-nil if markers M1 and M2 point to the same buffer position."
  (and (markerp m1) (markerp m2)
       (eq (marker-buffer m1) (marker-buffer m2))
       (= (marker-position m1) (marker-position m2))))

;;; Log rendering ─────────────────────────────────────────────────────────────
;;
;; Layout (newest at top within each day):
;;
;;   ── today ▼  H:MM spent · H:MM planned ────────   (footer, today's toggle)
;;   HH:MM–HH:MM  Title                    H:MM  (H:MM on task)
;;   ················ N min ················          (gap, if ≥ threshold)
;;   HH:MM–HH:MM  Title                    H:MM
;;   ── Fri 16 May ▶  H:MM spent · H:MM planned ──   (prev-day, collapsed)
;;
;; `cl::log-entries' is the sole source of truth (the lock buffer is an
;; org-agenda buffer, erased and rebuilt on every redo/relock, so nothing can
;; live in buffer text between renders).  `cl::log-render' rebuilds the whole
;; block from it on every call; `cl::log-collapsed-days' says which days to
;; render without their body lines.  Every rendered line still carries the
;; `cl::log-line' property so `cl::log-bounds' can find and replace just this
;; block inside the larger agenda buffer.

(defconst cl::log-title-width 36
  "Display columns reserved for the task title in log lines.")

(defun cl::log-fmt-day-label (date)
  "Format DATE (YYYY-MM-DD) as e.g. \"Fri 16 May\"."
  (format-time-string "%a %e %b" (date-to-time (concat date " 00:00:00"))))

;;; Line constructors ──────────────────────────────────────────────────────────

(defun cl::log-make-session-line (start end title break-p spent planned cumul date)
  "Return a propertized log line for a completed session.
START and END are time values for the session's clock-in and clock-out times.
TITLE is the task heading string.
BREAK-P is non-nil when this was a break session (adds a ☕ icon).
SPENT is the number of minutes actually clocked in this session.
PLANNED is the number of minutes originally scheduled for this session.
CUMUL is the total minutes clocked on this task up to and including this
session; when CUMUL > SPENT an annotation showing the cumulative total is
appended.
DATE is the session date string (YYYY-MM-DD)."
  (let* ((tr    (format "%s–%s"
                        (format-time-string "%H:%M" start)
                        (format-time-string "%H:%M" end)))
         (icon  (if break-p "☕ " ""))
         (disp  (truncate-string-to-width
                 (concat icon title) cl::log-title-width nil ?\s "…"))
         (dur   (concat (propertize (cl::fmt-hh-mm spent)   'face 'cl:spent-face)
                        "/"
                        (propertize (cl::fmt-hh-mm planned) 'face 'cl:planned-face)))
         (base  (concat "  "
                        (format "%-11s" tr)
                        "  "
                        (format (format "%%-%ds" cl::log-title-width) disp)
                        "  "
                        dur))
         (annot (when (> cumul spent)
                  (propertize (format "  (%s on task)" (cl::fmt-hh-mm cumul))
                              'face 'shadow)))
         (line  (concat base (or annot "") "\n")))
    (add-text-properties 0 (length line)
                         (list 'cl::log-line t 'cl::date date)
                         line)
    line))

(defun cl::log-make-gap-line (minutes date)
  "Return a propertized gap indicator line for MINUTES of unaccounted time.
DATE is the date string (YYYY-MM-DD) of the surrounding sessions."
  (let* ((label (format " %d min " minutes))
         (pad   58)
         (left  (max 4 (/ (- pad (length label)) 2)))
         (right (max 4 (- pad (length label) left)))
         (line  (concat "  " (make-string left ?·)
                        label (make-string right ?·) "\n")))
    (add-text-properties 0 (length line)
                         (list 'cl::log-line t 'cl::date date 'face 'shadow)
                         line)
    line))

(defun cl::log-make-ruler (label spent planned collapsed-p)
  "Return a propertized ─── ruler string with LABEL, arrow, and time totals.
LABEL is the centre text (e.g. \"today\" or a formatted day name).
SPENT and PLANNED are minute counts rendered as HH:MM in distinct faces.
COLLAPSED-P controls the ▶/▼ arrow appended to LABEL.
The returned string carries only face properties — callers add `cl::footer',
`cl::header', `cl::date', etc. via `add-text-properties'."
  (let* ((arrow     (if collapsed-p "▶" "▼"))
         (spent-str  (cl::fmt-hh-mm spent))
         (plan-str   (cl::fmt-hh-mm planned))
         (core       (format " %s %s  %s spent · %s planned " label arrow spent-str plan-str))
         (pad        62)
         (left       (max 2 (/ (- pad (length core)) 2)))
         (right      (max 2 (- pad (length core) left))))
    (concat
     (propertize (concat "  " (make-string left ?─)) 'face 'shadow)
     (propertize core                                  'face 'shadow)
     (propertize (concat (make-string right ?─) "\n") 'face 'shadow))))

(defun cl::log-make-footer-line (date spent planned &optional collapsed-p)
  "Return a propertized today-total ruler line.
DATE is the date string (YYYY-MM-DD) stored as a text property.
SPENT and PLANNED are minute counts for the day so far.
COLLAPSED-P controls the ▶/▼ arrow shown next to \"today\"."
  (let ((line (cl::log-make-ruler "today" spent planned collapsed-p)))
    (add-text-properties 0 (length line)
                         (list 'cl::log-line t 'cl::date date)
                         line)
    line))

(defun cl::log-make-header-line (date spent planned collapsed-p)
  "Return a propertized previous-day ruler line.
DATE is the date string (YYYY-MM-DD), formatted as e.g. \"Fri 16 May\" in the label.
SPENT and PLANNED are minute totals for that day.
COLLAPSED-P controls the ▶/▼ arrow shown next to the day label."
  (let ((line (cl::log-make-ruler (cl::log-fmt-day-label date) spent planned collapsed-p)))
    (add-text-properties 0 (length line)
                         (list 'cl::log-line t 'cl::date date)
                         line)
    line))

;;; Log operations ─────────────────────────────────────────────────────────────

(defun cl::log-render-day (entries date)
  "Render one day's session/gap lines, newest first.
ENTRIES are that DATE's plists from `cl::log-entries', newest first.
The cumulative-on-task annotation for each line sums that entry and every
older same-marker entry in ENTRIES; gaps are the time between one entry's
start and the next (older) entry's end."
  (apply #'concat
         (cl-loop for (e . older) on entries
                  for cumul = (cl-reduce
                               #'+ (cons e older) :initial-value 0
                               :key (lambda (x)
                                      (if (cl::markers-equal-p
                                           (plist-get x :marker) (plist-get e :marker))
                                          (plist-get x :spent) 0)))
                  collect (cl::log-make-session-line
                           (plist-get e :start) (plist-get e :end)
                           (plist-get e :title) (plist-get e :break-p)
                           (plist-get e :spent) (plist-get e :planned)
                           cumul date)
                  when older
                  collect (let ((gap (max 0 (round
                                              (/ (float-time
                                                  (time-subtract (plist-get e :start)
                                                                 (plist-get (car older) :end)))
                                                 60)))))
                            (if (>= gap cl:log-min-gap-minutes)
                                (cl::log-make-gap-line gap date)
                              "")))))

(defun cl::log-render ()
  "Return the full rendered log section, most recent day first.
Always includes today, even with no sessions logged yet."
  (let* ((today   (format-time-string "%Y-%m-%d"))
         (by-date (seq-group-by (lambda (e) (plist-get e :date)) cl::log-entries))
         (dates   (sort (cl-adjoin today (mapcar #'car by-date) :test #'equal)
                        #'string>)))
    (mapconcat
     (lambda (date)
       (let* ((entries (sort (copy-sequence (alist-get date by-date nil nil #'equal))
                              (lambda (a b) (time-less-p (plist-get b :start)
                                                         (plist-get a :start)))))
              (spent   (cl-reduce #'+ entries :initial-value 0
                                   :key (lambda (e) (plist-get e :spent))))
              (planned (cl-reduce #'+ entries :initial-value 0
                                   :key (lambda (e) (plist-get e :planned))))
              (collapsed-p (and (member date cl::log-collapsed-days) t)))
         (concat (if (equal date today)
                     (cl::log-make-footer-line date spent planned collapsed-p)
                   (cl::log-make-header-line date spent planned collapsed-p))
                 (unless collapsed-p (cl::log-render-day entries date)))))
     dates "")))

(defun cl::log-bounds ()
  "Return (START . END) of the rendered log block, or nil if absent."
  (when-let* ((start (text-property-any (point-min) (point-max) 'cl::log-line t)))
    (cons start (or (text-property-not-all start (point-max) 'cl::log-line t)
                    (point-max)))))

(defun cl::redraw-log ()
  "Regenerate the log block from `cl::log-entries' in place."
  (when-let* ((bounds (cl::log-bounds)))
    (let ((inhibit-read-only t))
      (save-excursion
        (delete-region (car bounds) (cdr bounds))
        (goto-char (car bounds))
        (insert (cl::log-render))))))

(defun cl::log-toggle-day ()
  "Toggle collapse/expand of the log day-block at point."
  (interactive)
  (when-let* ((date (get-text-property (point) 'cl::date)))
    (if (member date cl::log-collapsed-days)
        (setq cl::log-collapsed-days (delete date cl::log-collapsed-days))
      (push date cl::log-collapsed-days))
    (cl::redraw-log)))

(defun cl:ui--log-session-entry ()
  "Record the just-completed session in `cl::log-entries'.
Also collapses any day that is no longer today, mirroring the log's old
auto-collapse-on-rollover behaviour."
  (when cl::session
    (let* ((marker  (cl::session-marker         cl::session))
           (break-p (cl::session-break-p         cl::session))
           (title   (cl::session-title           cl::session))
           (planned (cl::session-planned-minutes cl::session))
           (end     (or org-clock-out-time (current-time)))
           (start   org-clock-start-time)
           (spent   (max 0 (round (org-time-convert-to-integer
                                   (time-subtract end start)) 60)))
           (date    (format-time-string "%Y-%m-%d" start))
           (today   (format-time-string "%Y-%m-%d")))
      (unless (<= spent 0)
        (push (list :title title :break-p break-p :start start :end end
                    :spent spent :planned planned :marker marker :date date)
              cl::log-entries)
        (unless (equal date today)
          (cl-pushnew date cl::log-collapsed-days :test #'equal))))))


(defun cl:ui-status-strings ()
  "Return status strings for the active session as (symbol title time-str hint).
When secs is negative the session has expired and the interrupt prompt
is pending; the time is shown in warning face."
  (when cl::session
    (let* ((secs       (cl::secs-remaining))
           (break-p    (cl::session-break-p cl::session))
           (idle       (current-idle-time))
           (idle-s     (if idle (round (float-time idle)) 0))
           (warn-s     (or cl:idle-warn-seconds 0))
           (expired-p  (<= secs 0))
           (near-end-p (and (not break-p)
                            (<= secs cl:session-warn-seconds)))
           (idle-p     (and (not break-p) (> warn-s 0) (> idle-s warn-s)))
           (time-str   (format "%02d:%02d"
                               (abs (/ secs 60)) (abs (% secs 60))))
           (hint
            (cond
             (idle-p
              (format "⚠ IDLE since %s"
                      (format-time-string
                       "%H:%M"
                       (time-subtract (current-time) (current-idle-time)))))
             (break-p
              (substitute-command-keys "\\[org-clock-out] end break"))
             (t
              (substitute-command-keys
               "\\[org-clock-out] clock-out  \\[org-clock-lock-switch-task] switch task")))))
      (list (if break-p "☕" (if (or near-end-p expired-p) "⚠⏱" "⏱"))
            (cl::session-title cl::session)
            (if expired-p
                (propertize time-str 'face 'org-warning)
              time-str)
            hint))))

;;; Lock screen buffer

(defun cl::agenda-redo ()
  "Rebuild the lock-screen agenda, log, and clock report from scratch.
Bound over the agenda's own `org-agenda-redo'/`org-agenda-redo-all',
which rename the buffer away from `cl::buf' and drop
`org-agenda-clockreport-mode' for a plain (non-sticky) agenda buffer
like this one."
  (interactive)
  (cl::refresh-lock-buffer))

(defun cl::agenda-finalize ()
  "Append the org-clock-lock preamble and day log to the lock buffer.
Runs on `org-agenda-finalize-hook', i.e. on every (re)generation of the
lock buffer, since `org-agenda-mode' erases and rebuilds it from
scratch each time."
  (when (equal (buffer-name) cl::buf)
    (goto-char (point-min))
    (insert
     "\n EMACS IS LOCKED\n\n"
     (substitute-command-keys
      (concat
       "\\<org-clock-lock--agenda-map>"
       "  \\[org-clock-lock-new-session]  Pick a task (C-c b inside to filter breaks)\n"
       (if (where-is-internal 'cl:mode cl::agenda-map)
           "  \\[org-clock-lock-mode]  Disable org-clock-lock\n"
         "")))
     "\n")
    (goto-char (point-max))
    (insert "\n" (cl::log-render))
    (cl::agenda-lock-minor-mode 1)))

(defun cl::refresh-lock-buffer ()
  "(Re)build the agenda-based lock buffer and return it.
Builds today's agenda into `cl::buf' via `org-agenda-list', with the
native clock report forced on; `cl::agenda-finalize' appends the
org-clock-lock preamble and day log once the agenda content is in."
  (let ((org-agenda-buffer-tmp-name cl::buf)
        (org-agenda-start-with-clockreport-mode t)
        (org-agenda-window-setup 'current-window)
        (org-agenda-sticky nil))
    (save-window-excursion
      (org-agenda-list nil nil 'day)))
  (get-buffer cl::buf))

(defun cl::ensure-lock-buffer ()
  "Return the lock screen buffer, building it if necessary."
  (or (get-buffer cl::buf) (cl::refresh-lock-buffer)))

(defun cl::show-lock-screen ()
  "Save each lockable frame's window config and show the lock buffer.
Rebuilds the buffer on every call so agenda, log, and clock report all
reflect current data.  See `cl::lockable-frame-p' for which frames are
considered."
  (let ((frames (cl-remove-if-not #'cl::lockable-frame-p (frame-list))))
    (setq cl::saved-frame-wconfs
          (mapcar (lambda (f)
                    (cons f (with-selected-frame f (current-window-configuration))))
                  frames))
    (let ((buf (cl::refresh-lock-buffer)))
      (dolist (f frames)
        (with-selected-frame f
          (cl::apply-lock-layout buf))))))

(defun cl::hide-lock-screen ()
  "Restore each frame's saved window configuration."
  (dolist (entry cl::saved-frame-wconfs)
    (when (frame-live-p (car entry))
      (with-selected-frame (car entry)
        (condition-case nil
            (set-window-configuration (cdr entry))
          (error (bury-buffer))))))
  (setq cl::saved-frame-wconfs nil))

;;; Header line

(defvar cl::original-header nil)

(defun cl::install-header ()
  (when cl:show-header
    (setq cl::original-header (default-value 'header-line-format))
    (setq-default header-line-format
                  '(:eval (string-join (cl:ui-status-strings) " ")))))

(defun cl::remove-header ()
  (when cl:show-header
    (setq-default header-line-format cl::original-header)))

;;; Minor mode

;;;###autoload
(define-minor-mode cl:mode
  "Block Emacs until you choose an org task, then protect your focus.

LOCKED   Full-frame lock screen: an org-agenda buffer with the day log
         and clock report appended.  `cl:locked-map' blocks navigation
         and buffer commands; \"t\" picks a task, TAB toggles a day-log block.

UNLOCKED Normal Emacs with optional header-line countdown.
         Break tasks (BREAK property) skip idle detection.

Session end
  Timer fires  — interrupt prompt over the lock screen.  Pick the same
                 task to resume, a different task to clock into (previous
                 task ends at the interrupt boundary), C-g to clock out
                 now, or C-c C-e to keep all time and clock out now.
  C-c f d      — org-clock-out; hook transitions to locked.
  C-c f t      — switch task; C-g keeps the current clock.
  Idle/sleep   — same interrupt prompt, with the idle or sleep start as
                 boundary.  Call `cl:on-sleep' from a system-sleep hook
                 for a precise boundary.

Startup: adopts a running org clock if one exists."
  :global t :lighter " 🔒"
  (if cl:mode
      (progn
        (unless
            (cl-find-if (lambda (e)
                          (and (consp e )
                               (assq 'org-clock-lock--locked-p e)))
                        emulation-mode-map-alists)
          (push `((cl::locked-p . ,cl:locked-map))
                emulation-mode-map-alists))
        (add-hook 'org-clock-out-hook #'cl::on-clock-out)
        (add-hook 'org-clock-cancel-hook #'cl::on-clock-out)
        (add-hook 'org-agenda-finalize-hook #'cl::agenda-finalize)
        (unless (cl::adopt-running-clock)
          (cl::end-session)))
    (setq emulation-mode-map-alists
          (cl-remove-if (lambda (e)
                          (and (consp e )
                               (assq 'org-clock-lock--locked-p e)))
                        emulation-mode-map-alists))
    (remove-hook 'org-clock-out-hook #'cl::on-clock-out)
    (remove-hook 'org-clock-cancel-hook #'cl::on-clock-out)
    (remove-hook 'org-agenda-finalize-hook #'cl::agenda-finalize)
    (cl::cancel-timers)
    (cl::hide-lock-screen)
    (cl::remove-header)
    (setq cl::locked-p            nil
          cl::saved-frame-wconfs  nil
          cl::session             nil)))

(provide 'org-clock-lock)

;; Local Variables:
;; read-symbol-shorthands: (("cl:" . "org-clock-lock-")
;;                          ("cl::" . "org-clock-lock--"))
;; End:
;;; org-clock-lock.el ends here
