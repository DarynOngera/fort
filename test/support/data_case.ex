defmodule Fort.DataCase do
  use ExUnit.CaseTemplate

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

    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
