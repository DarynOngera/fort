defmodule Fort.TestRepo do
  use Ecto.Repo,
    otp_app: :fort,
    adapter: Ecto.Adapters.Postgres
end
