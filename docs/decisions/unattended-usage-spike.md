# Unattended usage: do approvals wait while I'm away? (#183)

Checked 2026-11-21 on the owner's Mac from the app's `events.jsonl` (in its Application Support directory) and `pmset -g log`. Read-only, aggregates only. 43 approval events over five SGT calendar days (2026-11-17 to 2026-11-21; the log's own span is four days of UTC timestamps plus the morning of day five). No project names, tool names, inputs or paths are in this note.

**Decision: wait. The numbers do not show unattended use, and four days is too little to say it is absent.** Do not drop #167, do not widen it either. Validate with more days first (below).

## 1. Approvals per day, and on which days

43 approvals in total, on 5 days: 17 (Tue 17 Nov), 7 (Wed), 15 (Thu), 2 (Fri), 2 (Sat, partial day when read). About 10 per working day on the busy days, far fewer once the day is partial. All 43 came from 11 distinct projects.

*Go/no-go input: approvals are frequent enough that a digest has something to show on a busy day, but this says nothing about finishes (see "Not covered").*

## 2. Notch vs terminal, and `none`

| channel | count | share |
|---|---|---|
| notch | 22 | 51% |
| terminal | 21 | 49% |

Decisions: `allow` 11, `answered` 10, `deny` 1, `none` 21. Every `terminal` row is a `none` and every `none` row is `terminal` (21 of 21): the hook gave up or the terminal answered first, so the notch did not take the decision. `answered` (10) is a notch answer given by an earlier "Always" rule.

*Reading:* half of approvals never reach the notch as a decision. That is a bigger share than expected and worth its own look (is the terminal answering first because the user is at the keyboard, or is the hook timing out?). It is not an away signal on its own.

## 3. `wait_ms` distribution

| min | median | p75 | p90 | max |
|---|---|---|---|---|
| 0 s | 17 s | 30 s | 60 s | 905 s (15 min) |

Buckets: under 2 s: 3. 2 to 10 s: 13. 10 to 60 s: 22. 60 to 300 s: 4. Over 300 s: 1. Over 15 min: 1 (the same 905 s event, at the boundary). Over 60 min: 0.

Only one approval in 43 crossed `AwayTracker.defaultThreshold` (300 s). The typical wait is about 17 seconds: the usual picture is someone at the machine.

## 4. Hour of day (Singapore time)

Approvals by SGT hour: 09: 1, 10: 8, 11: 4, 13: 2, 14: 4, 15: 1, 16: 4, 17: 3, 18: 9, 20: 6, 22: 1. They cluster in office hours with a second bump at 18:00 and 20:00 to 21:00, which is an evening session at the machine, not obviously an overnight or lunch gap.

## 5. Do long waits line up with the display being off?

`pmset -g log` has 141 display on/off lines from 2026-11-14, giving 70 off intervals. All 43 approvals fall inside that coverage.

- Approvals created while the display was off: **3 of 43**.
- The one wait over 5 minutes (905 s): display was off when it was created, and off at some point during the wait. So the single long wait did coincide with being away.

*Reading:* the display is off for only 3 approvals, and the single long wait fits "walked away". It is one data point.

## 6. What this implies for #167 and #168, and what it cannot tell

- **#167 (menu bar window):** the premise is that the user leaves and agents wait or finish. One approval in 43 waited past the 5-minute away threshold. With a median wait of 17 s the usual pattern is attended. The digest would have fired about once in four days from approvals alone. **Wait.**
- **#168 (persisted log with finishes):** this is the piece that can answer the question, because it would record finishes, not only approval waits. It does not depend on #167 being built. **Reshape the order: #168's finish events (or a counter) before more digest UI.**

**Not covered:**
- No finish (Stop) events, no "asks you" events, no away periods are in the log. An agent that finished while the user was away leaves no trace. The honest question ("how many finishes happened while I was away") cannot be answered from this file.
- Four to five days, one person, one machine. Not enough to see a weekly pattern.
- Approvals only: a long-running agent that never asks for approval (auto-allowed) is invisible.
- Display off is not the same as away (the user can read a screen that dims, or be away with the display on).
- `terminal` rows have a `none` decision, so their `wait_ms` is when the hook gave up, not how long a human waited.

## Method (aggregates only)

Run locally with `python3 -I` from the scratchpad, never inside the repo. It prints counts and percentiles only; it never prints `project` or `tool` values (the distinct project count is printed as a number). It reads `events.jsonl` (`ts`, `wait_ms`, `channel`, `decision`, `project`), parses display on/off lines out of `pmset -g log`, and counts approvals whose creation time (`ts - wait_ms`) falls inside a display-off interval.

Outline of the script:

```python
ev = [(parse(ts), wait_ms, channel, decision, project) for line in open(events_jsonl)]
print(len(ev), "distinct projects", len({e[4] for e in ev}))      # a count, not the names
print(Counter(e[0].astimezone(SGT).date() for e in ev))            # per day
print(Counter(e[2] for e in ev), Counter(e[3] for e in ev))        # channel, decision
print(sorted(Counter(e[0].astimezone(SGT).hour for e in ev).items()))
w = sorted(e[1] / 1000 for e in ev)                                # min, median, p75, p90, max, over 300/900/3600 s
# pmset -g log | grep "Display is turned" -> off intervals; count approvals created inside one
```

Privacy check: a case-insensitive whole-word grep of this note for every distinct `project` value in the log returned nothing (run locally, list not pasted).

## Recommendation

**Validate first: keep logging for about 10 working days and add finish events to the log via #168 before building more on #167.** Build nothing for #167 until the numbers show agents finishing while the user is away.
