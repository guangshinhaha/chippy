# Focus detection (#95)

Chippy reads `~/Library/DoNotDisturb/DB/Assertions.json` (no public API; needs Full Disk Access).

Parser rule: Focus is on only when a `storeAssertionRecords` entry is a dictionary that is not expired and not
starting in the future (keys containing "expir" / "start", Apple reference-date, unix seconds or ms). Empty records
are off. Any unexpected shape is "unknown", treated as off (fail open) and logged once via os_log, no content.

Verified: unit tests against synthetic JSON only; macOS 26.7.1 on this machine.
NOT verified: the real file. Reading `~/Library/DoNotDisturb/DB/` returned "Operation not permitted" for the
agent session (no Full Disk Access), so the real key names, expiry key and timestamp unit are from memory of macOS
12 to 15 (`data[].storeAssertionRecords[]`, `assertionStartDateTimestamp`) and unconfirmed. A mode switched on
without an expiry reads as active; a scheduled Focus that ends without rewriting the file could read as on until
the file updates. Check on a real Mac with Focus on, off and on a timer before relying on it.

Reads are cached for 2s and refreshed off the calling thread; the first event after launch sees "off".
