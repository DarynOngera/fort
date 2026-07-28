defmodule Mix.Tasks.Fort.Reconcile do
  @moduledoc false
  @shortdoc "Re-emits audit log rows that were never sent to Logger"

  use Mix.Task

  @impl true
  def run(args) do
    batch_size =
      case args do
        [batch] -> String.to_integer(batch)
        _ -> 100
      end

    Mix.Task.run("app.start")

    repo = Application.fetch_env!(:fort_audit, :repo)

    {:ok, count} = Fort.Audit.reconcile(repo, batch_size)
    Mix.shell().info("Reconciled #{count} unemitted audit log(s)")
  end
end
