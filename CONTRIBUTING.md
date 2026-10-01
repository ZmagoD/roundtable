# Contributing

Roundtable keeps coordination separate from provider implementations and the browser UI.
Changes should preserve durable delivery, per-participant session isolation,
and explicit permission handling.

- Use `mix setup`, then `mix phx.server` for development.
- Run `mix test`, `mix format --check-formatted`, and `mix compile --warnings-as-errors`.
- Put provider-specific logic under `lib/roundtable/agents/`; implement the adapter
  behaviour and add protocol fixture tests. See `docs/ADAPTERS.md`.
- Keep credentials and local transcripts out of code, fixtures, screenshots, and logs.
- Do not disable provider approval/sandbox settings to make an integration pass.
- Keep browser and agent-tool business rules in `Roundtable.Chat` and
  `Roundtable.Coordinator`; the UI never writes database tables directly.

Before publishing, select a license and add the repository URL and maintainer
contact information. This repository intentionally has no fabricated ownership
or security contact details.
