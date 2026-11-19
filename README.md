# Chippy

A chipmunk in the Mac notch that shows what needs you right now. v1: Claude Code approvals, local only.
See PRD in issue #1.

    scripts/bundle.sh      # build build/Chippy.app
    swift test             # unit tests

## T3 Code

Chippy installs its hooks in `~/.claude/settings.json` (`chippy-hook install`). T3 Code reads that file only when it uses the default Claude home. With a custom Claude home in T3 (a home path set in its settings, or `CLAUDE_CONFIG_DIR` pointing elsewhere), T3 reads only the project and local settings, so Chippy's hooks never run and the notch stays silent with no error.

If you use a custom Claude home, add Chippy's hooks to that home's `settings.json`, or to the project's `.claude/settings.json`.

To check: start a T3 thread that asks for an approval and watch for the notch. If nothing appears, the hooks are not being read.
