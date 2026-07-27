import Config

config :fort, :ecto_repos, [Fort.TestRepo]

config :fort, :repo, Fort.TestRepo

hostname = System.get_env("FORT_DB_HOST")
socket_dir = if hostname, do: nil, else: System.get_env("FORT_DB_SOCKET", "/var/run/postgresql")

config :fort, Fort.TestRepo,
  database: System.get_env("FORT_DB_DATABASE", "fort_test"),
  hostname: hostname,
  socket_dir: socket_dir,
  username: System.get_env("FORT_DB_USERNAME", System.get_env("USER", "postgres")),
  password: System.get_env("FORT_DB_PASSWORD"),
  pool: Ecto.Adapters.SQL.Sandbox
