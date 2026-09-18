defmodule Roundtable.Agents.Adapter do
  @moduledoc """
  Extension contract for a local coding-agent CLI. Adapters receive worker state,
  normalize JSON events, and use Worker helpers to emit session/output/approval events.
  Adapters are trusted application code, registered in :roundtable, :adapters.
  See docs/ADAPTERS.md for a complete example and protocol lifecycle.
  """
  @callback id() :: String.t()
  @callback label() :: String.t()
  @callback command(map(), String.t()) :: {String.t(), [String.t()]}
  @callback start(map()) :: any()
  @callback handle_event(map(), map()) :: map()
  @callback approve(map(), any(), String.t(), map()) :: any()
  @callback exit_status(non_neg_integer(), map()) :: {String.t(), String.t() | nil}
end
