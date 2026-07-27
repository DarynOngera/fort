import Config

config :fort, :ecto_repos, [Fort.TestRepo]

import_config "#{config_env()}.exs"
