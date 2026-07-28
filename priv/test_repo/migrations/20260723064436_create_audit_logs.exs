defmodule Fort.Repo.Migrations.CreateAuditLogs do
  use Ecto.Migration

  def change do
    create table(:audit_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :inserted_at, :utc_datetime_usec, null: false

      add :actor_id, :string, null: false
      add :actor_type, :string, null: false
      add :actor_name, :string
      add :actor_identifier, :string

      add :subject_id, :string
      add :subject_type, :string
      add :subject_name, :string
      add :subject_reference, :string

      add :action, :string, null: false
      add :scope_type, :string
      add :scope_id, :string
      add :category, :string
      add :description, :string

      add :outcome, :string, null: false

      add :before_data, :map, default: fragment("'{}'::jsonb")
      add :after_data, :map, default: fragment("'{}'::jsonb")
      add :changes, :map, default: fragment("'{}'::jsonb")
      add :metadata, :map, default: fragment("'{}'::jsonb")
    end

    execute(
      "ALTER TABLE audit_logs ADD CONSTRAINT outcome_must_be_success_or_failure CHECK (outcome IN ('success', 'failure'))"
    )

    create index(:audit_logs, :action)
    create index(:audit_logs, :category)
    create index(:audit_logs, :outcome)
    create index(:audit_logs, :inserted_at)
    create index(:audit_logs, [:actor_type, :actor_id])
    create index(:audit_logs, [:subject_type, :subject_id])
  end
end
