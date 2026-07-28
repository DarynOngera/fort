defmodule Fort.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    repo = Application.fetch_env!(:fort_audit, :repo)
    :persistent_term.put({:fort, :repo}, repo)

    label_fields =
      Application.get_env(:fort_audit, :logger_label_fields, [
        :outcome,
        :actor_type,
        :subject_type
      ])
      |> MapSet.new()

    :persistent_term.put({:fort, :logger_label_fields}, label_fields)

    children = []
    opts = [strategy: :one_for_one, name: Fort.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
