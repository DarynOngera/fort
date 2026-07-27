defmodule Fort.TestRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :fort,
    adapter: Ecto.Adapters.Postgres
end
