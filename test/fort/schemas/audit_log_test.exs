defmodule Fort.Schemas.AuditLogTest do
  use ExUnit.Case

  import Ecto.Changeset

  alias Fort.Schemas.AuditLog

  @valid_attrs %{
    actor_id: "123e4567-e89b-12d3-a456-426614174000",
    actor_type: "admin_user",
    action: "settlement.generated",
    outcome: "success"
  }

  defp errors_on(changeset) do
    traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "changeset/2" do
    test "accepts valid attributes" do
      changeset = AuditLog.changeset(%AuditLog{}, @valid_attrs)
      assert changeset.valid?
    end

    test "accepts all optional fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          actor_name: "John Doe",
          actor_identifier: "john@example.com",
          subject_id: "123e4567-e89b-12d3-a456-426614174001",
          subject_type: "settlement",
          subject_name: "BANK-REF-001",
          subject_reference: "BANK-REF-001",
          category: "finance",
          description: "Settlement generated",
          profile_id: "123e4567-e89b-12d3-a456-426614174002",
          organization_id: "123e4567-e89b-12d3-a456-426614174003",
          before_data: %{},
          after_data: %{amount: 1000},
          changes: %{status: "generated"},
          metadata: %{source_ip: "127.0.0.1"}
        })

      changeset = AuditLog.changeset(%AuditLog{}, attrs)
      assert changeset.valid?
      assert get_field(changeset, :actor_name) == "John Doe"
      assert get_field(changeset, :category) == "finance"
      assert get_field(changeset, :after_data) == %{amount: 1000}
    end

    test "requires actor_id" do
      attrs = Map.delete(@valid_attrs, :actor_id)
      changeset = AuditLog.changeset(%AuditLog{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset)[:actor_id]
    end

    test "requires actor_type" do
      attrs = Map.delete(@valid_attrs, :actor_type)
      changeset = AuditLog.changeset(%AuditLog{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset)[:actor_type]
    end

    test "requires action" do
      attrs = Map.delete(@valid_attrs, :action)
      changeset = AuditLog.changeset(%AuditLog{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset)[:action]
    end

    test "requires outcome" do
      attrs = Map.delete(@valid_attrs, :outcome)
      changeset = AuditLog.changeset(%AuditLog{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset)[:outcome]
    end

    test "validates outcome inclusion" do
      attrs = Map.put(@valid_attrs, :outcome, "invalid")
      changeset = AuditLog.changeset(%AuditLog{}, attrs)
      assert "is invalid" in errors_on(changeset)[:outcome]
    end

    test "allows failure outcome" do
      attrs = Map.put(@valid_attrs, :outcome, "failure")
      changeset = AuditLog.changeset(%AuditLog{}, attrs)
      assert changeset.valid?
    end

    test "jsonb fields default to empty maps" do
      changeset = AuditLog.changeset(%AuditLog{}, @valid_attrs)
      assert get_field(changeset, :before_data) == %{}
      assert get_field(changeset, :after_data) == %{}
      assert get_field(changeset, :changes) == %{}
      assert get_field(changeset, :metadata) == %{}
    end

    test "omitting all optional fields is valid" do
      changeset = AuditLog.changeset(%AuditLog{}, @valid_attrs)
      assert changeset.valid?
    end
  end
end
