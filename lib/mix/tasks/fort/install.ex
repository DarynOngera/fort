defmodule Mix.Tasks.Fort.Install do
  @moduledoc false
  @shortdoc "Copies the Fort audit_logs migration into the host app"

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    source_dir = Application.app_dir(:fort, "priv/test_repo/migrations")
    target_dir = target_dir(args)

    File.mkdir_p!(target_dir)

    source_dir
    |> File.ls!()
    |> Enum.each(fn file ->
      source = Path.join(source_dir, file)
      target = Path.join(target_dir, file)

      if File.exists?(target) do
        Mix.shell().info("  * skipping (already exists) #{target}")
      else
        File.cp!(source, target)
        Mix.shell().info("  * copied #{target}")
      end
    end)

    Mix.shell().info("""
    Migration installed to #{target_dir}.

    Next steps:

      1. Configure the Ecto repo in config/config.exs:

           config :fort, :repo, MyApp.Repo

      2. Run the migration:

           mix ecto.migrate

    See https://hex.pm/packages/fort for full documentation.
    """)
  end

  defp target_dir([dir]), do: dir

  defp target_dir(_args) do
    case Application.fetch_env(:fort, :repo) do
      {:ok, repo_module} ->
        repo_name = repo_module |> Module.split() |> List.last() |> Macro.underscore()
        "priv/#{repo_name}/migrations"

      :error ->
        "priv/repo/migrations"
    end
  end
end
