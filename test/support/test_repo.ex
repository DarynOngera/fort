defmodule Fort.TestRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :fort_audit,
    adapter: Ecto.Adapters.Postgres
end
