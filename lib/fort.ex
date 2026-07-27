defmodule Fort do
  @moduledoc """
  Dual-routed audit logging library: persists to PostgreSQL and emits
  structured JSON via `:logger`.

  ## Usage

  Add to your `mix.exs`:

      {:fort, path: "~/projects/fort"}

  Configure the Ecto repo in `config/config.exs`:

      config :fort, :repo, MyApp.Repo

  Then run the migration installer:

      mix fort.install

  See `Fort.Audit` for the main API.
  """
end
