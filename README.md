# org-clock-lock

Mandatory task focus for Emacs org-mode. When enabled, Emacs stays locked
behind a full-frame screen until you commit to a task and a session length.
The lock returns when the session ends, when you clock out, or when you go
idle — and you must actively decide what to do with any unaccounted time
before Emacs unlocks again.

## Rationale

`org-clock` tracks time but does nothing to enforce it. It is easy to clock
in and then drift between tasks, ignore the clock when a session ends, or
accumulate idle time silently. `org-clock-lock` makes the clock structural:
you cannot use Emacs without first choosing what you are working on, and
when something interrupts that work — a timer, idle keyboard, or a sleep
cycle — you must account for the gap before continuing.

## Requirements

- Emacs with `org-mode` and `org-clock`
- `minibuf-ext.el` (companion file, provides the live-prompt and completing-read helpers)

## Setup

```elisp
(require 'org-clock-lock)
(org-clock-lock-mode 1)

;; Add any custom bindings to `org-clock-lock-locked-map` which can
;; allow you to "escape" the lock.
```

If a clock is already running when the mode is enabled, you are offered the
option to adopt it as the current session.

## The lock screen

When locked, Emacs shows a full-frame buffer with these action keys:

| Key   | Action                                    |
|-------|-------------------------------------------|
| `t`   | Pick a task and start working             |
| `c`   | Resume the pending interrupted task directly, skipping the picker (see below) |
| `TAB` | Collapse/expand the day log               |

Navigation and buffer commands (`C-x b`, `C-x k`, `find-file`, window
splits, etc.) are blocked while locked.

The lock screen shows a scrollable log of today's sessions with spent and
planned time, gaps between sessions, and a daily total. Past days are
collapsed into a header line and can be expanded with `TAB`. Below the log
is a live org clock report for today.

## Task picker

The task picker (`t` on the lock screen, or triggered automatically) draws
candidates from:

- The heading at point if you are in an org buffer or agenda
- Recent clock history
- Tasks scheduled or due today

Type a number (`1`–`9`) to immediately select one of the first nine
candidates. Press `<` to expand to all not-done agenda tasks. Confirm with
`RET` or select by typing a candidate's numeric key.

After selecting a task you are prompted for the session length in minutes.
The default is `org-clock-lock-default-duration` (25), or the task's
`EFFORT` property if set. The allowed range is `org-clock-lock-session-limits`
(2–120 by default).

## Break tasks

Any org heading with a `BREAK` property is treated as a break task. Break
sessions skip idle detection. Inside the task picker, press `C-c b` to
toggle the break-only filter, restricting candidates to headings with the
`BREAK` property.

## While working

| Key       | Action                                   |
|-----------|------------------------------------------|
| `C-c f d` | Clock out (lock screen returns)          |
| `C-c f t` | Switch to a different task               |

An optional header line shows the task name, a countdown to session end,
and hints for available commands. It turns to `⚠⏱` when fewer than
`org-clock-lock-session-warn-seconds` remain (default 120).

## Session expiry, idle, and sleep

When a session ends — by timer, idle keyboard, or system sleep — the lock
screen is shown and an interrupt prompt appears over it. The prompt header
shows what triggered it (`Expired`, `Idle`, or `Asleep`) and how long ago,
updating live.

The prompt is a task picker. Your choice determines what happens to the
time since the interrupt boundary:

| Action | Result |
|--------|--------|
| Pick the **same task** and it still has time remaining on its own timer | Resume: re-arms silently, no prompt, no time lost, one unbroken clock entry. |
| Pick the **same task** otherwise, and credit the whole gap back (`X/`) | Resume: one unbroken clock entry, same as above — nothing was ever dead, so there's nothing to split. |
| Pick the **same task** and credit only part of the gap, or a **different task** | Enter a duration (see below). The previous task is clocked out at the boundary, crediting back only what you ask for; the picked task then gets a fresh clock-in. |
| `C-g` | Exclude: prompted for minutes to keep (default 0). The previous task is clocked out at boundary + keep-minutes. Emacs stays locked. |
| `C-c C-e` | Keep all: clock out at the current time (all absent time counted as work). Emacs stays locked. |

The duration prompt accepts `X`, `X-N`, or `X-N/O`:

- `X` — total minutes to work on the picked task, counting from its actual start.
- `N` — the picked task actually started `N` minutes ago (backdated clock-in).
- `O` — of the gap since the interrupt, `O` minutes are credited back to the
  task just clocked out instead of staying dead. Omitting `/O` credits
  nothing, the default. A bare trailing `/` credits the maximum possible
  instead — for a same-task pick with no backdate (`X/`), that's the whole
  gap, so no time is lost and the task stays one unbroken clock entry
  instead of a real clock-out followed by a fresh clock-in.

Press `?` at either this or the plain duration prompt (e.g. when picking a
task from the lock screen) to toggle a fuller explanation of the syntax
below the prompt — the minibuffer expands to fit it, similar to how a
completion UI shows its candidate list, and it stays up (press `?` again to
dismiss it) instead of crowding the prompt line itself.

When multiple interrupts overlap — for example, the session expires during a
sleep — the earliest boundary is used, so the retroactive clock-out option
always reaches back to when you last actively worked.

### Auto-continuing small gaps

Set `org-clock-lock-auto-continue-max-gap-minutes` to a number of minutes to
skip locking altogether for a short idle or sleep gap: if the gap is at or
under that threshold, the interrupted task's clock entry is silently
extended and a brief message notes it — no lock screen, no prompt. Session
expiry is never auto-continued this way, no matter how small the resulting
gap, since running out the timer is always a deliberate stopping point.

### Sleep detection

The tick timer (1 second) detects sleep by comparing successive firings. A
gap larger than `org-clock-lock-sleep-detect-seconds` (default 10) triggers
the interrupt prompt with `Asleep` as the kind and the last pre-sleep tick
as the boundary.

For a more precise boundary — for example, exactly when the lid was closed —
call `org-clock-lock-on-sleep` from a system-sleep hook:

```sh
# systemd sleep inhibitor (Linux)
emacsclient --eval "(org-clock-lock-on-sleep (current-time))"
```

```sh
# macOS sleepwatcher (~/.sleep)
emacsclient --eval "(org-clock-lock-on-sleep (current-time))"
```

Set `org-clock-lock-clock-out-on-sleep` to `t` to skip the prompt entirely
and clock out automatically at the sleep boundary.

### Deferring the prompt

Set `org-clock-lock-defer-interrupt-prompt` to `t` to skip straight to the
plain lock screen on interrupt, without opening the prompt. The old clock
keeps running, frozen at the interrupt boundary, until you press `t` (or
otherwise start a new session) — at that point the same prompt appears,
covering both what to do with the interrupted task and which task to start
next, exactly as if the interrupt had just happened. Pressing `c` instead
resumes that same task directly, skipping the picker — a shortcut for the
common case where you just want to keep working on what you were doing.

While an interrupt is pending, the lock screen shows a status line naming
the interrupted task, what triggered the interrupt (`Expired`, `Idle`, or
`Asleep`) and since when, since this is otherwise invisible with the
prompt deferred. The same status line, in a plainer form, also appears
whenever the `*org-clock-lock*` buffer is visited (it's an ordinary buffer
once built, not exclusively the full-frame lock display) while something is
clocked in with no interrupt pending — so it's never silently misleading
about the current clock state.

In this mode, `C-g` at the task picker doesn't force a decision — it's a
clean no-op back to the plain lock screen, nothing clocked out, so you can
leave the interrupt unresolved and come back to it later. (This differs
from the immediate-prompt case above, where `C-g` opens the "minutes to
keep" sub-prompt instead, since a live interrupt has already happened and
needs a resolution.) Because resolving the prompt here is always something
you deliberately asked for — either by pressing `t`/`c` on a screen you're
already looking at — `org-clock-lock-prompt-protect-seconds` keystroke
protection, which exists to stop stray keystrokes from a prompt that
appeared unannounced, is skipped in this mode.

## Customisation

| Variable | Default | Description |
|----------|---------|-------------|
| `org-clock-lock-default-duration` | 25 | Default session length (minutes) |
| `org-clock-lock-default-break` | 5 | Default break length (minutes) |
| `org-clock-lock-session-limits` | `(2 . 120)` | Min/max session length |
| `org-clock-lock-session-warn-seconds` | 120 | Header urgency threshold |
| `org-clock-lock-idle-warn-seconds` | 300 | Idle detection threshold (`nil` to disable) |
| `org-clock-lock-auto-continue-max-gap-minutes` | `nil` | Silently continue instead of locking when an idle/sleep gap is at or under this many minutes |
| `org-clock-lock-sleep-detect-seconds` | 10 | Tick gap that signals sleep |
| `org-clock-lock-clock-out-on-sleep` | `nil` | Auto clock-out on sleep without prompting |
| `org-clock-lock-defer-interrupt-prompt` | `nil` | Lock without prompting on interrupt; resolve later via `t` |
| `org-clock-lock-show-header` | `t` | Show header-line countdown |
| `org-clock-lock-log-progress` | `nil` | Append a LOGBOOK note after each session |
| `org-clock-lock-log-min-gap-minutes` | 10 | Minimum gap shown in the session log |
| `org-clock-lock-clock-report-params` | today's clocktable | Org clocktable parameters for the lock screen report |
| `org-clock-lock-prompt-protect-seconds` | 1 | Keystroke suppression window (seconds) when the interrupt prompt appears; `nil` to disable |
| `org-clock-lock-prompt-protect-max-seconds` | 3 | Hard cap on prompt protection regardless of keystroke resets |
| `org-clock-lock-prompt-protect-min-idle` | 60 | Idle seconds at which prompt protection is bypassed; `nil` to never bypass |

## Hooks

| Hook | When |
|------|------|
| `org-clock-lock-session-start-hook` | After a session starts (clock running, screen unlocked) |
| `org-clock-lock-session-end-hook` | Before a session ends (session data still accessible) |
