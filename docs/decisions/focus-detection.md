# Focus detection (#95)

Chippy reads `~/Library/DoNotDisturb/DB/Assertions.json` (no public API; needs Full Disk Access).

Parser rule: Focus is on only when a `storeAssertionRecords` entry is a dictionary with a recognised start or expiry
timestamp that is not expired and not starting in the future (keys containing "expir" / "start", Apple reference-date, unix seconds or ms). Empty records
are off. A record with no recognised timestamp is "unknown", never on. Any unexpected shape is "unknown", treated as off (fail open) and logged once via os_log, no content.

Verified: unit tests against synthetic JSON only; macOS 26.7.1 on this machine.
NOT verified: the real file. Reading `~/Library/DoNotDisturb/DB/` returned "Operation not permitted" for the
agent session (no Full Disk Access), so the real key names, expiry key and timestamp unit are from memory of macOS
12 to 15 (`data[].storeAssertionRecords[]`, `assertionStartDateTimestamp`) and unconfirmed. A mode with no recognised timestamp reads as unknown (off); a scheduled Focus that ends without rewriting the file could read as on until
the file updates. Check on a real Mac with Focus on, off and on a timer before relying on it.

Reads are cached for 2s and refreshed off the calling thread; the first event after launch sees "off".

## Policy (advisor-required)

- Focus-quiet is OFF by default. Status-menu toggle "Quiet during Focus (best effort, needs Full Disk Access)",
  persisted in UserDefaults (`quiet.focus.enabled`). When off, the file is never read.
- The Full Disk Access hint shows only when the toggle is on and Focus is unreadable.
- Lock-quiet stays on by default. Lock is re-read live from `CGSessionCopyCurrentDictionary()`
  (`CGSSessionScreenIsLocked`, `kCGSSessionOnConsoleKey`) inside `silenceState()`, never latched from distributed
  notifications, so a missed unlock cannot leave Chippy quiet. Wake and session-active drop the cached Focus reading.

Manual proof still needed: with Full Disk Access, log readings with Focus on, off and on a timer; then lock, sleep,
wake, unlock and confirm a hook request pops and sounds.
