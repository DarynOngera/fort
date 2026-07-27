Fort.TestRepo.start_link()
Ecto.Migrator.run(Fort.TestRepo, Application.app_dir(:fort, "priv/repo/migrations"), :up, all: true)

ExUnit.start()
