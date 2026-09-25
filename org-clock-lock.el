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

(defcustom cl:auto-continue-max-gap-minutes nil
  "Silently continue the interrupted task when its gap is small enough.
nil: disabled -- every idle or sleep interrupt locks the screen and
opens (or, with `cl:defer-interrupt-prompt', defers) the prompt, same
as always.
integer: when an idle or sleep interrupt fires with a gap -- the time
between the idle/sleep boundary and now -- at or under this many
minutes, the interrupted task's clock entry is silently extended by
that gap instead: the screen is never locked and no prompt is shown, as
if the interrupt had not happened at all.  A brief message still notes
it.  Session expiry (the planned duration legitimately running out) is
never auto-continued this way, no matter how small the resulting gap
turns out to be -- that is always a deliberate stopping point, not
incidental absence, so `cl::interrupt-boundary' resolving to \\='expired
always goes through the normal locked flow."
  :type '(choice (const  :tag "Disabled" nil)
                 (natnum :tag "Max gap minutes")))

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

(defcustom cl:defer-interrupt-prompt nil
  "Non-nil to defer the interrupt prompt until a new task is picked.
When nil (default), an interrupt (idle, sleep, or session expiry) locks
the screen and immediately opens the interactive prompt asking what to
do with the just-interrupted task.

When non-nil, the interrupt only locks the screen; the prompt is not
shown.  The old clock keeps running (frozen at the interrupt boundary,
same as always) until you press \"t\" on the lock screen or invoke
`org-clock-lock-new-session' -- at that point the same prompt appears,
covering both what to do with the old task (resume, backdate, credit
time back to it, cancel it) and which new task to start, exactly as if
the interrupt had just happened.  Press \"c\" instead to resume that same
old task directly, skipping the picker.  While the interrupt sits
unresolved, the lock screen shows a status line naming the old task, why
it was interrupted, and since when.

In this mode, C-g at the top-level task picker does not force a
decision: it silently cancels back to the plain lock screen, leaving
the old task's fate undecided and nothing clocked out, so you can defer
again and revisit later.  This differs from the immediate-prompt case,
where C-g instead opens a \"minutes to keep\" sub-prompt, since an
already-fired live interrupt requires a resolution.  Also unlike the
immediate-prompt case, `cl:prompt-protect-seconds' keystroke protection
is skipped here: that protection exists for a prompt that appears
unannounced, and resolving here is always something you asked for by
pressing \"t\" or \"c\" on a screen you were already looking at."
  :type 'boolean)

(defcustom cl:debug-window-selection nil
  "Non-nil to log how window selection is saved and restored by the lock.
Every lock and unlock appends, to the buffer named by
`org-clock-lock--diag-buf', the selected frame and window, each
lockable frame's own selected window and current tab, and the call
stack that triggered it.  For `cl:diag-watch-seconds' after an unlock,
every later change of the selected window is logged too -- with the
calling function stack when the change came from a Lisp
`select-window'/`select-frame' call -- along with the first few
commands run.  View the log with `org-clock-lock-show-diagnostics'."
  :type 'boolean)

(defcustom cl:diag-watch-seconds 5
  "Seconds after an unlock during which selection changes are logged.
Only used when `cl:debug-window-selection' is non-nil."
  :type 'natnum)


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
    (define-key m (kbd "t") #'cl::agenda-new-session)
    (define-key m (kbd "c") #'cl::agenda-resume-task)
    (define-key m (kbd "u") #'cl:undo-clock-out)
    (define-key m (kbd "g") #'cl::agenda-redo)
    (define-key m (kbd "r") #'cl::agenda-redo)
    m)
  "Keymap layered over `org-agenda-mode-map' in the lock screen buffer.
Shadows the agenda's own \"t\", since in this buffer it picks a task
instead of cycling a TODO state.  Also shadows \"c\", used here to
resume a pending interrupted task directly (see `cl::agenda-resume-task'),
and \"u\", which undoes the last clock-out (see `org-clock-lock-undo-clock-out').")

(defvar cl::log-line-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "TAB") #'cl::log-toggle-day)
    (define-key m [tab] #'cl::log-toggle-day)
    m)
  "Keymap attached to org-clock-lock log lines via the `keymap' text
property, so TAB toggles a day's log block wherever
`org-clock-lock-agenda-log-block' is used -- the lock screen or any
other org-agenda buffer -- without shadowing TAB elsewhere.
Both TAB (C-i, event 9) and [tab] are bound, mirroring
`org-agenda-mode-map' itself: a GUI frame's physical Tab key can
generate either event, and a `keymap' text property only matches the
exact event it defines, so binding just one leaves the other falling
through to whatever the buffer's local map does with it -- e.g.
`org-agenda-goto' in a plain org-agenda buffer.")

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
    (define-key m (kbd "C-c f u") #'cl:undo-clock-out)
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
                   org-agenda-kill-all-agenda-buffers
                   tab-bar-select-tab tab-select
                   tab-bar-switch-to-next-tab tab-next
                   tab-bar-switch-to-prev-tab tab-previous
                   tab-bar-switch-to-tab tab-switch
                   tab-bar-switch-to-recent-tab tab-recent
                   tab-bar-switch-to-last-tab tab-last))
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

(defvar cl::saved-selection nil
  "The window selected when the lock screen was raised, or nil.
Nil too when that window was a minibuffer window or on a frame that
isn't lockable (see `cl::lockable-frame-p').  Reselected explicitly by
`cl::hide-lock-screen' once every frame's configuration is back:
restoring each frame in turn leaves selected whichever frame was
selected at unlock time, not the one selected at lock time.")

(defvar cl::lock-tab-token nil
  "Object tagging each frame's tab that was current at lock time.
Stored under the `org-clock-lock' parameter of that tab.  The tab bar
carries unknown tab parameters along when switching tabs, so the tab
can be found again, and switched back to, if another tab gets selected
while locked -- see `cl::select-locked-tab'.")

(defvar cl::last-clock-out nil
  "Plist describing the most recent clock-out, for `cl:undo-clock-out'.
Keys: :hd-marker (the task's heading), :clock-marker (start of its
CLOCK line, nil if org removed a zero-length one), :line (that line's
text, to tell whether it was edited since), :title, :start and
:end (time values of the clock entry), :planned (the session's planned
minutes, or nil), :break-p.  Recorded by `cl::record-clock-out'.")

(defvar cl::inhibit-clock-hooks nil
  "Non-nil while org-clock-lock is clocking in or out on its own.
Makes `cl::on-clock-out' and `cl::record-clock-out' do nothing, for
changes whose lock/unlock and logging the caller handles itself.")

(defvar cl::last-tick-time nil
  "Float-time of the most recent `cl::tick' call, or nil before the first tick.
Nil is reset by `cl::cancel-timers' so the first tick of a new session
does not false-positive against a stale pre-sleep timestamp.")

(defvar cl::pending-interrupt nil
  "Cons (KIND-LABEL . BOUNDARY) for a not-yet-resolved deferred interrupt.
Set by `cl::interrupt-prompt' when `cl:defer-interrupt-prompt' is
non-nil, instead of resolving the interrupt immediately.  Nil when there
is nothing pending.  The interrupted task's marker/title/break-p are not
duplicated here -- they are still sitting in `cl::session', which
`cl::end-session' left intact (keep-state t) precisely for this purpose.
Cleared by `cl::interrupt-dispatch' once the user commits a resolution,
and on `org-clock-lock-mode' disable.")


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
  (with-demoted-errors "org-clock-lock: lock layout error: %S"
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
configuration saved first.  A frame that was saved but has since had
another tab selected is switched back to its locked tab instead (see
`cl::select-locked-tab'), so the lock layout never lands in, and
later overwrites, a second tab.  See `cl::lockable-frame-p' for which
frames are considered."
  (when cl::locked-p
    (let ((buf (cl::ensure-lock-buffer)))
      (dolist (frame (frame-list))
        (when (and (frame-live-p frame) (cl::lockable-frame-p frame))
          (if (assq frame cl::saved-frame-wconfs)
              (when-let* ((tab (with-selected-frame frame
                                 (cl::select-locked-tab frame))))
                (cl::diag "ENFORCE %S: locked tab %S" frame tab))
            (cl::diag "ENFORCE %S: saving late frame" frame)
            (push (cons frame (with-selected-frame frame
                                (current-window-configuration)))
                  cl::saved-frame-wconfs)
            (cl::tag-current-tab frame))
          (unless (get-buffer-window buf frame)
            (with-selected-frame frame
              (cl::apply-lock-layout buf))))))))

(defun cl::on-tab-select (&rest _)
  "Put the lock screen back after a tab switch while locked.
On `tab-bar-tab-post-select-functions'.  `cl:locked-map' blocks the tab
commands themselves, but not commands that call them as functions.
Deferred to a timer since this runs in the middle of the switch."
  (when cl::locked-p
    (run-at-time 0 nil #'cl::enforce-lock-screen)))

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

(defun cl::minibuffer-bind-help (key text)
  "Bind KEY, in the active minibuffer, to toggle a persistent display of
TEXT below the current input -- the minibuffer window grows to fit it,
the same way a completion UI like Vertico expands the minibuffer to show
its candidate list below the prompt, just with fixed content here
instead of live candidates.  Unlike `minibuffer-message', the text stays
up (and the window stays grown) across further keystrokes, until KEY is
pressed again or the prompt exits.

Call from a `minibuffer-with-setup-hook' function.  Installs a fresh
child keymap parented to whatever local map is already active rather
than mutating that map in place -- the active map for a plain
`read-string'/`read-from-minibuffer' call is `minibuffer-local-map'
itself, a single object shared across every such call in the session,
so binding KEY directly on it would leak into unrelated prompts
elsewhere; a child keymap keeps the binding local to this one
minibuffer session while still falling through to every other binding
via the parent.

The display itself is a zero-width overlay at (point-max) carrying a
`before-string', repositioned via a buffer-local `post-command-hook' so
it stays trailing the input as it grows or shrinks -- the exact
mechanism Vertico itself uses for its candidates overlay (including the
FRONT-ADVANCE/REAR-ADVANCE t t on `make-overlay', which pins the
zero-width overlay at the insertion point so it advances correctly the
instant text is typed, ahead of the next `post-command-hook' run rather
than relying on that alone) and the leading `cursor t' text property on
the `before-string' (also lifted from Vertico), which is what keeps the
terminal cursor rendered at the actual input position instead of after
the whole overlay -- without it, point sitting at the overlay's
position renders the cursor below the help text instead.  A
buffer-local `minibuffer-exit-hook' deletes the overlay when the prompt
exits, since the minibuffer buffer is reused across prompts and a
leftover overlay would otherwise linger into the next one."
  (let ((map (make-sparse-keymap))
        ov reposition)
    (set-keymap-parent map (current-local-map))
    (setq reposition
          (lambda ()
            (when (overlayp ov) (move-overlay ov (point-max) (point-max)))))
    (add-hook 'minibuffer-exit-hook
              (lambda () (when (overlayp ov) (delete-overlay ov)))
              nil t)
    (define-key map key
                (lambda ()
                  (interactive)
                  (if (overlayp ov)
                      (progn (delete-overlay ov)
                             (setq ov nil)
                             (remove-hook 'post-command-hook reposition t))
                    (setq ov (make-overlay (point-max) (point-max) nil t t))
                    ;; Leading #(" " 0 1 (cursor t)) marks where redisplay
                    ;; should actually draw the cursor -- without it, point
                    ;; sitting at the overlay's position (the end of the
                    ;; input) renders the cursor after the whole
                    ;; before-string instead, i.e. below the help text.
                    ;; Same fix Vertico applies to its own candidates
                    ;; overlay, for the same reason.
                    (overlay-put ov 'before-string
                                 (concat #(" " 0 1 (cursor t))
                                         (propertize (concat "\n" text)
                                                     'face 'shadow)))
                    (add-hook 'post-command-hook reposition nil t))))
    (use-local-map map)))

(defun cl::read-minutes (prompt default)
  "Read a session duration in minutes, returning a positive integer.
PROMPT is displayed before the bracketed default value.
DEFAULT is returned when the user enters blank input.
Values above `cl:session-limits' max are rejected with a message.
Values below `cl:session-limits' min trigger a y-or-n-p confirmation.
Signals `quit' if the user presses C-g.

Accepts \"N\" or \"N-M\" (see `cl::parse-duration-spec', called with no
GAP so a \"/O\" part is never offered here): a bare N is returned as is;
\"N-M\" backdates by M, returning (max 0 (- N M)).  Unparsable input
re-prompts with an explanation instead of silently falling back to
DEFAULT.  Press \"?\" at the prompt for a fuller explanation of the
syntax (see `cl::minibuffer-bind-help'), toggled below the prompt
instead of crowding it."
  (let (result)
    (while (null result)
      (let* ((raw  (minibuffer-with-setup-hook
                       (lambda ()
                         (cl::minibuffer-bind-help
                          (kbd "?")
                          "N      total minutes, as given
N-M    N total minutes, but M of those already happened
       -- it started M minutes ago"))
                     (read-string
                      (format "%s [default: %d min, ? for help]: "
                              prompt default)
                      nil nil (number-to-string default))))
             (spec (cl::parse-duration-spec raw default nil))
             (val  (and spec
                        (if (nth 3 spec)
                            (max 0 (- (nth 0 spec) (nth 1 spec)))
                          (nth 0 spec)))))
        (if (not val)
            (progn
              (message "Can't parse %S as \"N\" or \"N-M\"" raw)
              (sit-for 1.5))
          (setq result (cl::duration-range-check val)))))
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
C-g at the duration prompt returns to the task picker.

When `org-clock-lock--pending-interrupt' is set -- a deferred interrupt
awaiting resolution, see `org-clock-lock-defer-interrupt-prompt' -- PROMPT
and SWITCH are ignored and this instead resolves that interrupt via
`org-clock-lock--interrupt-resolve': its picker covers both what to do
with the interrupted task and which task to start next, exactly as if
the interrupt had just happened.  A bare C-g at that picker is a clean
no-op -- nothing clocked out, the interrupt still pending."
  (interactive)
  (if cl::pending-interrupt
      (cl::interrupt-resolve (car cl::pending-interrupt)
                             (cdr cl::pending-interrupt)
                             t)
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
                  (setq done t))))))))))

(defun cl:switch-task ()
  "Select a new task then clock out of current and clock in.
C-g at any prompt leaves the current clock running."
  (interactive)
  (cl:new-session nil t))

(defun cl::agenda-new-session ()
  "Start a session, defaulting to the task at point in the lock screen.
On an agenda line for a task (an `org-hd-marker' or `org-marker' text
property present at point) \"t\" is taken to mean \"clock into this
task\": skip the picker and go straight to the duration prompt for it.
Prefers `org-hd-marker' -- the heading's own position -- over
`org-marker', which for e.g. a scheduled entry points at the timestamp
instead; `cl::heading-at' and friends need point on the heading line.
A clock already running for that SAME task is left alone (just a
message, no re-prompt); a clock running for a DIFFERENT task is ended
first, same as `org-clock-lock-switch-task'.  Same comparison
`org-agenda-mark-clocking-task' itself uses: `org-hd-marker' against
`org-clock-hd-marker', not the entry/CLOCK-line markers.
Falls back to the full task picker (`org-clock-lock-new-session') when
point isn't on a task line.

When `org-clock-lock--pending-interrupt' is set, the marker-at-point fast
path is skipped entirely -- deferred interrupts always go through the
full picker (via `org-clock-lock-new-session'), which is what asks what
to do with the interrupted task alongside picking the next one."
  (interactive)
  (if cl::pending-interrupt
      (cl:new-session)
    (if-let* ((marker (or (org-get-at-bol 'org-hd-marker)
                          (org-get-at-bol 'org-marker))))
      (if (and (org-clocking-p) (cl::markers-equal-p marker org-clock-hd-marker))
          (message "Already clocked into \"%s\"" (cl::heading-at marker))
        (let* ((title        (cl::heading-at marker))
               (break-p      (cl::marker-is-break-p marker))
               (default-mins (or (cl::effort-minutes marker)
                                 (if break-p cl:default-break cl:default-duration)))
               (mins         (ignore-error quit
                               (cl::read-minutes
                                (format "Work on \"%s\" for" title)
                                default-mins))))
          (when mins
            (when (org-clocking-p)
              (cl::org-clock-out nil t))
            (cl::begin-session title (copy-marker marker) mins))))
      (cl:new-session))))

(defun cl::agenda-resume-task ()
  "Resume the pending interrupted task, skipping the task picker.
Mirrors the fast path `cl::agenda-new-session' offers for a task at
point (\"t\"): jumps straight to the duration prompt, here for the
interrupted task itself rather than whatever is at point.  Only
meaningful when `cl::pending-interrupt' is set (see
`cl:defer-interrupt-prompt'); with nothing pending, this is a no-op with
a message.  The plain task picker (`org-clock-lock-new-session', \"t\")
remains available to switch to a different task instead."
  (interactive)
  (if cl::pending-interrupt
      (cl::interrupt-resolve (car cl::pending-interrupt)
                             (cdr cl::pending-interrupt)
                             t
                             (cl::session-marker cl::session))
    (message "No interrupted task to resume")))

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

(defun cl::parse-duration-spec (raw default gap)
  "Parse RAW as \"N\", \"N-M\", or \"N-M/O\".
DEFAULT is substituted for N when omitted; M defaults to 0.
GAP, when non-nil, bounds M+O — the two must never claim more than GAP
— and permits a trailing \"/O\" part.  When GAP is nil, a \"/O\" part is
rejected as unparsable: there is no gap to credit anything from.

O defaults to 0 (nothing credited) when \"/O\" is omitted entirely.  A
bare trailing \"/\" with no digits after it — only meaningful when GAP is
given — instead credits the maximum possible, (- GAP M): a caller can
offer \"credit everything\" without knowing GAP itself, and without that
meaning the same thing as an explicit \"/0\".

Returns a list (N M O DASH-P), where DASH-P is non-nil only when RAW
actually has a \"-M\" part.  Returns nil if RAW cannot be parsed this
way, if a \"/O\" part is present without GAP, or if M+O exceeds GAP."
  (when (and (string-match
              "\\`[ \t]*\\([0-9]+\\)?[ \t]*\\(-[ \t]*\\([0-9]+\\)\\)?[ \t]*\\(/[ \t]*\\([0-9]+\\)?\\)?[ \t]*\\'"
              raw)
             (or gap (not (match-string 4 raw))))
    (let* ((n      (if (match-string 1 raw) (string-to-number (match-string 1 raw)) default))
           (m      (if (match-string 3 raw) (string-to-number (match-string 3 raw)) 0))
           (o      (cond
                    ((not (match-string 4 raw)) 0)
                    ((match-string 5 raw) (string-to-number (match-string 5 raw)))
                    (t (max 0 (- (or gap 0) m)))))
           (dash-p (and (match-string 2 raw) t)))
      (when (or (not gap) (<= (+ m o) gap))
        (list n m o dash-p)))))

(defun cl::duration-range-check (val)
  "Validate VAL against `cl:session-limits'.
Returns VAL if acceptable, possibly after a y-or-n-p confirmation for a
very short value.  Returns nil to signal the caller should reprompt —
after messaging, for a value above the maximum; silently, if the very
short confirmation is declined."
  (cond
   ((> val (cdr cl:session-limits))
    (message "%d min exceeds maximum of %d — try again."
             val (cdr cl:session-limits))
    (sit-for 1.5)
    nil)
   ((and (> val 0) (< val (car cl:session-limits)))
    (and (y-or-n-p (format "%d min is very short — use anyway? " val))
         val))
   (t val)))

(defun cl::read-task-duration (title default gap)
  "Read a duration spec for clocking into TITLE after an interrupt.
DEFAULT is the duration used when nothing is typed.  GAP is the number
of minutes since the interrupt boundary; all of it is dead time unless
some is explicitly credited back.  Used identically whether TITLE is the
just-interrupted task itself (a same-task continue) or a different one
(a switch) -- only which marker ends up clocked into differs; see
`cl::interrupt-pick'.

Accepts \"X\", \"X-N\", or \"X-N/O\" (see `cl::parse-duration-spec'):
  X — total minutes to work on TITLE, counting from its actual start.
  N — TITLE actually started N minutes ago (backdated clock-in).
  O — of GAP (minus N), O minutes are credited back to the task just
      clocked out instead of staying dead.  Omitting \"/O\" entirely
      credits nothing, the default.  A bare trailing \"/\" credits the
      maximum instead, (- GAP N) -- for a same-task continue with no
      backdate (\"X/\"), that credits the whole gap, so nothing was ever
      dead and `cl::interrupt-pick' keeps it a single unbroken clock
      entry instead of a real clock-out followed by a fresh clock-in.
      N+O must not exceed GAP, so the old and new sessions never overlap.

Returns a list (VALUE N O), or nil on C-g.  Unparsable input, or input
violating the N+O<=GAP or `cl:session-limits' bounds, re-prompts with an
explanation rather than silently falling back to a default.  An
already-elapsed total (X<=N) is always a hard reject -- there is no
\"just clock out\" fallback here; C-g at the top-level task picker is
that fallback instead.  The prompt itself carries GAP, so how much time
is up for grabs stays visible while typing the spec; the syntax proper
is behind \"?\" (see `cl::minibuffer-bind-help'), toggled below the
prompt instead of crowding it."
  (let (result)
    (while (null result)
      (let ((raw (condition-case nil
                     (minibuffer-with-setup-hook
                         (lambda ()
                           (cl::minibuffer-bind-help
                            (kbd "?")
                            (format "X      total minutes for the task, counting from its actual start
X-N    it actually started N minutes ago (backdated clock-in)
X-N/O  also credit O minutes of the %dm gap back to the task just
       clocked out (default: nothing credited)
X-N/   a bare trailing / credits the whole remaining gap instead --
       for a same-task pick with no backdate (X/), that keeps it
       one unbroken clock entry"
                                    gap)))
                       (read-string
                        (format "Work on \"%s\" for [default: %d min%s, ? for help]: "
                                title default
                                (if (> gap 0)
                                    (format ", %dm since interrupt" gap)
                                  ""))
                        nil nil (number-to-string default)))
                   (quit :quit))))
        (if (eq raw :quit)
            (setq result :quit)
          (let ((spec (cl::parse-duration-spec raw default gap)))
            (if (null spec)
                (progn
                  (message "Can't parse %S as \"X\", \"X-N\", or \"X-N/O\" (N+O ≤ %dm)" raw gap)
                  (sit-for 1.5))
              (pcase-let ((`(,val ,n ,o ,_) spec))
                (if (<= val n)
                    (progn
                      (message "%d min ≤ %d already elapsed — enter a larger total" val n)
                      (sit-for 1.5))
                  (let ((v (cl::duration-range-check val)))
                    (when v (setq result (list v n o)))))))))))
    (unless (eq result :quit) result)))

(defun cl::interrupt-pick (kind-label break-p boundary prev-marker prev-title
                                      expand-state protect-seconds
                                      &optional abort-on-quit preselect-marker)
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
ABORT-ON-QUIT, when non-nil, makes a bare C-g at the top-level task
picker abort the whole pick and return nil, instead of opening the
\"minutes to keep\" sub-prompt.  Used when the interrupt is being
resolved on the user's own initiative (`cl:defer-interrupt-prompt') so
backing out costs nothing -- no decision is forced, nothing is clocked
out.  C-g at a duration sub-prompt still just loops back to the task
picker either way (see below), so this only changes what a *second*,
top-level C-g does.

PRESELECT-MARKER, when non-nil, skips the interactive picker on the
first iteration of the loop and behaves as though that marker had just
been picked -- used by `cl::agenda-resume-task' to jump straight to the
duration prompt for the interrupted task itself, the same fast path
`cl::agenda-new-session' offers for a task at point.  Only consulted
once: a C-g out of the resulting duration prompt loops back to the
ordinary interactive picker rather than re-offering the same marker.

Returns a plist (:marker M :keep K :duration D :break-p B), or nil if
ABORT-ON-QUIT fired, where:
  :marker       — task to clock into (a marker), or nil (stay locked, no new session)
  :keep         — minutes of the old session to retain, or \\='all (keep everything)
  :duration     — minutes for the new session, or nil (no new session, stay locked)
  :break-p      — break-filter state in effect when :marker was committed; used
                  to tag a freshly typed title (a new task) with a BREAK property
  :new-position — minutes past BOUNDARY at which the new session actually
                  started; the gap between :keep and :new-position is
                  unaccounted dead time, credited to neither task
  :pre-elapsed  — minutes of the new session already elapsed before the
                  duration prompt, i.e. how far :new-position is behind now
  :cancel       — non-nil when C-c C-k canceled the old session outright
                  (`org-clock-cancel'; nothing logged) instead of clocking out

Special case: when :marker equals PREV-MARKER and :keep is \\='all, the
old session is resumed for :duration minutes without clocking out --
one unbroken clock entry, nothing logged as having ended.  Reached two
ways: the silent-resume fast path below (time still remaining on the
old timer, no prompt at all), or the duration prompt itself when it
turns out the same task was picked and the whole gap ends up credited
back to it (an empty \"/\", with no backdate) -- since then nothing was
ever dead, there is nothing to split into two entries for.

Any other pick, whether :marker equals PREV-MARKER (a same-task
continue that doesn't cover the whole gap) or not (a switch), goes
through the same duration sub-prompt (`cl::read-task-duration'), which
collects :keep, :new-position, and :pre-elapsed together via a single
\"X\", \"X-N\", or \"X-N/O\" spec: N backdates the new clock-in's start, O
credits part of the gap back to the task just clocked out, and the rest
of the gap (since BOUNDARY) stays dead by default.  This clocks the old
entry out for real and starts a fresh clock-in -- for a same-task pick,
that only happens when some of the gap is left dead or backdated into
the new entry; crediting all of it back collapses into the special case
above instead.

C-g at any sub-prompt (keep-minutes, duration) returns to the task picker.
The function loops until the user commits a fully resolved choice."
  (let (result (break-state (list break-p)) (preselect preselect-marker))
    (while (null result)
      (let* ((keep-all nil)
             (cancel-p nil)
             (marker
              (if preselect
                  (prog1 preselect (setq preselect nil))
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
                                   " (all, C-c C-e keep, C-c C-k cancel): "
                                 " [< all, C-c C-e keep, C-c C-k cancel]: "))))
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
                                        (abort-recursive-edit)))
                          (define-key (current-local-map)
                                      (kbd "C-c C-k")
                                      (lambda ()
                                        (interactive)
                                        (setq cancel-p t)
                                        (abort-recursive-edit))))
                      (cl:read-task nil break-p expand-state break-state))))
                (quit nil)))))
        ;; Protection only applies on the first invocation of the picker
        (setq protect-seconds nil)
        (cond
         ;; ── C-c C-e: keep everything, stay locked ──────────────────────
         (keep-all
          (setq result (list :marker nil :keep 'all :duration nil)))

         ;; ── C-c C-k: cancel the old session outright, stay locked ───────
         (cancel-p
          (setq result (list :marker nil :keep 0 :duration nil :cancel t)))

         ;; ── C-g at picker, ABORT-ON-QUIT: bail out, nothing decided ─────
         ((and (null marker) abort-on-quit)
          (setq result :abort))

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
                                         (format "Minutes of \"%s\" to keep (0–%d) [0]: "
                                                 prev-title max-mins)
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
              ;; Same task or different, the duration prompt is identical.
              (let* ((base (max 0 (round
                                   (/ (float-time
                                       (time-subtract (current-time) boundary))
                                      60))))
                     (spec (cl::read-task-duration title default-mins base)))
                ;; nil spec = C-g at duration prompt → loop back to task picker
                (when spec
                  (pcase-let ((`(,mins ,n ,o) spec))
                    (setq result
                          (if (and same-p (>= o base))
                              ;; Same task, whole gap credited (n is then
                              ;; necessarily 0, since n+o can't exceed
                              ;; base) -- nothing was ever dead, so this
                              ;; stays one unbroken clock entry instead of
                              ;; a real clock-out followed by a fresh
                              ;; clock-in.
                              (list :marker marker :keep 'all
                                    :duration mins
                                    :break-p (car break-state))
                            (list :marker marker
                                  :keep o
                                  :new-position (- base n)
                                  :duration (- mins n)
                                  :pre-elapsed n
                                  :break-p (car break-state)))))))))))))
    (unless (eq result :abort) result)))

(defun cl::interrupt-dispatch (choice prev-marker prev-title boundary)
  "Apply CHOICE, a plist as returned by `cl::interrupt-pick', and clean up.
PREV-MARKER/PREV-TITLE are the interrupted task; BOUNDARY is the
interrupt boundary time value CHOICE's :keep/:new-position are relative
to.  Clears `cl::pending-interrupt' first, since committing any CHOICE
resolves it.  Dispatches:

  Same marker, :keep \\='all — resume: re-arm the session for :duration
                              minutes without clocking out.  Produced
                              either by the silent-resume fast path in
                              `cl::interrupt-pick' (time still remaining,
                              no prompt at all) or by the duration prompt
                              itself when a same-task pick ends up
                              crediting the whole gap back -- either way
                              nothing was ever dead, so this stays one
                              unbroken clock entry.
  :cancel                  — discard the old session outright via
                              `org-clock-cancel' (nothing logged), stay locked.
  :marker nil, :keep K      — clock out at boundary+K (or now if K=\\='all),
                               stay locked.
  Otherwise                — clock out at boundary+K (or now), clock into
                              :marker at boundary+:new-position (or now, if
                              :new-position is nil) for :duration minutes.
                              Any gap between the two is unaccounted dead
                              time.  Covers both a genuinely different task
                              and a same-task continue picked manually.

In every case, one final `message' summarizes what happened."
  (setq cl::pending-interrupt nil)
  (let* ((marker   (plist-get choice :marker))
         (keep     (plist-get choice :keep))
         (duration (plist-get choice :duration))
         (cancel-p (plist-get choice :cancel))
         (resume-p (and marker
                        (cl::markers-equal-p marker prev-marker)
                        duration
                        (eq keep 'all))))
    (cond
     (resume-p
      ;; Resume: same task, no absent time discarded — continue=t
      ;; so planned minutes accumulate correctly.
      (cl::begin-session prev-title
                         (copy-marker prev-marker)
                         duration
                         (or keep 0))
      (message "Resumed \"%s\", +%d min — running until %s"
               prev-title duration
               (format-time-string
                "%H:%M" (time-add (current-time) (seconds-to-time (* duration 60))))))

     (cancel-p
      (cl::org-clock-cancel)
      (message "Canceled \"%s\" — nothing logged" prev-title))

     (t
      ;; Clock out the previous task at the appropriate time.
      (if (eq keep 'all)
          (cl::org-clock-out nil t)
        (cl::org-clock-out nil t
                           (time-add boundary
                                     (seconds-to-time (* keep 60)))))
      (if (and marker duration)
          (let* ((title (if (markerp marker) (cl::heading-at marker) marker))
                 (new-marker (if (markerp marker)
                                 (copy-marker marker)
                               (cl::capture-org-task
                                title (and (plist-get choice :break-p)
                                           '(("BREAK" . "t"))))))
                 (new-position (plist-get choice :new-position))
                 (pre-elapsed  (plist-get choice :pre-elapsed))
                 (start-time (and new-position
                                  (time-add boundary
                                            (seconds-to-time (* new-position 60))))))
            (cl::begin-session title new-marker duration pre-elapsed start-time)
            (message "Clocked out \"%s\" (%s); clocked into \"%s\"%s, %d min — until %s"
                     prev-title
                     (if (eq keep 'all) "kept all" (format "kept %d min" (or keep 0)))
                     title
                     (if (and pre-elapsed (> pre-elapsed 0))
                         (format " (started %d min ago)" pre-elapsed)
                       "")
                     duration
                     (format-time-string
                      "%H:%M"
                      (time-add (or start-time (current-time))
                                (seconds-to-time (* duration 60))))))
        (message "Clocked out \"%s\" (%s); staying locked"
                 prev-title
                 (if (eq keep 'all) "kept all" (format "kept %d min" (or keep 0)))))))))

(defun cl::interrupt-resolve (kind-label boundary &optional abort-on-quit preselect-marker)
  "Run the interrupt picker against the still-locked `cl::session' and dispatch.
KIND-LABEL and BOUNDARY describe the interrupt (see `cl::interrupt-pick').
ABORT-ON-QUIT is passed through to `cl::interrupt-pick': non-nil makes a
bare C-g at the top-level task picker a clean no-op instead of forcing a
keep-minutes decision.  Does nothing (stays locked, `cl::pending-interrupt'
untouched) when the picker is aborted.  ABORT-ON-QUIT is also used here to
tell a deliberate, user-initiated resolve (called once the user is already
looking at the lock screen and pressed a key to act on it) apart from a
live interrupt firing out of the blue: only the latter needs
`cl:prompt-protect-seconds' keystroke protection on the picker's first
invocation, so protection is skipped whenever ABORT-ON-QUIT is set.
PRESELECT-MARKER is passed through to `cl::interrupt-pick' to skip the
picker and jump straight to the duration prompt for that marker.
Assumes `cl::session' still holds the interrupted task's marker/title/
break-p, i.e. `cl::end-session' was called with KEEP-STATE t and no
session has begun since."
  (let* ((prev-marker  (cl::session-marker  cl::session))
         (prev-title   (cl::session-title   cl::session))
         (break-p      (cl::session-break-p cl::session))
         (expand-state (list nil))
         (choice       (cl::interrupt-pick
                        kind-label break-p boundary
                        prev-marker prev-title
                        expand-state (unless abort-on-quit cl:prompt-protect-seconds)
                        abort-on-quit preselect-marker)))
    (when choice
      (cl::interrupt-dispatch choice prev-marker prev-title boundary))))

(defun cl::maybe-auto-continue (kind boundary)
  "Silently extend the current session instead of locking, if eligible.
Return non-nil (having already done so) when `cl:auto-continue-max-gap-minutes'
is set, KIND is not \\='expired, and the gap between BOUNDARY and now is at
or under that many minutes; return nil (having done nothing) otherwise,
leaving `cl::interrupt-prompt' to lock and prompt as usual.

On success, the session/idle timers are re-armed via `cl::begin-session'
exactly as `cl::interrupt-pick''s own SILENT-RESUME-P fast path does for
a manual same-task pick with time still remaining -- CONTINUE is passed
as \\='all, not a number, so :planned-minutes grows by only the forward
duration passed, the same as that path, and the org clock itself is
never touched, since it was never stopped to begin with.  When the
gap outlasted the session's own remaining time too (e.g. a sleep longer
than what was left), the forward duration falls back to the gap itself
rounded up to whole minutes, so the session still gets at least that
much time going forward.  A brief message notes what happened."
  (when (and cl:auto-continue-max-gap-minutes
             (not (eq kind 'expired))
             cl::session)
    (let ((gap-minutes (/ (float-time (time-subtract (current-time) boundary)) 60.0)))
      (when (<= gap-minutes cl:auto-continue-max-gap-minutes)
        (let* ((remaining (cl::secs-remaining))
               (fwd-mins  (if (> remaining 0)
                               (round (/ remaining 60))
                             (max 1 (ceiling gap-minutes))))
               (title     (cl::session-title cl::session))
               (marker    (cl::session-marker cl::session)))
          (cl::begin-session title (copy-marker marker) fwd-mins 'all)
          (message "%s — continued automatically (%d min gap credited)"
                   title (ceiling gap-minutes))
          t)))))

(defun cl::interrupt-prompt ()
  "Unified session interrupt handler for idle/sleep/expiry.

Defers until no minibuffer is active.  Determines the earliest boundary
and, unless `cl::maybe-auto-continue' silently handles it (small gap,
see `cl:auto-continue-max-gap-minutes'), cancels timers and locks
(keeping `cl::session' intact so the interrupted task's marker/title/
break-p survive).

With `cl:defer-interrupt-prompt' nil (default), immediately resolves the
interrupt via `cl::interrupt-resolve' -- the classic behavior, prompting
right away and requiring a decision (C-g falls back to a keep-minutes
sub-prompt rather than doing nothing).

With `cl:defer-interrupt-prompt' non-nil, only locks and records the
interrupt in `cl::pending-interrupt'; the prompt itself is deferred until
`org-clock-lock-new-session' (bound to \"t\" on the lock screen) calls
`cl::interrupt-resolve' on it."
  (when (and cl::session (not cl::locked-p))
    (minibuf-ext-when-inactive
     (when (and cl::session (not cl::locked-p))
       (let* ((kbnd     (or (cl::interrupt-boundary)
                            (cons 'expired (current-time))))
              (kind     (car kbnd))
              (boundary (cdr kbnd)))
         (unless (cl::maybe-auto-continue kind boundary)
           (let ((kind-label (pcase kind
                               ('idle    "Idle")
                               ('sleep   "Asleep")
                               ('expired "Expired"))))
             (let ((ts (cl::session-timer-session cl::session))
                   (ti (cl::session-timer-idle    cl::session)))
               (when (timerp ts) (cancel-timer ts))
               (when (timerp ti) (cancel-timer ti)))
             ;; Set before locking (not just for the defer branch) so the
             ;; lock buffer's status line (`cl::lock-status-line') has
             ;; something to read from its very first render, even in the
             ;; immediate-prompt case below where it's normally covered
             ;; right away by the prompt.
             (setq cl::pending-interrupt (cons kind-label boundary))
             (cl::end-session t)
             (if cl:defer-interrupt-prompt
                 (message "%s since %s — locked; %s to resolve \"%s\""
                          kind-label
                          (format-time-string "%H:%M" boundary)
                          (substitute-command-keys "\\[org-clock-lock-new-session]")
                          (cl::session-title cl::session))
               (cl::interrupt-resolve kind-label boundary)))))))))

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
If still clocked in (task switched), adopt the new clock immediately.

A deferred interrupt (`cl::pending-interrupt') for the task just
clocked out is resolved by this alone: the user clocked out directly
\(e.g. plain `org-clock-out'\), bypassing `org-clock-lock-new-session',
so `cl::pending-interrupt' is cleared here instead of being left stale,
pointing at a task that is not even clocked in any more.  Unless
something new got clocked into in the same breath (handled below via
`cl::adopt-running-clock'), the session is also finalized/logged here,
since the plain `org-clocking-p'/`cl::locked-p' check below would
otherwise skip `cl::end-session' entirely on the grounds that the
screen is already locked.

Does nothing while `cl::inhibit-clock-hooks' is non-nil."
  (unless cl::inhibit-clock-hooks
    (when cl::pending-interrupt
      (setq cl::pending-interrupt nil)
      (unless (org-clocking-p)
        (cl::end-session)))
    (unless
        (if (org-clocking-p)
            (cl::adopt-running-clock t)
          cl::locked-p)
      (cl::end-session))))

;;; Undoing a clock-out

(defconst cl::closed-clock-re
  (concat "^[ \t]*" org-clock-string
          "[ \t]*\\(\\[[^]\n]+\\]\\)--\\(\\[[^]\n]+\\]\\)")
  "Regexp matching a closed CLOCK line; groups 1 and 2 are its timestamps.")

(defun cl::forget-clock-out ()
  "Clear `cl::last-clock-out', releasing its markers."
  (dolist (key '(:hd-marker :clock-marker))
    (when-let* ((m (plist-get cl::last-clock-out key)))
      (set-marker m nil)))
  (setq cl::last-clock-out nil))

(defun cl::record-clock-out ()
  "Remember the clock entry just closed, for `cl:undo-clock-out'.
On `org-clock-out-hook', which runs in the task's buffer with point on
the CLOCK line just closed -- unless org removed it for being zero
length, in which case there is no line to reopen and only the start
time is kept.  Does nothing while `cl::inhibit-clock-hooks' is non-nil."
  (unless cl::inhibit-clock-hooks
    (cl::forget-clock-out)
    (save-excursion
      (let* ((removed (bound-and-true-p org-clock-out-removed-last-clock))
             (line    (and (not removed)
                           (progn (forward-line 0)
                                  (looking-at cl::closed-clock-re))
                           (buffer-substring-no-properties
                            (point) (line-end-position))))
             (start   (if line
                          (org-time-string-to-time (match-string 1))
                        org-clock-start-time))
             (clock   (and line (point-marker)))
             (hd      (progn (org-back-to-heading t) (point-marker))))
        (setq cl::last-clock-out
              (list :hd-marker hd
                    :clock-marker clock
                    :line line
                    :title (org-get-heading t t t t)
                    :start start
                    :end org-clock-out-time
                    :planned (and cl::session
                                  (cl::markers-equal-p
                                   (cl::session-marker cl::session) hd)
                                  (cl::session-planned-minutes cl::session))
                    :break-p (and (org-entry-get hd "BREAK") t)))))))

(defun cl::clock-out-undoable-p (last)
  "Signal a `user-error' unless the clock-out LAST can still be undone.
LAST is a `cl::last-clock-out' plist.  Its task must still exist and
its CLOCK line, if it had one, must still read as it did at clock-out."
  (let ((title (plist-get last :title))
        (hd    (plist-get last :hd-marker))
        (clock (plist-get last :clock-marker)))
    (cond
     ((null last)
      (user-error "No clock-out to undo"))
     (cl::pending-interrupt
      (user-error "Resolve the pending interrupt first (%s)"
                  (substitute-command-keys "\\[org-clock-lock-new-session]")))
     ((not (marker-buffer hd))
      (user-error "Can't undo: the task \"%s\" is gone" title))
     ((and clock
           (not (and (marker-buffer clock)
                     (with-current-buffer (marker-buffer clock)
                       (org-with-wide-buffer
                        (goto-char clock)
                        (equal (buffer-substring-no-properties
                                (point) (line-end-position))
                               (plist-get last :line)))))))
      (user-error "Can't undo: the clock entry of \"%s\" changed since" title)))))

(defun cl::fmt-clock-time (time)
  "Format TIME as HH:MM, prefixed with the weekday when it isn't today."
  (format-time-string
   (if (equal (format-time-string "%F" time) (format-time-string "%F"))
       "%H:%M"
     "%a %H:%M")
   time))

(defun cl:undo-clock-out ()
  "Undo the most recent clock-out, resuming that task's clock entry.
The clocked-out task's CLOCK line is reopened -- it gets clocked in
again from the entry's original start, as though it had never been
clocked out, so the time since the clock-out counts toward it -- and
whatever is clocked in now is canceled via `org-clock-cancel': its
running CLOCK line is deleted and nothing is logged for it.  The
clock-out's own entry in the lock screen's log is dropped too, since
the reopened entry gets logged whole when it finally ends.

Asks for confirmation first, spelling out both, then for the length of
the resumed session (default: what was left of its planned time, if
any worthwhile).  Nothing changes if either prompt is quit.

Only the latest clock-out is remembered, and only until it is undone;
it can't be undone once its CLOCK line was edited, or while an
interrupt is pending (see `org-clock-lock-defer-interrupt-prompt')."
  (interactive)
  (let ((last cl::last-clock-out))
    (cl::clock-out-undoable-p last)
    (let* ((title    (plist-get last :title))
           (start    (plist-get last :start))
           (end      (plist-get last :end))
           (planned  (plist-get last :planned))
           (break-p  (plist-get last :break-p))
           (now      (current-time))
           (gap      (max 0 (round (float-time (time-subtract now end)) 60)))
           (running  (and (org-clocking-p) org-clock-heading))
           (run-mins (and running
                          (max 0 (round (float-time
                                         (time-subtract now org-clock-start-time))
                                        60))))
           (prompt
            (concat
             (format "Undo clock-out of \"%s\"?  Its entry from %s is reopened \
as if never clocked out at %s, crediting it the %d min since.  "
                     title (cl::fmt-clock-time start) (cl::fmt-clock-time end) gap)
             (when running
               (format "The running clock on \"%s\" (since %s, %d min) is \
canceled, nothing kept or logged.  "
                       running (cl::fmt-clock-time org-clock-start-time)
                       run-mins)))))
      (when (y-or-n-p prompt)
        (let* ((elapsed   (round (float-time (time-subtract now start)) 60))
               (remaining (and planned (- planned elapsed)))
               (mins      (cl::read-minutes
                           (format "Resume \"%s\" for" title)
                           (cond
                            ((and remaining
                                  (>= remaining (car cl:session-limits)))
                             remaining)
                            (break-p cl:default-break)
                            (t (or (cl::effort-minutes (plist-get last :hd-marker))
                                   cl:default-duration)))))
               (hd        (copy-marker (plist-get last :hd-marker)))
               (clock     (plist-get last :clock-marker)))
          (let ((cl::inhibit-clock-hooks t))
            (when (org-clocking-p)
              ;; In the clock's own buffer, since `org-clock-cancel-hook'
              ;; runs in whatever buffer is current.
              (with-current-buffer (org-clocking-buffer)
                (org-clock-cancel))))
          (when clock
            (with-current-buffer (marker-buffer clock)
              (org-with-wide-buffer
               (goto-char clock)
               (delete-region (line-beginning-position)
                              (min (point-max) (line-beginning-position 2))))))
          (setq cl::log-entries
                (cl-remove-if (lambda (e) (equal (plist-get e :end) end))
                              cl::log-entries))
          (cl::forget-clock-out)
          (cl::begin-session title hd mins nil start)
          (when (and cl::session planned)
            (setf (cl::session-planned-minutes cl::session) (+ planned mins)))
          (message "Undid clock-out of \"%s\": clocked in since %s, %d more min%s"
                   title (cl::fmt-clock-time start) mins
                   (if running (format "; canceled \"%s\"" running) "")))))))

;;; State transitions

(defun cl::begin-session (title marker minutes &optional continue start-time)
  "Transition to unlocked state for TITLE (at MARKER) for MINUTES.
With CONTINUE non-nil, this is a continuation of the previous session:
:planned-minutes accumulates the additional minutes on top of the
previous planned total.  When CONTINUE is a number it is also added,
representing extra already-elapsed minutes not otherwise reflected in
MINUTES (see the backdated-switch path in `cl::interrupt-prompt').
START-TIME, when non-nil, backdates the clock-in to that time instead
of clocking in now; passed straight through to `org-clock-in'."
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
            (org-with-point-at marker (org-clock-in nil start-time))
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

(defun cl::org-clock-cancel ()
  "Cancel the running clock (nothing logged) and enter locked state.
Mirrors `cl::org-clock-out', but discards the session via
`org-clock-cancel' instead of finalizing it with `org-clock-out'.  Clears
`cl::session' before locking so `cl::end-session' skips
`cl:session-end-hook' and the log entry — nothing happened, so nothing
is recorded."
  (unwind-protect
      (when (org-clocking-p)
        (org-clock-cancel))
    (setq cl::session nil)
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
;; block from it on every full agenda (re)build; `cl::log-collapsed-days'
;; says which days should render collapsed.
;;
;; Collapsing/expanding a single day (`cl::log-toggle-day', bound to TAB)
;; does NOT go through `cl::log-render' again: every day's body lines are
;; always present in the buffer, and collapsing just marks them invisible
;; (`cl::log-invis') in place, flipping the ruler's arrow glyph via the
;; `cl::log-arrow' property.  Nothing is deleted or reinserted, so point
;; never moves, no matter where in the buffer it was.

(defconst cl::log-title-width 36
  "Display columns reserved for the task title in log lines.")

(defconst cl::log-invis 'org-clock-lock-log-day
  "Invisibility spec symbol for collapsed log day-blocks.")

(defun cl::log-fmt-day-label (date)
  "Format DATE (YYYY-MM-DD) as e.g. \"Fri 16 May\"."
  (format-time-string "%a %e %b" (date-to-time (concat date " 00:00:00"))))

;;; Line constructors ──────────────────────────────────────────────────────────

(defun cl::log-make-line (line date &optional body-p)
  "Attach the shared org-clock-lock log text properties to LINE.
DATE stamps the `cl::date' property so `cl::log-toggle-day' knows which
day a line belongs to.  Only the `keymap' property is used (not
`local-map'): a `keymap' property is consulted ahead of the buffer's
local map without replacing it, so TAB is bound here without shadowing
any other binding -- e.g. org-agenda-mode-map's own commands -- while
point is on a log line.
BODY-P, when non-nil, also stamps `cl::log-body' with DATE, marking LINE
as one of that day's body lines (as opposed to its ruler line) so
`cl::log-toggle-day' can find and hide/show it without touching
anything else."
  (add-text-properties 0 (length line)
                       (list 'cl::log-line t 'cl::date date
                             'keymap cl::log-line-map)
                       line)
  (when body-p
    (add-text-properties 0 (length line) (list 'cl::log-body date) line))
  line)

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
                              'face 'shadow))))
    (cl::log-make-line (concat base (or annot "") "\n") date t)))

(defun cl::log-make-gap-line (minutes date)
  "Return a propertized gap indicator line for MINUTES of unaccounted time.
DATE is the date string (YYYY-MM-DD) of the surrounding sessions."
  (let* ((label (format " %d min " minutes))
         (pad   58)
         (left  (max 4 (/ (- pad (length label)) 2)))
         (right (max 4 (- pad (length label) left)))
         (line  (concat "  " (make-string left ?·)
                        label (make-string right ?·) "\n"))
         (line (cl::log-make-line line date t)))
    (add-text-properties 0 (length line)
                         (list 'face 'shadow)
                         line)
    line))

(defun cl::log-make-ruler (label spent planned collapsed-p date)
  "Return a propertized ─── ruler string with LABEL, arrow, and time totals.
LABEL is the centre text (e.g. \"today\" or a formatted day name).
SPENT and PLANNED are minute counts rendered as HH:MM in distinct faces.
COLLAPSED-P controls the ▶/▼ arrow appended to LABEL.
DATE stamps the arrow character with a `cl::log-arrow' property so
`cl::log-toggle-day' can find and swap just that glyph in place.
The returned string carries only face properties besides that — callers
add `cl::log-line', `cl::date', etc. via `cl::log-make-line'."
  (let* ((arrow      (propertize (if collapsed-p "▶" "▼")
                                 'face 'shadow 'cl::log-arrow date))
         (spent-str  (cl::fmt-hh-mm spent))
         (plan-str   (cl::fmt-hh-mm planned))
         (pre        (format " %s " label))
         (post       (format "  %s spent · %s planned " spent-str plan-str))
         (core-len   (+ (length pre) 1 (length post)))
         (pad        62)
         (left       (max 2 (/ (- pad core-len) 2)))
         (right      (max 2 (- pad core-len left))))
    (concat
     (propertize (concat "  " (make-string left ?─)) 'face 'shadow)
     (propertize pre 'face 'shadow)
     arrow
     (propertize post 'face 'shadow)
     (propertize (concat (make-string right ?─) "\n") 'face 'shadow))))

(defun cl::log-make-footer-line (date spent planned &optional collapsed-p)
  "Return a propertized today-total ruler line.
DATE is the date string (YYYY-MM-DD) stored as a text property.
SPENT and PLANNED are minute counts for the day so far.
COLLAPSED-P controls the ▶/▼ arrow shown next to \"today\"."
  (let ((line (cl::log-make-ruler "today" spent planned collapsed-p date)))
    (cl::log-make-line line date)))

(defun cl::log-make-header-line (date spent planned collapsed-p)
  "Return a propertized previous-day ruler line.
DATE is the date string (YYYY-MM-DD), formatted as e.g. \"Fri 16 May\" in the label.
SPENT and PLANNED are minute totals for that day.
COLLAPSED-P controls the ▶/▼ arrow shown next to the day label."
  (let ((line (cl::log-make-ruler (cl::log-fmt-day-label date)
                                  spent planned collapsed-p date)))
    (cl::log-make-line line date)))

;;; Log operations ─────────────────────────────────────────────────────────────

(defun cl::log-render-day (entries date)
  "Render one day's session/gap lines, newest first.
ENTRIES are that DATE's plists from `cl::log-entries', newest first.
The cumulative-on-task annotation is shown once per task, on its most
recent entry, and sums every same-marker entry in ENTRIES; older entries
of the same task carry no annotation.  Gaps are the time between one
entry's start and the next (older) entry's end."
  (let (seen)
    (apply #'concat
           (cl-loop for (e . older) on entries
                    for marker = (plist-get e :marker)
                    for newest-p = (not (cl-find marker seen
                                                 :test #'cl::markers-equal-p))
                    for cumul = (if newest-p
                                    (cl-reduce
                                     #'+ (cons e older) :initial-value 0
                                     :key (lambda (x)
                                            (if (cl::markers-equal-p
                                                 (plist-get x :marker) marker)
                                                (plist-get x :spent) 0)))
                                  (plist-get e :spent))
                    do (when newest-p (push marker seen))
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
                                ""))))))

(defun cl::log-render ()
  "Return the full rendered log section, most recent day first.
Always includes today, even with no sessions logged yet.  Every day's
body lines are always included, even when the day is in
`cl::log-collapsed-days': they're marked invisible (`cl::log-invis')
rather than omitted, so `cl::log-toggle-day' can show/hide a day in
place afterwards without ever needing to rebuild this block."
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
              (collapsed-p (and (member date cl::log-collapsed-days) t))
              (body    (cl::log-render-day entries date)))
         (when (and collapsed-p (> (length body) 0))
           (add-text-properties 0 (length body) (list 'invisible cl::log-invis) body))
         (concat (if (equal date today)
                     (cl::log-make-footer-line date spent planned collapsed-p)
                   (cl::log-make-header-line date spent planned collapsed-p))
                 body)))
     dates "")))

(defun cl::log-toggle-day ()
  "Toggle collapse/expand of the log day-block at point, in place.
Unlike rebuilding via `cl::log-render', this only flips the `invisible'
property on the day's body lines and swaps the ruler's arrow glyph --
no text anywhere in the buffer is deleted or reinserted, so point
never moves, regardless of where it was when TAB was pressed."
  (interactive)
  (when-let* ((date (get-text-property (point) 'cl::date)))
    (let ((collapsing (not (member date cl::log-collapsed-days))))
      (if collapsing
          (push date cl::log-collapsed-days)
        (setq cl::log-collapsed-days (delete date cl::log-collapsed-days)))
      (let ((inhibit-read-only t))
        (save-excursion
          (when-let* ((arrow-pos (text-property-any (point-min) (point-max)
                                                     'cl::log-arrow date)))
            (goto-char arrow-pos)
            (delete-char 1)
            (insert (propertize (if collapsing "▶" "▼")
                                'face 'shadow 'cl::log-arrow date)))
          (when-let* ((start (text-property-any (point-min) (point-max)
                                                 'cl::log-body date))
                      (end   (or (text-property-not-all start (point-max)
                                                         'cl::log-body date)
                                (point-max))))
            (if collapsing
                (put-text-property start end 'invisible cl::log-invis)
              (remove-text-properties start end '(invisible nil)))))))))

(defun cl:agenda-log-block (&optional _match)
  "Org-agenda block showing org-clock-lock's day log of clocked sessions.
Standalone, general-purpose, and independent of `org-clock-lock-mode':
add it to your own `org-agenda-custom-commands' like any other block,
e.g.

  (\"c\" \"My day\" ((agenda \"\") (org-clock-lock-agenda-log-block)))

or call it directly as its own agenda command.  TAB on any log line
toggles that day's block; the binding is a `keymap' text property
local to the log's lines, so it neither shadows TAB anywhere else in
whatever agenda buffer this is embedded in, nor any other binding
\(e.g. org-agenda-mode-map's own commands\) while point is on a log
line -- a `keymap' property is consulted ahead of, not instead of, the
buffer's local map.

The block's header respects `org-agenda-overriding-header' like any
other block, so a series entry can override it via its own settings,
e.g.

  (org-clock-lock-agenda-log-block
   \"\" ((org-agenda-overriding-header \"Sessions\")))"
  (interactive)
  (org-agenda-prepare "Clock log")
  (add-to-invisibility-spec cl::log-invis)
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (let ((s (point)))
      (org-agenda--insert-overriding-header "Clock log:\n")
      (when (> (point) s)
        (add-text-properties s (1- (point)) (list 'face 'org-agenda-structure))
        (org-agenda-mark-header-line s)))
    (insert (cl::log-render)))
  (goto-char (point-min))
  (or org-agenda-multi (org-agenda-fit-window-to-buffer))
  (add-text-properties
   (point-min) (point-max)
   (list 'org-agenda-type 'org-clock-lock-log
         'org-redo-cmd '(org-clock-lock-agenda-log-block)))
  (org-agenda-finalize)
  ;; Unconditional, matching every built-in single-command entry point
  ;; (`org-agenda-list', `org-todo-list', ...): each block in a series
  ;; calls `org-agenda-prepare' itself, which clears `buffer-read-only'
  ;; whenever `org-agenda-multi' is set, so whichever block runs last
  ;; must always restore it or the whole buffer is left editable.
  (setq buffer-read-only t))

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

(defun cl::default-agenda-command ()
  "Default `cl:agenda-command': today's plain `org-agenda-list'."
  (org-agenda-list nil nil 'day))

(defcustom cl:agenda-command #'cl::default-agenda-command
  "Niladic function that builds/displays the agenda shown while locked.
org-clock-lock has no opinion on what the lock screen looks like beyond
that it is an org-agenda buffer: this is called with
`org-agenda-buffer-tmp-name' bound to the lock buffer's name, so any
`org-agenda' entry point works, e.g. a plain `org-agenda-list' (the
default), or `(lambda () (org-agenda nil \"c\"))' to dispatch one of
your own `org-agenda-custom-commands'.  Add
`org-clock-lock-agenda-log-block' and/or `org-agenda-clockreport-mode'
to that custom command yourself if you want the clocked-session log or
a clock report in the lock screen."
  :type 'function)

(defun cl::agenda-redo ()
  "Rebuild the lock-screen agenda from scratch via `cl:agenda-command'.
Bound over the agenda's own `org-agenda-redo'/`org-agenda-redo-all',
which rename the buffer away from `cl::buf' and drop per-buffer agenda
state (e.g. `org-agenda-clockreport-mode') for a plain (non-sticky)
agenda buffer like this one."
  (interactive)
  (cl::refresh-lock-buffer))

(defun cl::lock-status-line ()
  "Return a propertized preamble line describing the current clock status.
Two cases, checked in order:

`cl::pending-interrupt' set -- an interrupt (idle, sleep, or session
expiry) fired but hasn't been resolved yet, routine while
`cl:defer-interrupt-prompt' is non-nil, since that mode leaves the
screen locked without opening the resolving prompt itself; otherwise
only a brief transient before `cl::interrupt-resolve' covers the screen
with that prompt.  Reports the interrupted task, what triggered the
interrupt and when, and that the underlying org clock is still running
behind the lock screen (frozen accounting at the interrupt boundary,
per `cl:defer-interrupt-prompt', but not actually clocked out) until
resolved via `org-clock-lock-new-session' or `cl::agenda-resume-task'.

Otherwise, `org-clocking-p' -- something is clocked in with no
interrupt pending, e.g. because this buffer was visited directly (it's
an ordinary buffer once built, not exclusively the full-frame lock
display) while a session is actively running elsewhere, or a task got
clocked into by some means org-clock-lock itself didn't initiate.
Reports that plainly, via org's own `org-clock-heading' rather than
`cl::session', so it stays accurate even when the latter doesn't
reflect what is actually clocked in.

Otherwise, when a clock-out can be undone (`cl::last-clock-out'), a
reminder of which task and that \"u\" undoes it.

Nil in every other case (nothing to report)."
  (cond
   (cl::pending-interrupt
    (let* ((kind-label (car cl::pending-interrupt))
           (boundary   (cdr cl::pending-interrupt))
           (title      (or (and cl::session (cl::session-title cl::session))
                           "?"))
           (secs       (max 0 (round (float-time
                                      (time-subtract (current-time) boundary))))))
      (propertize
       (format "  🔒 Clocked in: \"%s\" — %s since %s (%d:%02d) — t to resolve, c to resume\n\n"
               title kind-label (format-time-string "%H:%M" boundary)
               (/ secs 60) (% secs 60))
       'face 'org-warning)))
   ((org-clocking-p)
    (propertize
     (format "  ⏱ Clocked in: \"%s\"\n\n" org-clock-heading)
     'face 'org-agenda-clocking))
   (cl::last-clock-out
    (propertize
     (format "  ↶ Clocked out of \"%s\" at %s — u to undo\n\n"
             (plist-get cl::last-clock-out :title)
             (cl::fmt-clock-time (plist-get cl::last-clock-out :end)))
     'face 'shadow))))

(defun cl::agenda-finalize ()
  "Finalized lock buffer."
  (when (equal (buffer-name) cl::buf)
    (when-let* ((status (cl::lock-status-line)))
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-min))
          (insert status))))
    (cl::agenda-lock-minor-mode 1)))

(defun cl::refresh-lock-buffer ()
  "(Re)build the agenda-based lock buffer and return it.
Calls `cl:agenda-command' with the buffer pinned to `cl::buf'.  Both
`org-agenda-buffer-name' and `org-agenda-buffer-tmp-name' are bound:
a single-command function (`org-agenda-list' and friends) reads
`org-agenda-buffer-tmp-name' itself, but a genuine multi-block series
command (`org-agenda-run-series') never does -- its own outer buffer
setup just uses whatever `org-agenda-buffer-name' already is, so that
needs pinning directly too.  `cl::agenda-finalize' then prepends the
org-clock-lock preamble once the agenda content is in."
  (let ((org-agenda-buffer-name cl::buf)
        (org-agenda-buffer-tmp-name cl::buf)
        (org-agenda-window-setup 'current-window)
        (org-agenda-sticky nil))
    (save-window-excursion
      (funcall cl:agenda-command)))
  (get-buffer cl::buf))

(defun cl::ensure-lock-buffer ()
  "Return the lock screen buffer, building it if necessary."
  (or (get-buffer cl::buf) (cl::refresh-lock-buffer)))

(defun cl::show-lock-screen ()
  "Save each lockable frame's window config and show the lock buffer.
Rebuilds the buffer on every call via `cl::refresh-lock-buffer' so it
reflects current data.  Also records the selected window
\(`cl::saved-selection') and tags each frame's current tab (see
`cl::lock-tab-token').

A frame whose configuration is still saved from a lock that
`cl::hide-lock-screen' never undid -- e.g. a failed clock-in in
`cl::begin-session' locking again -- keeps that configuration, rather
than having it replaced by the lock layout it currently shows.  See
`cl::lockable-frame-p' for which frames are considered."
  (let ((frames (cl-remove-if-not #'cl::lockable-frame-p (frame-list))))
    (if cl::saved-frame-wconfs
        (cl::diag "LOCK again, keeping saved configurations of %s"
                  (mapconcat (lambda (e) (format "%S" (car e)))
                             cl::saved-frame-wconfs ", "))
      (let ((w (selected-window)))
        (setq cl::saved-selection (and (not (window-minibuffer-p w))
                                       (memq (window-frame w) frames)
                                       w)
              cl::lock-tab-token (list 'org-clock-lock))))
    (dolist (f frames)
      (unless (assq f cl::saved-frame-wconfs)
        (push (cons f (with-selected-frame f (current-window-configuration)))
              cl::saved-frame-wconfs)
        (cl::tag-current-tab f)))
    (cl::diag "LOCK %s\n  by: %s\n  saved: %s\n%s"
              (cl::diag-state) (cl::diag-callers)
              (cl::diag-window cl::saved-selection) (cl::diag-frames frames))
    (let ((buf (cl::refresh-lock-buffer)))
      (dolist (f frames)
        (with-selected-frame f
          (cl::apply-lock-layout buf))))))

(defun cl::restore-selection (window why)
  "Select WINDOW, and its frame, unless it is already selected.
Does nothing if WINDOW is dead, or on a frame that is no longer
visible.  Returns non-nil if it selected WINDOW.  WHY is a label for the
diagnostics log."
  (when (and (window-live-p window)
             (not (eq window (selected-window)))
             (eq (frame-visible-p (window-frame window)) t))
    (cl::diag "  reselect (%s): %s -> %s" why
              (cl::diag-window (selected-window)) (cl::diag-window window))
    (unless (eq (window-frame window) (selected-frame))
      (select-frame-set-input-focus (window-frame window)))
    (select-window window)
    t))

(defun cl::reassert-selection (window events)
  "Reselect WINDOW if something else got selected since the unlock.
Run from a zero-delay timer set by `cl::hide-lock-screen', i.e. once
the command or timer that unlocked has finished.  EVENTS is
`num-nonmacro-input-events' at unlock time: once any further input has
been read, the selection is the user's to change and is left alone, as
it is while locked again or while a minibuffer is active."
  (when (and (not cl::locked-p)
             (= events num-nonmacro-input-events)
             (zerop (minibuffer-depth))
             (cl::restore-selection window "after unlock")
             cl:debug-window-selection)
    (message "org-clock-lock: selection changed right after unlock; \
restored it (see M-x org-clock-lock-show-diagnostics)")))

(defun cl::hide-lock-screen ()
  "Restore each frame's saved window configuration and selection.
Before restoring a frame, switches it back to the tab that was current
at lock time if another got selected meanwhile (see
`cl::select-locked-tab'), so the configuration goes back into its own
tab.  After restoring all of them, reselects the window selected at
lock time (`cl::saved-selection'), which restoring several frames in
turn doesn't necessarily leave selected, and once more after the
current command in case something else selects another window
meanwhile (see `cl::reassert-selection').

Also drops the lock buffer from every restored window's
`window-prev-buffers'/`window-next-buffers', which the configuration
itself doesn't cover: displaying the lock buffer records it in that
per-window history (`switch-to-buffer''s NORECORD argument suppresses
only the global recently-selected list, not this one), and
`set-window-configuration' records it again as it swaps the real buffer
back in.  Left there, it sits at the head of the history, so
`previous-buffer' in a restored window goes to the lock screen instead
of whatever the window showed before the interrupt."
  (let ((buf (get-buffer cl::buf))
        (expected cl::saved-selection))
    (when cl::saved-frame-wconfs
      (cl::diag "UNLOCK %s\n  by: %s\n  expect: %s"
                (cl::diag-state) (cl::diag-callers) (cl::diag-window expected)))
    (dolist (entry cl::saved-frame-wconfs)
      (when (frame-live-p (car entry))
        (with-selected-frame (car entry)
          (let* ((tab (cl::select-locked-tab (car entry)))
                 (res (condition-case err
                          (set-window-configuration (cdr entry))
                        (error (bury-buffer) err))))
            (cl::diag "  restore %S%s: %S -> %s"
                      (car entry) (if tab (format " (tab %S)" tab) "") res
                      (cl::diag-window (frame-selected-window))))
          (cl::untag-tabs (car entry))
          (when buf
            (walk-windows
             (lambda (w)
               (set-window-prev-buffers
                w (assq-delete-all buf (window-prev-buffers w)))
               (set-window-next-buffers
                w (delq buf (window-next-buffers w))))
             nil (car entry))))))
    (when cl::saved-frame-wconfs
      (cl::restore-selection expected "after restore")
      (cl::diag "  done: %s" (cl::diag-state))
      (cl::diag-start-watch expected)
      (run-at-time 0 nil #'cl::reassert-selection
                   expected num-nonmacro-input-events)))
  (setq cl::saved-frame-wconfs nil
        cl::saved-selection nil
        cl::lock-tab-token nil))

;;; Tabs

(declare-function tab-bar--current-tab-find "tab-bar" (&optional tabs frame))
(declare-function tab-bar--current-tab-index "tab-bar" (&optional tabs frame))
(declare-function tab-bar-select-tab "tab-bar" (&optional tab-number))

(defun cl::tag-current-tab (frame)
  "Tag FRAME's current tab, if it has tabs, with `cl::lock-tab-token'."
  (when-let* ((token cl::lock-tab-token)
              ((fboundp 'tab-bar--current-tab-find))
              (tab (tab-bar--current-tab-find (frame-parameter frame 'tabs))))
    (setf (alist-get 'org-clock-lock (cdr tab)) token)))

(defun cl::untag-tabs (frame)
  "Remove the lock tag from all of FRAME's tabs."
  (dolist (tab (frame-parameter frame 'tabs))
    (when (assq 'org-clock-lock (cdr tab))
      (setcdr tab (assq-delete-all 'org-clock-lock (cdr tab))))))

(defun cl::select-locked-tab (frame)
  "Select FRAME's tab tagged at lock time, if another one is current.
FRAME must be the selected frame.  Return nil when there's nothing to
do (no tabs, or the tagged tab is current), \\='gone when the tagged tab
was closed meanwhile, or (FROM . TO), the tab indices switched between."
  (when-let* ((token cl::lock-tab-token)
              ((fboundp 'tab-bar--current-tab-index))
              (tabs (frame-parameter frame 'tabs)))
    (let ((idx (seq-position tabs token
                             (lambda (tab tok)
                               (eq (alist-get 'org-clock-lock (cdr tab)) tok))))
          (cur (tab-bar--current-tab-index tabs)))
      (cond
       ((null idx) 'gone)
       ((not (eql idx cur))
        (tab-bar-select-tab (1+ idx))
        (cons cur idx))))))

;;; Diagnostics

(defconst cl::diag-buf " *org-clock-lock-diag*"
  "Name of the buffer `cl:debug-window-selection' logs to.")

(defvar cl::diag-watch nil
  "Plist of the selection watch that follows an unlock, or nil.
Keys: :window, the window expected to stay selected; :until, the
`float-time' at which to stop; :commands, how many more commands to
log; :timer, the timer that stops it.")

(defun cl::diag (fmt &rest args)
  "Log (format FMT ARGS) with a timestamp, if `cl:debug-window-selection'."
  (when cl:debug-window-selection
    (with-current-buffer (get-buffer-create cl::diag-buf)
      (save-excursion
        (goto-char (point-max))
        (insert (format-time-string "%F %T.%3N ") (apply #'format fmt args) "\n")
        (when (> (buffer-size) 500000)
          (goto-char (/ (buffer-size) 2))
          (delete-region (point-min) (line-beginning-position 2)))))))

(defun cl::diag-window (window)
  "Describe WINDOW, with its frame, for the diagnostics log."
  (cond
   ((not (windowp window)) (format "%S" window))
   ((window-live-p window)
    (format "%S in %S" window (window-frame window)))
   (t (format "%S (dead)" window))))

(defun cl::diag-state ()
  "Describe the current selection and command for the diagnostics log."
  (format "sel=%s cmd=%S ev=%S mb-depth=%d"
          (cl::diag-window (selected-window))
          this-command last-input-event (minibuffer-depth)))

(defun cl::diag-frames (frames)
  "Describe each of FRAMES, one per line, for the diagnostics log."
  (mapconcat
   (lambda (f)
     (format "  %S vis=%S focus=%S tab=%S sel=%S"
             f (frame-visible-p f) (frame-focus-state f)
             (and (fboundp 'tab-bar--current-tab-index)
                  (frame-parameter f 'tabs)
                  (tab-bar--current-tab-index (frame-parameter f 'tabs)))
             (frame-selected-window f)))
   frames "\n"))

(defun cl::diag-callers ()
  "Return the functions on the call stack, innermost first, as a string."
  (let (names)
    (mapbacktrace
     (lambda (evald fun _args _flags)
       (when evald
         (let ((name (if (symbolp fun) (symbol-name fun) "<lambda>")))
           (unless (or (string-prefix-p "org-clock-lock--diag" name)
                       (member name '("apply" "funcall" "mapbacktrace")))
             (push name names))))))
    (string-join (seq-take (nreverse names) 25) " < ")))

(defun cl::diag-watching-p ()
  "Non-nil while the post-unlock selection watch is on; stop it once due."
  (when cl::diag-watch
    (or (< (float-time) (plist-get cl::diag-watch :until))
        (progn (cl::diag-stop-watch) nil))))

(defun cl::diag-start-watch (window)
  "Log selection changes for a while after an unlock expecting WINDOW.
See `cl:diag-watch-seconds'."
  (when cl:debug-window-selection
    (cl::diag-stop-watch)
    (setq cl::diag-watch
          (list :window window
                :until (+ (float-time) cl:diag-watch-seconds)
                :commands 3
                :timer (run-at-time cl:diag-watch-seconds nil
                                    #'cl::diag-stop-watch)))
    (add-hook 'window-selection-change-functions #'cl::diag-on-selection-change)
    (add-hook 'post-command-hook #'cl::diag-on-post-command)
    (advice-add 'select-window :before #'cl::diag-on-select-window)
    (advice-add 'select-frame :before #'cl::diag-on-select-frame)))

(defun cl::diag-stop-watch ()
  "Stop the post-unlock selection watch."
  (when-let* ((timer (plist-get cl::diag-watch :timer)))
    (cancel-timer timer))
  (when cl::diag-watch
    (cl::diag "  watch over: %s" (cl::diag-state)))
  (setq cl::diag-watch nil)
  (remove-hook 'window-selection-change-functions #'cl::diag-on-selection-change)
  (remove-hook 'post-command-hook #'cl::diag-on-post-command)
  (advice-remove 'select-window #'cl::diag-on-select-window)
  (advice-remove 'select-frame #'cl::diag-on-select-frame))

(defun cl::diag-on-select-window (window &optional norecord)
  "Log a recorded `select-window' of WINDOW during the watch, with callers.
NORECORD selections are left out: `with-selected-window' and friends
make them all the time and undo them straight after."
  (when (and (not norecord)
             (not (eq window (selected-window)))
             (cl::diag-watching-p))
    (cl::diag "  select-window %s (from %s)\n    by: %s"
              (cl::diag-window window) (cl::diag-window (selected-window))
              (cl::diag-callers))))

(defun cl::diag-on-select-frame (frame &optional norecord)
  "Log a recorded `select-frame' of FRAME during the watch, with callers."
  (when (and (not norecord)
             (not (eq frame (selected-frame)))
             (cl::diag-watching-p))
    (cl::diag "  select-frame %S (from %S)\n    by: %s"
              frame (selected-frame) (cl::diag-callers))))

(defun cl::diag-on-selection-change (frame)
  "Log a change of selected window reported for FRAME during the watch.
On `window-selection-change-functions', which reports every change,
including those made from C (frame switches, mouse clicks,
`set-window-configuration'), once redisplay notices it."
  (when (cl::diag-watching-p)
    (cl::diag "  selection changed (%S): %s%s cmd=%S ev=%S"
              frame (cl::diag-window (selected-window))
              (if (eq (selected-window) (plist-get cl::diag-watch :window))
                  "" " [NOT the expected window]")
              this-command last-input-event)))

(defun cl::diag-on-post-command ()
  "Log the first few commands after an unlock, then end the watch."
  (when (cl::diag-watching-p)
    (cl::diag "  after command %S: %s" this-command
              (cl::diag-window (selected-window)))
    (when (<= (cl-decf (plist-get cl::diag-watch :commands)) 0)
      (cl::diag-stop-watch))))

(defun cl:show-diagnostics ()
  "Show the log kept while `org-clock-lock-debug-window-selection' is on."
  (interactive)
  (let ((buf (get-buffer-create cl::diag-buf)))
    (with-current-buffer buf (goto-char (point-max)))
    (pop-to-buffer buf)))

;;; Header line

(defvar cl::original-header nil)

(defconst cl::header-format
  '(:eval (string-join (cl:ui-status-strings) " "))
  "The `header-line-format' installed while a session runs.")

(defun cl::install-header ()
  (when cl:show-header
    ;; Also called for a session begun while another's header is up, so
    ;; don't mistake that header for the original one.
    (unless (equal (default-value 'header-line-format) cl::header-format)
      (setq cl::original-header (default-value 'header-line-format)))
    (setq-default header-line-format cl::header-format)))

(defun cl::remove-header ()
  (when cl:show-header
    (setq-default header-line-format cl::original-header)))

;;; Minor mode

;;;###autoload
(define-minor-mode cl:mode
  "Block Emacs until you choose an org task, then protect your focus.

LOCKED   Full-frame lock screen: an org-agenda buffer, built by
         `cl:agenda-command' (customize it to add
         `org-clock-lock-agenda-log-block' or a clock report).
         `cl:locked-map' blocks navigation and buffer commands;
         \"t\" picks a task, \"c\" resumes a pending interrupted task
         directly, \"u\" undoes the last clock-out.

UNLOCKED Normal Emacs with optional header-line countdown.
         Break tasks (BREAK property) skip idle detection.

Session end
  Timer fires  — interrupt prompt over the lock screen.  Pick the same
                 task to resume, a different task to clock into (previous
                 task ends at the interrupt boundary), C-g to clock out
                 now, or C-c C-e to keep all time and clock out now.
  C-c f d      — org-clock-out; hook transitions to locked.
  C-c f t      — switch task; C-g keeps the current clock.
  C-c f u      — undo the last clock-out: reopen that task's clock
                 entry, canceling whatever is clocked in now.
  Idle/sleep   — same interrupt prompt, with the idle or sleep start as
                 boundary.  Call `cl:on-sleep' from a system-sleep hook
                 for a precise boundary.

With `cl:defer-interrupt-prompt' non-nil, an interrupt only locks the
screen instead of also opening the prompt, showing a status line with the
old task, why it was interrupted, and since when; \"t\" then resolves it
(same prompt, covering the old task's fate and the new one), \"c\" resumes
the old task directly, and a bare C-g at the picker is a clean no-op
instead of forcing a decision.

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
        (add-hook 'org-clock-out-hook #'cl::record-clock-out -10)
        (add-hook 'tab-bar-tab-post-select-functions #'cl::on-tab-select)
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
    (remove-hook 'org-clock-out-hook #'cl::record-clock-out)
    (remove-hook 'tab-bar-tab-post-select-functions #'cl::on-tab-select)
    (remove-hook 'org-clock-cancel-hook #'cl::on-clock-out)
    (remove-hook 'org-agenda-finalize-hook #'cl::agenda-finalize)
    (cl::cancel-timers)
    (cl::hide-lock-screen)
    (cl::remove-header)
    (setq cl::locked-p            nil
          cl::saved-frame-wconfs  nil
          cl::session             nil
          cl::pending-interrupt   nil)
    (cl::forget-clock-out)))

(provide 'org-clock-lock)

;; Local Variables:
;; read-symbol-shorthands: (("cl:" . "org-clock-lock-")
;;                          ("cl::" . "org-clock-lock--"))
;; End:
;;; org-clock-lock.el ends here
