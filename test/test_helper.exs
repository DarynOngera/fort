Fort.TestRepo.start_link()

Ecto.Migrator.run(
  Fort.TestRepo,
  Application.app_dir(:fort_audit, "priv/test_repo/migrations"),
  :up,
  all: true
)

ExUnit.start()
