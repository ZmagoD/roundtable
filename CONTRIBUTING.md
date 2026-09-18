# Contributing

Roundtable keeps coordination separate from provider implementations and clients.
Changes should preserve durable delivery, per-participant session isolation,
and explicit permission handling.

- Use `mix setup`, then `mix phx.server` for development.
- Run `mix test`, `mix format --check-formatted`, and `mix compile --warnings-as-errors`.
- Put provider-specific logic under `lib/roundtable/agents/`; implement the adapter
  behaviour and add protocol fixture tests. See `docs/ADAPTERS.md`.
- Keep credentials and local transcripts out of code, fixtures, screenshots, and logs.
- Do not disable provider approval/sandbox settings to make an integration pass.
- For a future TUI, keep business logic in `Roundtable.Chat` and
  `Roundtable.Coordinator`; introduce a versioned, authenticated transport rather
  than coupling the client to database tables.

Before publishing, select a license and add the repository URL and maintainer
contact information. This repository intentionally has no fabricated ownership
or security contact details.
