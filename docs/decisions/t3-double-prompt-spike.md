# T3 double prompt: T3's dialog and the notch card (#145)

Checked 2026-11-20 by Shin, live, on a T3 thread set to ask before running commands (approval mode). No T3 MCP, RPC or credentials used. Allow and Deny were each tried once, answered from the notch card.

**Decision: leave as is. No-go on any change.** Shin reported both runs "work as expected": T3's own dialog is dismissed after a notch answer, so there is no second click.

## 1. After a notch answer, does T3's dialog close?

**Yes, for both Allow and Deny.** The hook returns the decision to Claude Code, and T3 drops its own dialog because the request is no longer pending. The notch answer wins; fail-open still holds (Chippy not running means T3's dialog is the only prompt). *Go: nothing to build.*

## 2. If it stays, can a hook or setting avoid the double prompt?

Not needed, since it does not stay. *No lever to name.*

## 3. Recommendation

**Leave as is.** The two prompts showing together is a feature (answer in either place), and one answer clears both. Not documented in the README: nothing a user must do.

## Not covered

One Allow and one Deny on one machine, one T3 version. A prompt that Claude Code times out or an answer given in T3 first (the notch card should clear; not exercised here).
