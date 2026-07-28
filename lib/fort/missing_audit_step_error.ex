defmodule Fort.MissingAuditStepError do
  @moduledoc """
  Raised by `transact/4` when the `AuditedMulti` has zero audit steps.

  Every transaction must carry at least one audit step added via
  `append_to_multi/3`.
  """

  defexception [:message]

  @impl true
  def exception(_opts) do
    %__MODULE__{
      message:
        "transact/4 called with zero audit steps — every business Multi must call Fort.Audit.append_to_multi/3 at least once"
    }
  end
end
