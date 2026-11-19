# Other agent sources feeding the notch (#125)

Desk research 2026-11-19 from vendor docs. Nothing was installed or run: every row is "documented", not "tested here". No project or personal data went into the searches.

**Decision: feasible, but no-go on building now.** The notch is still being proven for one source, and question 5 (who asked for this) has no answer yet. If demand shows up, the order is: confirm Claude Desktop and IDE, then Codex, then Cursor.

## 1. Can each source be read without screen-scraping?

| Source | Mechanism | Events that matter | Answer an approval from outside? |
|---|---|---|---|
| Claude Code CLI (today) | `~/.claude/settings.json` hooks | `PermissionRequest`, `Notification`, `Stop` | Yes |
| Claude Desktop (Code tab), VS Code, JetBrains | Same hooks. The hooks docs say the events fire in the IDE extensions and the Desktop app; VS Code shares `settings.json`; JetBrains runs the `claude` CLI | Same | Same. **Unconfirmed on this Mac for the Desktop Code tab: test one hook there first.** |
| Codex CLI | `hooks.json` (`~/.codex` or `.codex`), JSON on stdin | `PermissionRequest`, `Stop`, `Interrupt`; payload has `session_id`, `cwd`, `tool_name`, `tool_input` | Yes: allow or deny, any deny wins |
| Codex `notify` | A program in `config.toml` | Turn-complete only | No, observe only |
| Cursor | `~/.cursor/hooks.json` | `beforeShellExecution`, `beforeMCPExecution`, `stop` | Yes: allow, deny or ask |
| Gemini CLI | `~/.gemini/settings.json` | `Notification` (permission), `AfterAgent`, `BeforeTool` | No documented allow. Its page says it was replaced by Antigravity CLI on 2026-06-18; Antigravity's hooks were not confirmed |
| Windsurf | `.devin/hooks.v1.json` | `PreToolUse` only | Can block, no needs-input event |

Codex's app-server approval flow is only in third-party notes and needs Chippy to host the Codex process. Not an option.

## 2. Mapping to Chippy's states

Claude, Codex and Cursor each have an approval-point hook (NEEDS YOU) and a stop hook (FINISHED). "Working" comes from tool events on Claude; Codex and Cursor give only coarser signals. Gemini and Windsurf cannot supply NEEDS YOU reliably, so they are out.

## 3. Answer or jump only

Claude: answer, as today. Codex and Cursor: answering is documented, so possible, but each has its own allow/deny payload shape and timeout. Jump-only is the safe first step for any new source (as with Orca and T3 Code).

## 4. Privacy

Same rules. Hooks run locally; payloads stay on the Mac; rows carry no content (#30). Nothing new leaves the machine.

## 5. Who asked?

Unanswered. No MOE user or teacher has asked for this. Shin's own interest is the only evidence. That, not feasibility, is why this is a no-go for now.

## Cost if it ever goes ahead

The host adapter table (#140) is the natural place: a source is a hook installer plus a payload decoder plus a jump. Codex first, about 2-3 days with a spike on a real Codex install. Not scheduled.
