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

When locked, Emacs shows a full-frame buffer with two action keys:

| Key   | Action                                    |
|-------|-------------------------------------------|
| `t`   | Pick a task and start working             |
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
| Pick the **same task** | Resume: the absent time is counted as work. If enough session time remains the timer re-arms silently; otherwise you are asked for a new duration. |
| Pick a **different task** | The previous task is clocked out at the boundary (absent time is not counted). Enter the new session length and the new task starts immediately. |
| `C-g` | Exclude: prompted for minutes to keep (default 0). The previous task is clocked out at boundary + keep-minutes. Emacs stays locked. |
| `C-c C-e` | Keep all: clock out at the current time (all absent time counted as work). Emacs stays locked. |

When multiple interrupts overlap — for example, the session expires during a
sleep — the earliest boundary is used, so the retroactive clock-out option
always reaches back to when you last actively worked.

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

## Customisation

| Variable | Default | Description |
|----------|---------|-------------|
| `org-clock-lock-default-duration` | 25 | Default session length (minutes) |
| `org-clock-lock-default-break` | 5 | Default break length (minutes) |
| `org-clock-lock-session-limits` | `(2 . 120)` | Min/max session length |
| `org-clock-lock-session-warn-seconds` | 120 | Header urgency threshold |
| `org-clock-lock-idle-warn-seconds` | 300 | Idle detection threshold (`nil` to disable) |
| `org-clock-lock-sleep-detect-seconds` | 10 | Tick gap that signals sleep |
| `org-clock-lock-clock-out-on-sleep` | `nil` | Auto clock-out on sleep without prompting |
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
