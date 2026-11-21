# Which daily surface for the away digest? (#185)

Read from code on `main` at cbaf1ba, 2026-11-21. Nothing built, nothing launched, no user data read. Repo names in the mockups are made up (`repo-a`, `repo-b`).

**Decision: keep A, the menu bar window; build neither B nor C yet. #167 stands as shipped.** The window already exists (`DigestWindow.swift`, menu item "While you were away"), and #168's persisted log already shipped, so the issue's premise ("the digest only exists as the notch rest panel", "the digest does not survive a restart") is out of date. The open question is whether a second surface earns its cost. The usage numbers say not yet: see `docs/decisions/unattended-usage-spike.md` (#183: median approval wait 17 s, 1 of 43 past the 5-minute away threshold, no finish data yet). The recommendation depends on that spike's follow-up.

## What exists today (so each option reuses it, not rebuilds it)

- `AwayTracker.observe` (`AwayDigest.swift`) returns the away start once, on return, after at least 300 s.
- `NotchModel.observeAway` sets `awaySince`/`awayEnd` (persisted via `ActivityLog.saveWindow`), and `awayDigest` is rebuilt by `AwayDigest.build` from terminal asks, finished chips, Recent and (after a restart) `activity.jsonl`.
- `DigestWindowRows.rows(from:)` turns the digest into window rows. It has no field for text beyond repo, worktree, status and age (PDPA #30).
- `ActivityLog` is content-free JSON Lines (`ts`, `status`, `repo`, `worktree`, salted `sid`), 0600, 14 days, 2000 lines, atomic temp-file-and-rename writes.
- `WaitSummary.menuLine` is the existing pattern for a one-line text summary in the menu.
- `scripts/bundle.sh` makes an ad-hoc signed `.app` (`LSUIElement`, bundle id `sg.gov.tech.grl.chippy`).

## Seen state, common to all three

The notch digest is "seen" when the user closes its panel after at least `digestMinDwell` (1 s) (`markDigestSeenIfOpen`), or dismisses it (`dismissAwayDigest`). Both clear `awaySince`/`awayEnd`, so the dot goes and the digest is gone everywhere it is derived from.

As built, **A is read-only: opening or closing the window never marks the notch digest seen** (the controller says so). That is deliberate and right: a window opened to peek should not delete the dot. B and C should follow the same rule. Opening a notification or a file is not evidence the user read the rows; only the notch's own dwell rule is. Rule for all three: **a surface may show the digest, never clear it.**

## A. Menu bar window (shipped, #167)

```
+--------------------------------------------+
| While you were away (3)                    |
|--------------------------------------------|
| ! repo-a / feature-x   asked in terminal 4m|  [Open]
| o repo-b               finished        12m |  [Open]
| o repo-c               finished · ended 1h |
+--------------------------------------------+
```

1. **Reuses:** `DigestWindowController`, `DigestWindowView`, `DigestWindowRows`, `NotchModel.awayDigest`, `model.activate(_:)`. All exist.
2. **Effort:** zero further slices to build. Remaining: the owner's live check on #167 (hands-on).
3. **Privacy:** rows (repo, worktree, status, age) show only in a window the user opens, on their own screen. Risk is shoulder-surfing or a shared screen while it is open. Nothing is written anywhere new. Mitigation: it is opt-in (click the menu item), and rows carry no prompt or reply text.
4. **First test:** a local open counter (one integer per day in `UserDefaults`, aggregates only, no row content), read after about 10 working days: how many days was the window opened, versus how many days `activity.jsonl` had a finish inside an away window.
5. **Slices:** the counter is one small slice, only if the follow-up below needs it.

## B. Local notification on return

```
+------------------------------------------+
| Chippy                              now  |
| While you were away: 2 finished,         |
| 1 needs you                              |
+------------------------------------------+
```

1. **Reuses:** the return event from `AwayTracker.observe` in `NotchModel.observeAway` (the one place that knows a qualifying return), and `AwayDigest.Result` for the counts (`rows` by `status`, plus `hidden`). New: `UserNotifications` (no use anywhere in `Sources/` today), an authorisation request, and a code path that works for the bundled app only.
2. **Effort, in slices:**
   1. Counts only: a pure `AwayDigest.summaryLine(Result) -> String` in ChippyCore with tests (done when: "2 finished, 1 needs you" for given rows, no repo names). No dependency on #168.
   2. Wire `UNUserNotificationCenter`: request authorisation once, post on return, off by default behind a menu toggle (done when: toggling on shows the macOS prompt once, a return posts one notification; check in the bundled app, not `swift run`).
   3. Notification click opens window A (done when: clicking it shows the window and does not mark the digest seen).
3. **Privacy:** the largest surface of the three. A delivered notification sits in Notification Centre history, may show on the lock screen depending on the user's preview setting, and appears on a shared screen or screen recording the moment it arrives, not when the user chooses to look. Mitigation: counts only, never repo names or worktree names, so the worst leak is "something finished". Keep it opt-in and off by default. I did not test how previews behave for an ad-hoc signed app; that needs a hands-on check.
4. **First test:** the counts-only summary as a pure unit test; then dogfood opt-in for a week and ask whether it was read. Not testable by an agent: delivery needs the real app and the user's notification settings.

## C. Once-a-day local file

```
~/Library/Application Support/Chippy/digest-2026-11-21.md

# While you were away, Fri 21 Nov
- repo-a / feature-x: asked in terminal, 14:02
- repo-b: finished, 14:10
- repo-c: finished, 14:30
```

1. **Reuses:** `ActivityLog.events()` and `AwayDigest.build(logged:since:until:)` (built for exactly this: a digest from the log alone), `ChippyPaths.supportDir`, `ActivityLog`'s temp-file-and-rename write, and `WaitSummary.menuLine` as the model for a menu entry.
2. **Effort, in slices:**
   1. A pure `DigestFile.render(Result, date) -> String` with tests (done when: made-up rows give the expected Markdown, no field beyond repo, worktree, status, time).
   2. Write once a day, atomically, 0600, and prune files older than 14 days like `ActivityLog.maxAge` (done when: a second run on the same day rewrites, an old file is removed).
   3. A menu item "Open today's digest" (done when: it opens the file in the default editor).
   Depends on #168, already shipped, and it needs history across days, which the log now keeps.
3. **Privacy:** the file persists on disk. It lands in Time Machine backups of `~/Library/Application Support`. Spotlight indexing of that folder was not checked here, so treat it as unknown. Anyone with the user's account or a backup can read a day-by-day record of which repos had work. Mitigation: 0600, 14-day prune, and the same content-free rows as the log, so it adds a readable day-by-day view of what `activity.jsonl` already holds, not new data.
4. **First test:** the pure renderer as a unit test; then check that the file is written once, with mode 0600. Whether anyone opens it is the open question, and it has no counter unless one is added.

## Comparison

| | A window | B notification | C daily file |
|---|---|---|---|
| Built | yes (#167) | no | no |
| Slices left | 0 | 3 | 3 |
| Pushes to the user | no | yes | no |
| Survives a restart | yes (via #168) | no | yes |
| Privacy risk | low (opt-in, on-screen) | highest (lock screen, history) | medium (persists, backups) |
| Clears the notch dot | never | never | never |

## Not covered

- Whether anyone, including the owner, opens any of these. That is the thing to measure, and it needs days of use.
- Notification preview behaviour for an ad-hoc signed app, Spotlight indexing of Application Support, and Time Machine exclusions: not tested.
- Any surface that leaves the Mac (e-mail, Slack, phone push): out of scope by the issue.

## Recommendation

**None yet, validate first: keep A (#167 stands, closes after the live check); relaunch on current main so `activity.jsonl` accumulates finishes, and after about 10 working days check how often finishes landed inside away windows. Only if they did and the window went unopened, build B's counts-only notification (slice 1 first).**
