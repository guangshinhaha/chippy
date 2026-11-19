# Readable T3 session names on notch rows (#146)

Checked 2026-11-19 against three real T3 worktrees on this Mac and the hook code. No T3 API, MCP or credentials used.

**Decision: leave it as repo plus branch (what #139 already ships). No-go on prompt-derived names for now.**

## 1. What the hook already has for a T3 session

| Data | T3 example | Readable? |
|---|---|---|
| `cwd` folder | `~/.t3/worktrees/factory/t3-02cf476a-141e5ca834a2667c` | No: a generated hash. |
| Repo (parent folder, or the `gitdir:` pointer in the worktree) | `factory` | Yes, and #139 already uses it. |
| Branch (`git branch --show-current`) | session 1: none (detached HEAD), session 2: none, session 3: `fix-69` | Only when T3 made a branch. Two of three had none. |
| First prompt (`UserPromptSubmit.prompt`, held as `DoneItem.prompt` / `lastPrompt`) | the user's own words | Yes, but it is content. |
| T3 thread title | not in the hook payload | Unavailable without T3's API. Out of scope. |

## 2. Would repo plus branch tell three sessions apart?

For the three sessions above: no. All three are repo `factory`; two have no branch, so their rows read the same. The label is honest (it is the repo) but cannot separate sibling threads in one repo. The Open-in-T3 button already goes to the exact thread, so a wrong guess costs one click, not a wrong answer.

The first prompt's opening words would separate all three, but see 3.

## 3. PDPA position

Nothing is stored beyond memory today: the prompt lives in `DoneItem` / session state in memory only and is never written to `events.jsonl` (its fields are channel, decision, project, tool, ts, wait_ms). A prompt-derived row name would stay in memory too. The cost is not storage but exposure: rest-panel rows deliberately carry no reply, prompt or command text (#30), because the notch is visible to anyone looking at the screen, and a prompt can name a student, a case or a policy. That rule is why this is a no-go for now.

## 4. Recommendation

- Keep repo plus branch (and the worktree tag only when it is not a hash). Already built in #139.
- No-go on prompt words in row labels. If live use shows people cannot tell sibling T3 threads apart, the cheapest next step is a user-controlled opt-in (off by default, in memory only), filed then with that evidence.
- Not worth a branch-naming workaround: T3 decides whether a worktree gets a branch.
