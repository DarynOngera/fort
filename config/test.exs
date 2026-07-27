import Config

config :fort, :repo, Fort.TestRepo

config :fort, Fort.TestRepo,
  database: "fort_test",
  username: "ongera",
  socket_dir: "/var/run/postgresql",
  pool: Ecto.Adapters.SQL.Sandbox
