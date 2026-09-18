# Guides

Task-shaped recipes for Roundtable. The [README](../README.md) is the tour;
this is what to do once you are in.

- [Set up a team that actually divides work](#set-up-a-team-that-actually-divides-work)
- [Write a role that changes behaviour](#write-a-role-that-changes-behaviour)
- [Give the room one brief instead of five](#give-the-room-one-brief-instead-of-five)
- [Reuse people across rooms](#reuse-people-across-rooms)
- [Let an orchestrator run unattended](#let-an-orchestrator-run-unattended)
- [Change a model and have it take effect](#change-a-model-and-have-it-take-effect)
- [Review what the agents did](#review-what-the-agents-did)
- [Work across rooms](#work-across-rooms)
- [Run a model on another machine](#run-a-model-on-another-machine)
- [When something goes wrong](#when-something-goes-wrong)

## Set up a team that actually divides work

A room is one project on one working tree, and everyone in it shares that tree.
The split that works is by *responsibility*, not by chapter of the task:

```
/new-room checkout .
/context Elixir and Phoenix. Tests with every change, mix precommit before anything is done.
/agent architect claude --model opus --tier premium --role "Plan and assign. Split the work, say who does what, never write code yourself."
/agent builder codex --tier economy --role "Implement exactly what architect specifies. Tests with the change."
/agent reviewer claude --model sonnet --tier standard --role "Review diffs for correctness and coverage. Say what is wrong, do not fix it."
```

Then address the one you mean: `@architect a repeated POST charges twice`. Its
reply can mention `@builder`, which starts that turn, and so on for up to four
hops from your message. Everyone sees the whole room; only mentions create work.

Two agents on the same files at the same time will fight. Either keep one writer
and let the others plan and review, or give each writer its own room on its own
Git worktree.

## Write a role that changes behaviour

The role is the standing brief. Every turn that participant takes opens with it,
so it is the strongest lever you have — and it is about *how to work*, not only
what the participant is called:

| Weak | Does something |
| --- | --- |
| "Reviewer" | "Review diffs for correctness and test coverage. Say what is wrong and where; never edit the files yourself." |
| "Backend dev" | "Implement what architect specifies, nothing more. Write the tests with the change. Stop and ask if the spec is ambiguous." |
| "Helper" | "Answer questions about this codebase from the code, not from memory. Quote the file and line." |

Change it whenever you like: the next turn works to the new role and is told the
old one no longer applies. If you want the participant to have no memory of the
old brief at all, use **New session** on its card, or `/reset <agent>`.

## Give the room one brief instead of five

Anything that is true for everyone belongs in the room's brief rather than in
each role, where copies drift apart: the stack, the conventions, what "done"
means, what is off limits.

```
/context Elixir/Phoenix checkout service. Tests with every change. mix precommit
before anything is called done. Never push; the human does that.
```

In the browser it is **Room brief** in the room header. Every turn opens with
the participant's own role *and* this. Where both apply, an agent follows both;
where they genuinely conflict, it is told to say so rather than pick one
silently.

## Reuse people across rooms

**Agent profiles** in the sidebar is the library: provider, model, cost tier,
role and tool approvals, saved under a name. Add one to the room you are in with
the button on its row, or `/hire reviewer` in the terminal client.

A profile is a template. The participant it creates is its own from that moment
— its own provider session, its own queue — so the same `reviewer` profile can
be in three rooms at once without any of them sharing context. To have it twice
in one room, give the second a different name: `/hire reviewer reviewer-api`.

Editing or deleting a profile never reaches back into rooms.

## Let an orchestrator run unattended

Codex and Claude Code stop and ask before each tool use. That is right for a
participant you are watching and wrong for one you set going and leave.

Set **Tool approvals** to *Approve automatically* on its card, `/auto architect
on` in the terminal client, or press **Always allow** on a request that is
already waiting. Its turns then run without stopping, and every granted request
is written to the service log:

```sh
roundtable logs | grep auto-approved
```

The roster marks who is on it. Turn it back off with *Ask me before each tool*
or `/auto <agent> off`. OpenCode and Grok have no interactive approval channel —
they use their own configured permissions and never ask in the first place.

## Change a model and have it take effect

Pick a different model on the participant's card, or `/model ada <id>`
(`/model ada default` hands the choice back to the CLI). `/models <provider>`
lists what that CLI reports; anything it does not list can go in a **Model
preset**.

The change lands immediately: turns already queued move onto the new model, and
the provider session is dropped so the next turn starts a fresh one with the
room history behind it — a resumed session would otherwise carry on with the
model it began on. **Retry** on a failed turn also takes the participant's
current model, which is how you get off a model that just failed.

The exception is a model you chose *for one assignment* (a preset picked on that
message): it stays on that turn and its retries, whatever the default becomes.

## Review what the agents did

- **Terminal** in the room header opens a shell in the room's directory. `nvim
  .`, `lazygit`, `git diff` — it is a real pty, so full-screen programs work.
- In the terminal client, `^T` shows the changes pane for the room's tree and
  `^G` hands the whole terminal to lazygit until you quit it.
- Each reply carries the model and cost tier it was produced with, so an
  expensive turn is visible in the transcript rather than only on the bill.

## Work across rooms

Rooms are teams. One can ask another without joining it:

```
/ask platform/ada does the gateway retry 502s?
/delegate platform/ada add the retry and tell me when it lands
```

The answer is posted back into your room when their turn finishes. Hops are
capped the same way as mentions, so a chain cannot run away.

## Run a model on another machine

Roundtable drives the CLIs you already have, so anything they can reach, it can
reach. For Ollama on another box, point OpenCode at it as a custom provider and
use the resulting model IDs here — no Roundtable configuration, and nothing
about the remote host is stored by Roundtable itself. The
[README](../README.md#a-model-on-your-own-machine) has the worked example.

## When something goes wrong

| What you see | What it means |
| --- | --- |
| `failed  … (HTTP 403)` | the provider refused: a login or licence problem in that CLI, not in Roundtable. Fix it where you log in, then **Retry**. |
| A turn stuck on `queued` | that participant has a turn ahead of it, or four turns are already running across the service. |
| `interrupted` after a restart | the service stopped mid-turn. The partial output is kept; **Retry** starts it again. |
| Nothing happens when you post | no mention, so no work. Unaddressed messages are shared context only. |
| A rename is refused | it has taken a turn, and the room has been addressing it by name. Add a new participant instead. |

`roundtable status` prints the URL and the recent log; `roundtable logs`
follows it. Rooms and history live in one SQLite file under
`~/.local/share/roundtable` — back that up and you have backed up everything.
