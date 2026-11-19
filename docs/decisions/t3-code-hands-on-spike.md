# T3 Code hands-on spike (#128, part of #87)

Verified 2026-11-19 on T3 Code (Beta) from a fresh thread, using the real app. No T3 MCP or RPC used.

**Decision: GO.** Build detection plus an "Open T3 Code" button that opens the exact thread (`t3code://threads/<env>/<thread>`), falling back to activating the app when no thread id is known.

## 1. Do hooks fire? Yes

A fresh T3 thread in the chippy project asked an `AskUserQuestion`. `events.jsonl` went from 32 to 33 rows:

```
{"channel":"notch","decision":"answered","project":".claude","tool":"AskUserQuestion","wait_ms":7773}
```

- The notch showed the question and the answer round-tripped (7.8s).
- `project` was `.claude` because that thread's cwd was `~/.claude`. The label comes from cwd, so it reads `chippy` in a chippy thread.
- A permission-free `Bash` (`date`) logged no row. Chippy only logs prompts.
- A session started before the hook path was fixed did not pick up the fix. Hook config is read at session start, so tell users to start a new thread after changing hooks.

## 2. Bundle id and process chain

- Bundle id: `com.t3tools.t3code` (`/Applications/T3 Code (Beta).app`, from Info.plist). Only the Beta app was installed.
- Chain, child to parent: `chippy-hook` → `zsh` → `claude --output-format stream-json ... --permission-prompt-tool=stdio` → `T3 Code (Beta)` (server process) → `T3 Code (Beta)` (main) → `launchd`.
- Detection can walk the hook's parent chain to a `T3 Code` app, or match the bundle id of the running app.

## 3. Approval race: both prompts show, the notch answer wins

- Claude is launched with `--permission-prompt-tool=stdio`, so T3 renders its own approval dialog.
- When the question fired, the Chippy notch and T3's own dialog both appeared, almost instantly.
- Answering in the notch resolved the question and the session continued. **Fail-open holds**: the hook answer was accepted and nothing blocked.
- Not observed: whether T3's dialog dismissed itself after the notch answer. Unconfirmed; check on the build issue.
- Consequence: Chippy cannot suppress T3's dialog. Users see two prompts and answer either one.

`settingSources` on the current build (server bundle, Claude adapter): `["user", "project", "local"]`. With a custom Claude home (`homePath` set or `CLAUDE_CONFIG_DIR` differing) it is `["project", "local"]`, which drops user-level hooks. Chippy installs its hooks in `~/.claude/settings.json`, so **a custom Claude home in T3 disables the hooks.** Detection should say so.

## 4. Deep links

- URL schemes registered: `t3code` and `t3code-dev` (not `t3://`).
- **A thread link exists: `t3code://threads/<environmentId>/<threadId>`.** The desktop main process maps it to the route `/<env>/<thread>` (`desktop/dist-electron/main.cjs`, around :174165). It accepts the link from `open-url`, second-instance argv and launch args, and the renderer navigates to it. No T3 credentials, MCP or RPC involved.
- `t3code://pair` is the pairing flow. Do not use it.
- **Thread id reaches the hook**: T3 sets `T3CODE_THREAD_ID` in the environment of the `claude` process it spawns. Verified in this thread (`T3CODE_THREAD_ID` matches the thread's own id). `chippy-hook` is a child of `claude`, so it inherits it.
- **Environment id** is the plain file `~/.t3/userdata/environment-id`. Verified: its value equals the environment id in T3's own thread links.
- Mechanism for the button: hook forwards `T3CODE_THREAD_ID` (validate `^[A-Za-z0-9_-]{1,128}$`), Chippy stores it on the session/recent item, and the button does `open t3code://threads/<env>/<thread>`.
- **Live check, confirmed by eye:** `open t3code://threads/<env>/<thread>` from the terminal switched T3 Code (Beta) to the targeted thread (a different, older thread than the one running).

## Panel clarity (found while testing, separate from the go/no-go)

The notch panel is hard to read. Findings from the code (`NotchView.swift`, `NotchModel.swift`):

- The header says "Recent" when no chips show, so the whole panel is titled after its least important section.
- Every Recent row (finished work that needs nothing) carries a full "Open <app>" button, while live Thinking/Working rows have no action. Finished work looks like a call to action.
- The same session can appear twice (Recent and live) because the two lists are never de-duplicated.
- Labels differ between sections, and T3 worktree names (`<branch prefix>-<hash>`) are meaningless to a person.

Proposed order: "Needs you" first (approvals, asks, finished replies that ask something) with the only prominent button; "Working" with a quiet open affordance; a small collapsed "Done" list, de-duplicated against live rows. Header shows a count such as "2 need you · 3 working". Needs its own issue.

## Open items

- Unknown: does T3's own approval dialog dismiss after a notch answer?
- Unknown: does the environment id differ for linked or remote environments?

## Build issue scope

Detection (bundle id / parent chain), an "Open T3 Code" button that opens the exact thread, hook forwards `T3CODE_THREAD_ID`. `risk:low`, about 1-2 days. Handle the custom-home case with a visible note. Do not use `t3code://pair`. Panel clarity goes in a separate issue.

Close #87's T3 line when the build issue is filed.
