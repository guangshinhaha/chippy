# Notch design rules

Status: accepted. Moved here from issue #30.

Source: web research on Apple's Live Activities HIG and existing Claude Code notch apps. Findings come from marketing pages and search summaries, not hands-on testing. The HIG covers iOS, so it says nothing on Esc or click-outside.

## Rules
1. Decisions stay answerable, information folds away. An approval or question opens with no click and folds after 15s (#86) into a pulsing needs-you badge; it stays pending and answerable, hover pauses the timer, and a card the user opened never folds. A finished chip folds sooner.
2. The glance holds one fact. A second fact goes behind the click.
3. Every card has an action. A finished chip with only Dismiss is not enough.
4. Sensitive text sits behind a tap (PDPA): the glance is neutral by default.
5. Fail open: if Chippy is down, the terminal prompt works as normal.

## Status of the ranked improvements
- Neutral glance by default, reply line behind a setting: done.
- Esc and click-outside fold the detail: done (#29, #36).
- Jump to terminal on the finished chip: done (#35).
- Keyboard shortcuts for Allow/Deny: done (#36).
- Reply from the notch: unproven, not planned.

## Open
- Chip expiry stays at 10 min (HIG suggests 15-30); revisit if it feels short.

## Fold rules (#86)
- Each approval or question has its own 15s timer; hover holds all of them; the TOP-RANKED request decides when the panel folds (#93; rank = approvals before questions, then soonest to timeout), so a later request never restarts another one's timer. A request arriving while folded re-opens the panel and gives every request a fresh timer.
- A request the user opened by hand (click, list jump, picking an answer, a panel already open on arrival) is pinned and never folds. While any pinned request exists the panel stays on it and older due requests wait behind it; the moment it is answered, the panel folds if the oldest is due. Opening the list does not pin: folding pauses while it is open and unpinned cards get a fresh 15s when it closes. Any real interaction with a question card (step, pick, toggle, clear) pins it. A pointer arriving after the deadline but before the fold applied holds it (the timer restarts paused).
- The card, the badge ring and the sweep all use the wait the relay reports (`chippy_wait`, the hook's own `--timeout`); an older relay sends none, and then nothing is dropped on a timeout (only a hang-up ends the request) and no ring or countdown is shown. A request past a reported wait is dropped to the terminal chip even if hovered.

## Needs-you ranking (#93)
- One order for everything: approvals before questions, then closest to timeout within a kind (ties keep arrival order). The list, the badge, the default shown card, the "n of N" index, the fold timer owner, the folded ring and the next card after an answer all use rank first. Rule of thumb: rank first = shown = decides the fold.
- Badge tap opens the rank-first card by hand: it pins that one card (same as a list jump), not the others. A plain click on the folded notch (unfold) pins all, as before.
