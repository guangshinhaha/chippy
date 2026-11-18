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
- Each approval or question has its own 15s timer; hover holds all of them; the OLDEST request decides when the panel folds, so a later request never restarts an earlier one's timer (#93 ranking does not change this). A request arriving while folded re-opens the panel and gives every request a fresh timer.
- A request the user opened by hand (click, list jump, picking an answer, a panel already open on arrival) is pinned and never folds. While any pinned request exists the panel stays on it and older due requests wait behind it; the moment it is answered, the panel folds if the oldest is due. Opening the list does not pin: folding pauses while it is open and unpinned cards get a fresh 15s when it closes. Any real interaction with a question card (step, pick, toggle, clear) pins it. A pointer arriving after the deadline but before the fold applied holds it (the timer restarts paused).
- The card, the badge ring and the sweep all use the wait the relay reports (`chippy_wait`, the hook's own `--timeout`); an older relay sends none, and then nothing is dropped on a timeout (only a hang-up ends the request) and no ring or countdown is shown. A request past a reported wait is dropped to the terminal chip even if hovered.

## Needs-you ranking (#93)
- Rank: approvals before questions, then closest to timeout within a kind (ties keep arrival order). Rank decides the list order, which card appears when nothing is shown (first show, after an answer, after a fold), the badge tap and the "n of N" index.
- The visible card is sticky: a newly arrived higher-ranked request never replaces a card already on screen. It waits in the list, and rank picks it only once the shown card is answered.
- The fold timer is not rank-driven: the oldest pending request decides, and a later request never restarts it. The folded ring shows the soonest known deadline among folded requests (a request with no known wait does not hide the others).
- Badge tap opens the rank-first card by hand: it pins that one card (same as a list jump), not the others. A plain click on the folded notch (unfold) pins all, as before.

## Hook timeouts and stale installs (#99)
- Defaults: approval wait 60s (cap 120), question wait 120s (cap 300). Claude's own hook timeout is `max(approval, question) + 10` so our relay always times out first; otherwise Claude kills the hook at its stale limit (30s on old installs) and a question card dies mid-answer.
- A hook is stale when its `timeout` is below that, is missing, or the command has no `--question-timeout`. Chippy checks at launch (one alert) and when the menu opens (a "Repair Claude hook" item). Repair opens Terminal and runs `chippy-hook install`: backup, diff, confirm; nothing is written without a yes.
- Migration keeps custom values. An old default (`--timeout 20` with no question flag) becomes 60; a missing question flag becomes 120; any other `--timeout` or `--question-timeout` is kept.

## Needs you vs finished (#101)
- The list has two sections: NEEDS YOU (approvals, questions, terminal asks; #93 order, not regrouped) and FINISHED (one line each, grouped by repo, newest 3 shown then "+N more"). "Clear all" calls `dismissDone(nil)`, so items move to Recent.
- Terminal rows offer "Jump to terminal" and "Handled". A terminal row expires after 30 minutes (`NotchModel.terminalSeconds`); finished chips stay at 10 minutes.
- Badge counts needs-you only. Finished-only shows a dot, never a count.
- "+N more" is a selectable last row (arrows, Return or click). It expands FINISHED to every row in a scrolling region sized from what NEEDS YOU leaves (at least one row); the row then reads "Show fewer". Selection and scrollTo walk every row. Expansion resets when the list closes (Esc included). FINISHED rows show a one-line outcome (SummaryMarkdown outcome, first line, 60 chars, in memory only) or "finished".
- Height cap 560: FINISHED shrinks first, then NEEDS YOU scrolls. Needs-you rows are never cut.
- Labels are repo + worktree, read from git (pointer file to the common dir) off the main thread and cached; folder name is the fallback. Cards still show the project name.

## Session identity (#89)
- Identity is per resolved repo (`RepoLabel.repo`): a colour (8), a shape (4) and the repo's first letter, never colour alone. Worktrees of one repo share it; the worktree stays the sub-label tag.
- `IdentityBook`: FNV-1a of the repo picks a preferred slot; a taken slot moves to the next free one. The same repo gets the same identity across launches only absent collisions (a collision-moved repo depends on which repos were seen first). Only resolved repos are stored: until `RepoIdentityCache` has resolved the cwd the raw hash slot is used and nothing is remembered, so a mark never flips when the git label arrives. 32 live slots; beyond that the least recently used entry is evicted.
- Glyph: first Character of the uppercased repo name if it is an ASCII letter or digit, else `#`.
- Shown on list rows, Recent rows, every card header, the compact glance and the needs-you badge (rank-first item, only when the badge has 34pt or more). VoiceOver rows say the spoken form ("pink circle G"); the badge says the repo and mark ("next from govapps, teal diamond") and only when the mark is visible.
- Gallery: `Chippy --render-identity out.png`.
