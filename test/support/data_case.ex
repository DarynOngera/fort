defmodule Fort.DataCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Fort.DataCase
    end
  end

  setup tags do
    repo = Application.fetch_env!(:fort, :repo)

    pid = Sandbox.start_owner!(repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
