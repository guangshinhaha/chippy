# Chippy

A chipmunk in the Mac notch that shows what needs you right now. v1: Claude Code approvals, local only.
See PRD in issue #1.

    scripts/bundle.sh      # build build/Chippy.app
    swift test             # unit tests

## Menu bar icon with several displays

The 🐿 menu bar icon is a standard macOS status item. Chippy does not choose which
display's menu bar shows it: macOS places status items, and which bar they appear on
depends on the display setup (the primary display, and "Displays have separate Spaces"
in System Settings > Desktop & Dock) and on whether a display is awake. Chippy has no
setting for it.

If the icon is missing from the notched MacBook's bar:

- Check which display is the primary one (System Settings > Displays > Arrange; the
  white bar marks it). Status items follow the display that owns the menu bar.
- Make sure the MacBook bar has room. macOS hides status items that do not fit beside
  the notch, so quit or remove a few other menu bar icons (hold Cmd and drag to reorder
  or remove).
- The notch panel itself always draws on the display with the notch, whichever bar
  holds the icon.
