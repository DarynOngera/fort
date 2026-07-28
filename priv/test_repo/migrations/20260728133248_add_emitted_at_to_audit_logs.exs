defmodule Fort.Repo.Migrations.AddEmittedAtToAuditLogs do
  use Ecto.Migration

  def change do
    alter table(:audit_logs) do
      add(:emitted_at, :utc_datetime_usec)
    end

    create(
      index(:audit_logs, [:inserted_at],
        where: "emitted_at IS NULL",
        name: :idx_audit_logs_unemitted
      )
    )
  end
end
