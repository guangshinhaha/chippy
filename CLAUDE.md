# Chippy

shinstack-mode: auto

## Factory mode

Sessions here follow shinstack (the plugin must be installed) like a factory line. Use its skills; this section adds only what they don't say.

- Build an issue: `/shinstack:feature`. PR and review depth by tier: `/shinstack:opening-a-pr`.
- High risk: `/shinstack:blast-radius`, then `/shinstack:interrogate`.
- Independent verifier and merge: `/shinstack:ship`. Merge only with `--match-head-commit <sha>`; if gh refuses, stop and report.
- Several `ready` issues queued: `/shinstack:coordinate` runs them. It still takes them oldest first and one at a time.

Chippy rules:

1. Work only issues labelled `ready`, oldest first, one at a time.
2. Intake gate: if the issue has no testable "Done when" list, comment what's missing and stop.
3. Tier comes from the issue's `risk:none|low|medium|high` label. If it has no `risk:` label, pick a tier, say which and why, and add the label.
4. `risk:none` (docs, typos, copy): no independent verifier. Tests and CI are the gate.
5. For `risk:low` and above, the verifier is a fresh subagent that hasn't seen the build reasoning. Its verdict counts only at the head commit it ran at.
6. No Codex or external review. Claude only.
7. Finish with a comment on the issue: the PR link and one line on what you learned about Chippy. Friction in Chippy goes in a new Chippy issue; friction in shinstack goes to the shinstack repo (router: Friction).
8. Blocked on a product call while Shin is away: use `/shinstack:consult-shin`, log the pick on the issue, keep going. A PR that carries the pick merges on the normal gate for its tier; it does not wait for Shin to review the pick. Merge, deploy, credentials and irreversible actions never go through it.
