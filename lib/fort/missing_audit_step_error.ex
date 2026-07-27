defmodule Fort.MissingAuditStepError do
  defexception [:message]

  @impl true
  def exception(_opts) do
    %__MODULE__{
      message:
        "transact/4 called with zero audit steps — every business Multi must call Fort.Audit.append_to_multi/3 at least once"
    }
  end
end
