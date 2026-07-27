defmodule Fort.Repo.Migrations.AddOutcomeCheckConstraint do
  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE audit_logs ADD CONSTRAINT outcome_must_be_success_or_failure CHECK (outcome IN ('success', 'failure'))"
    )
  end
end
