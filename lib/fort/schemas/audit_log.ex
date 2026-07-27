defmodule Fort.Schemas.AuditLog do
  @moduledoc """
  Append-only audit trail for critical business events.

  No foreign keys — audit records survive entity deletion.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @fields [
    :actor_id,
    :actor_type,
    :actor_name,
    :actor_identifier,
    :subject_id,
    :subject_type,
    :subject_name,
    :subject_reference,
    :action,
    :category,
    :description,
    :outcome,
    :profile_id,
    :organization_id,
    :before_data,
    :after_data,
    :changes,
    :metadata
  ]

  @required_fields [:actor_id, :actor_type, :action, :outcome]

  @allowed_outcomes ~w(success failure)

  @type t :: %__MODULE__{}

  schema "audit_logs" do
    field(:actor_id, :string)
    field(:actor_type, :string)
    field(:actor_name, :string)
    field(:actor_identifier, :string)

    field(:subject_id, :string)
    field(:subject_type, :string)
    field(:subject_name, :string)
    field(:subject_reference, :string)

    field(:action, :string)
    field(:category, :string)
    field(:description, :string)

    field(:outcome, :string)

    field(:profile_id, :string)
    field(:organization_id, :string)

    field(:before_data, :map, default: %{})
    field(:after_data, :map, default: %{})
    field(:changes, :map, default: %{})
    field(:metadata, :map, default: %{})

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:outcome, @allowed_outcomes)
  end
end
