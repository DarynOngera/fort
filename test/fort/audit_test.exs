defmodule Fort.AuditIntegrationTest do
  use Fort.DataCase

  import ExUnit.CaptureLog

  alias Ecto.Changeset
  alias Ecto.Multi
  alias Fort.Audit
  alias Fort.AuditedMulti
  alias Fort.MissingAuditStepError
  alias Fort.Schemas.AuditLog

  @repo Application.compile_env(:fort, :repo)

  @valid_attrs %{
    actor_id: "123e4567-e89b-12d3-a456-426614174000",
    actor_type: "admin_user",
    action: "settlement.generated",
    outcome: "success"
  }

  describe "new/0 and wrap/1" do
    test "new/0 returns an AuditedMulti wrapping an empty Multi" do
      assert %AuditedMulti{multi: %Multi{}, audit_steps: []} = Audit.new()
    end

    test "wrap/1 wraps an existing Ecto.Multi" do
      multi = Multi.new() |> Multi.run(:ping, fn _repo, _changes -> {:ok, :pong} end)
      assert %AuditedMulti{multi: ^multi, audit_steps: []} = Audit.wrap(multi)
    end
  end

  describe "log/1" do
    test "inserts an audit log with valid attrs" do
      assert {:ok, %AuditLog{} = audit_log} = Audit.log(@valid_attrs)
      assert audit_log.action == "settlement.generated"
      assert audit_log.actor_id == "123e4567-e89b-12d3-a456-426614174000"
      assert audit_log.actor_type == "admin_user"
    end

    test "returns error changeset with missing required fields" do
      assert {:error, %Changeset{} = changeset} = Audit.log(%{})
      assert changeset.errors[:actor_id]
    end

    test "persists audit log to database" do
      assert {:ok, %AuditLog{}} = Audit.log(@valid_attrs)
      assert @repo.aggregate(AuditLog, :count, :id) == 1
    end

    test "emits Logger.info on successful insert" do
      Logger.configure(level: :info)

      log =
        capture_log(fn ->
          Audit.log(@valid_attrs)
        end)

      assert log =~ "settlement.generated"
    after
      Logger.configure(level: :warning)
    end

    test "emits Logger.error on failed insert" do
      log =
        capture_log(fn ->
          Audit.log(%{})
        end)

      assert log =~ "audit_log.persistence_failed"
    end
  end

  describe "transact/4" do
    test "returns {:ok, changes} when multi succeeds" do
      audited =
        Multi.new()
        |> Multi.run(:ping, fn _repo, _changes -> {:ok, :pong} end)
        |> Audit.wrap()
        |> Audit.append_to_multi(:audit, @valid_attrs)

      assert {:ok, %{ping: :pong}} =
               Audit.transact(audited, "test.action", "actor-1", actor_type: "system")
    end

    test "writes failure audit when multi fails" do
      audited =
        Multi.new()
        |> Multi.run(:fail, fn _repo, _changes -> {:error, :oops} end)
        |> Audit.wrap()
        |> Audit.append_to_multi(:audit, @valid_attrs)

      assert {:error, :oops} =
               Audit.transact(audited, "test.action", "actor-1", actor_type: "system")

      assert @repo.aggregate(AuditLog, :count, :id) == 1

      audit_log = @repo.one!(AuditLog)
      assert audit_log.action == "test.action"
      assert audit_log.outcome == "failure"
    end

    test "returns audit_failed error when failure-audit itself fails" do
      audited =
        Multi.new()
        |> Multi.run(:fail, fn _repo, _changes -> {:error, :oops} end)
        |> Audit.wrap()
        |> Audit.append_to_multi(:audit, @valid_attrs)

      assert {:error, {:audit_failed, :oops, _errors}} =
               Audit.transact(audited, "test.action", "actor-1", [])
    end
  end

  describe "append_to_multi/3" do
    test "with static map, inserts audit log when multi succeeds" do
      audited =
        Multi.new()
        |> Multi.run(:ping, fn _repo, _changes -> {:ok, :pong} end)
        |> Audit.wrap()
        |> Audit.append_to_multi(:audit, @valid_attrs)

      assert {:ok, _changes} = @repo.transaction(audited.multi)
      assert @repo.aggregate(AuditLog, :count, :id) == 1
    end

    test "with function, inserts audit log from accumulated changes" do
      audited =
        Multi.new()
        |> Multi.run(:data, fn _repo, _changes -> {:ok, %{user_id: "user-1"}} end)
        |> Audit.wrap()
        |> Audit.append_to_multi(:audit, fn changes ->
          %{
            actor_id: "actor-1",
            actor_type: "system",
            action: "test",
            outcome: "success",
            subject_id: changes.data.user_id
          }
        end)

      assert {:ok, _changes} = @repo.transaction(audited.multi)
      assert @repo.aggregate(AuditLog, :count, :id) == 1
    end

    test "rolls back changes when audit insert fails" do
      audited =
        Multi.new()
        |> Multi.run(:data, fn _repo, _changes -> {:ok, %{value: 42}} end)
        |> Audit.wrap()
        |> Audit.append_to_multi(:audit, %{})

      assert {:error, :audit, _failed_value, _changes} = @repo.transaction(audited.multi)

      assert @repo.aggregate(AuditLog, :count, :id) == 0
    end

    test "increments audit_steps on each call" do
      audited =
        Audit.new()
        |> Audit.append_to_multi(:step1, @valid_attrs)
        |> Audit.append_to_multi(:step2, @valid_attrs)

      assert length(audited.audit_steps) == 2
      assert :step2 in audited.audit_steps
      assert :step1 in audited.audit_steps
    end
  end

  describe "format_error/1 (tested via transact metadata)" do
    defp audited_multi_with_failure(reason) do
      Multi.new()
      |> Multi.run(:fail, fn _repo, _changes -> {:error, reason} end)
      |> Audit.wrap()
      |> Audit.append_to_multi(:audit, @valid_attrs)
    end

    test "formats atom reasons" do
      assert {:error, :oops} =
               Audit.transact(
                 audited_multi_with_failure(:oops),
                 "test.action",
                 "actor-1",
                 actor_type: "system"
               )

      audit_log = @repo.one!(AuditLog)
      assert audit_log.metadata["error"] == "oops"
    end

    test "formats tuple reasons" do
      assert {:error, {:validation, "bad"}} =
               Audit.transact(
                 audited_multi_with_failure({:validation, "bad"}),
                 "test.action",
                 "actor-1",
                 actor_type: "system"
               )

      audit_log = @repo.one!(AuditLog)
      assert audit_log.metadata["error"] == ~s[{:validation, "bad"}]
    end

    test "preserves existing metadata from opts" do
      assert {:error, :oops} =
               Audit.transact(
                 audited_multi_with_failure(:oops),
                 "test.action",
                 "actor-1",
                 actor_type: "system",
                 metadata: %{source: "test"}
               )

      audit_log = @repo.one!(AuditLog)
      assert audit_log.metadata["source"] == "test"
      assert audit_log.metadata["error"] == "oops"
    end
  end

  describe "guardrails" do
    test "bare Ecto.Multi handed to transact raises FunctionClauseError" do
      multi = Multi.new() |> Multi.run(:ping, fn _repo, _changes -> {:ok, :pong} end)

      assert_raise FunctionClauseError, fn ->
        Audit.transact(multi, "test.action", "actor-1")
      end
    end

    test "AuditedMulti with zero audit steps raises MissingAuditStepError" do
      audited = Audit.wrap(Multi.new())

      assert_raise MissingAuditStepError, fn ->
        Audit.transact(audited, "test.action", "actor-1")
      end
    end

    test "atomicity: invalid audit changeset rolls back business step" do
      audited =
        Multi.new()
        |> Multi.insert(:scratch, fn _repo ->
          %Fort.Schemas.AuditLog{}
          |> AuditLog.changeset(@valid_attrs)
          |> Ecto.Changeset.apply_action!(:insert)
        end)
        |> Audit.wrap()
        |> Audit.append_to_multi(:audit, %{})

      assert {:error, :audit, _failed, _changes} = @repo.transaction(audited.multi)

      refute @repo.one(AuditLog)
    end
  end
end
