defmodule Fort.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    repo = Application.fetch_env!(:fort, :repo)
    :persistent_term.put({:fort, :repo}, repo)
    children = []
    opts = [strategy: :one_for_one, name: Fort.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
