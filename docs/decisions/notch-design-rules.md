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
