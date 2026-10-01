This is a web application written using the Phoenix web framework.

Roundtable is a local-first room where a human and several named coding agents
share one conversation. Elixir 1.20 / OTP 29, Phoenix 1.8 LiveView, Ecto with
SQLite, no external services. A Phoenix LiveView browser UI drives the
coordination core and includes an optional in-room shell.

## How this project is written

Follow the generic Elixir and Phoenix guidance in
[docs/PHOENIX.md](docs/PHOENIX.md), and these project rules, which are where
this codebase deliberately differs or goes further:

- **Tests ship with the change, not after it.** `mix precommit` (compile with
  `--warnings-as-errors`, `deps.unlock --unused`, `format`, `credo --strict`,
  `test`) must pass before anything is called done. The default suite includes
  the browser shell’s PTY bridge tests.
- **`Roundtable.Chat` is the only module that writes to the database.** The
  browser and agent tools go through it, so each rule lives in one place. `Roundtable.Coordinator` owns queue state and nothing durable.
- **Styling is plain CSS in `assets/css/app.css`**, using the custom properties
  defined at the top of that file. The palette is one set of tokens with a
  hue-preserving dark inversion — add a token rather than a literal colour, and
  do not reach for utility classes here. The generic Tailwind guidance is in
  `docs/PHOENIX.md`; it applies to new Phoenix apps, not to this file.
- **Comments say why, not what.** Match the density around you: a comment earns
  its place by recording a decision or a trap, never by narrating the next line.
- **No new dependencies without a reason that survives a sentence.** The
  browser shell uses vendored xterm.js and a small Python PTY bridge.
- **Agent adapters** implement `Roundtable.Agents.Adapter` and normalise the
  provider's own event stream — see `docs/ADAPTERS.md` before adding one. Never
  scrape a terminal, and never hardcode a provider's model list: ask the CLI.
- **Never start a real agent turn to try something out.** Posting a message
  containing `@name` into a running instance spawns the provider CLI and spends
  the human's quota. Seed demo data without mentions.
- **User-facing text is written for a person**, in the same voice as the rest of
  the UI: no shouting, no exclamation marks, and say what happens next.
