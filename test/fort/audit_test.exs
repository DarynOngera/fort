defmodule Fort.AuditTest.Schema do
  @moduledoc false

  use Ecto.Schema

  schema "test_fixtures" do
    field(:name, :string)
    field(:email, :string)
    field(:age, :integer)
    field(:ssn, :string, redact: true)
  end
end

defmodule Fort.AuditTest.Address do
  @moduledoc false

  use Ecto.Schema

  embedded_schema do
    field(:street, :string)
    field(:city, :string)
  end
end

defmodule Fort.AuditTest.SchemaWithEmbed do
  @moduledoc false

  use Ecto.Schema

  schema "test_embeds" do
    field(:name, :string)
    embeds_one(:address, Fort.AuditTest.Address)
  end
end

defmodule Fort.AuditTest.StatusStruct do
  defstruct [:value]
end

defmodule Fort.AuditTest.CustomType do
  @moduledoc false

  use Ecto.Type

  def type, do: :string

  def cast(val), do: {:ok, %Fort.AuditTest.StatusStruct{value: to_string(val)}}
  def load(val), do: {:ok, %Fort.AuditTest.StatusStruct{value: val}}
  def dump(%{value: val}), do: {:ok, to_string(val)}
end

defmodule Fort.AuditTest.SchemaWithCustomType do
  @moduledoc false

  use Ecto.Schema

  schema "test_custom_types" do
    field(:name, :string)
    field(:status, Fort.AuditTest.CustomType)
  end
end

defmodule Fort.AuditIntegrationTest do
  use Fort.DataCase

  import ExUnit.CaptureLog

  alias Ecto.Changeset
  alias Ecto.Multi
  alias Fort.Audit
  alias Fort.AuditedMulti
  alias Fort.MissingAuditStepError
  alias Fort.Audit.Emitter
  alias Fort.Schemas.AuditLog

  @repo Application.compile_env(:fort_audit, :repo)

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

  describe "from_changeset/1" do
    alias Fort.AuditTest.Schema

    test "derives before_data, after_data, and changes scoped to schema fields" do
      record = %Schema{name: "Alice", email: "alice@example.com", age: 30, ssn: "hidden"}

      changeset =
        record
        |> Changeset.cast(%{name: "Alice B.", email: "alice@new.org"}, [:name, :email, :age, :ssn])

      result = Audit.from_changeset(changeset)

      assert result.before_data == %{
               id: nil,
               name: "Alice",
               email: "alice@example.com",
               age: 30
             }

      assert result.after_data == %{
               id: nil,
               name: "Alice B.",
               email: "alice@new.org",
               age: 30
             }

      assert result.changes == %{name: "Alice B.", email: "alice@new.org"}
    end

    test "strips redact: true fields from all three maps" do
      record = %Schema{name: "Alice", email: "alice@example.com", age: 30, ssn: "hidden"}

      changeset =
        record
        |> Changeset.cast(%{name: "Alice B."}, [:name, :email, :age, :ssn])

      result = Audit.from_changeset(changeset)

      refute Map.has_key?(result.before_data, :ssn)
      refute Map.has_key?(result.after_data, :ssn)
      refute Map.has_key?(result.changes, :ssn)
    end

    test "parity: before/after match non-redacted original data" do
      original = %Schema{name: "Carol", email: "carol@example.com", age: 35, ssn: "987-65-4321"}

      changeset =
        original
        |> Changeset.cast(%{name: "Carol D.", email: "carol@new.co"}, [:name, :email, :age, :ssn])

      result = Audit.from_changeset(changeset)

      assert result.before_data == %{id: nil, name: "Carol", email: "carol@example.com", age: 35}
      assert result.after_data == %{id: nil, name: "Carol D.", email: "carol@new.co", age: 35}
      assert result.changes == %{name: "Carol D.", email: "carol@new.co"}

      refute Map.has_key?(result.before_data, :ssn)
      refute Map.has_key?(result.after_data, :ssn)
      refute Map.has_key?(result.changes, :ssn)
    end

    # ── Step 6: verified-limitation observations (skipped — reference only) ─

    @tag :skip
    test "VERIFIED: embed struct in from_changeset output lacks Jason.Encoder" do
      record = %Fort.AuditTest.SchemaWithEmbed{name: "test", address: nil}

      changeset =
        record
        |> Changeset.cast(
          %{name: "updated", address: %{street: "123 Main", city: "Springfield"}},
          [:name]
        )
        |> Changeset.cast_embed(:address,
          with: fn _address, params ->
            %Fort.AuditTest.Address{}
            |> Changeset.cast(params, [:street, :city])
          end
        )

      result = Audit.from_changeset(changeset)

      embed_val = result.after_data[:address]
      IO.puts("EMBED VALUE: #{inspect(embed_val)}")
      IO.puts("EMBED VALUE TYPE: #{inspect(embed_val && embed_val.__struct__)}")

      case Jason.encode(result.after_data) do
        {:ok, json} -> IO.puts("EMBED JSON OK: #{json}")
        {:error, err} -> IO.puts("EMBED JSON FAIL: #{inspect(err)}")
      end

      assert true
    end

    @tag :skip
    test "VERIFIED: custom Ecto.Type returning struct without Jason.Encoder" do
      record = %Fort.AuditTest.SchemaWithCustomType{name: "test", status: "active"}

      changeset =
        record
        |> Changeset.cast(%{name: "updated", status: "inactive"}, [:name, :status])

      result = Audit.from_changeset(changeset)

      status_val = result.after_data[:status]
      IO.puts("CUSTOM TYPE VALUE: #{inspect(status_val)}")
      IO.puts("CUSTOM TYPE TYPE: #{inspect(status_val && status_val.__struct__)}")

      case Jason.encode(result.after_data) do
        {:ok, json} -> IO.puts("CUSTOM TYPE JSON OK: #{json}")
        {:error, err} -> IO.puts("CUSTOM TYPE JSON FAIL: #{inspect(err)}")
      end

      assert true
    end
  end

  describe "log/1" do
    test "inserts an audit log with valid attrs" do
      assert {:ok, %AuditLog{} = audit_log} = Audit.log(@valid_attrs)
      assert audit_log.action == "settlement.generated"
      assert audit_log.actor_id == "123e4567-e89b-12d3-a456-426614174000"
      assert audit_log.actor_type == "admin_user"
      assert audit_log.emitted_at != nil
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

    test "transact success emits Logger and stamps emitted_at" do
      Logger.configure(level: :info)

      log =
        capture_log(fn ->
          audited =
            Audit.new()
            |> Audit.append_to_multi(:audit, @valid_attrs)

          assert {:ok, _changes} =
                   Audit.transact(audited, "test.action", "actor-1", actor_type: "system")
        end)

      assert log =~ "settlement.generated"

      audit_log = @repo.one!(AuditLog)
      assert audit_log.emitted_at != nil
    after
      Logger.configure(level: :warning)
    end

    test "ghost log: business rollback after audit step produces no Logger for rolled-back audit" do
      Logger.configure(level: :info)

      log =
        capture_log(fn ->
          audited =
            Multi.new()
            |> Audit.wrap()
            |> Audit.append_to_multi(:audit, @valid_attrs)
            |> then(fn %{multi: multi} = a ->
              %{a | multi: Multi.run(multi, :failer, fn _repo, _changes -> {:error, :ghost} end)}
            end)

          assert {:error, :ghost} =
                   Audit.transact(audited, "test.action", "actor-1", actor_type: "system")
        end)

      # The failure audit was written (log_failure path) — that's expected
      assert @repo.aggregate(AuditLog, :count, :id) == 1
      audit_log = @repo.one!(AuditLog)
      assert audit_log.outcome == "failure"

      # But the success audit's Logger line MUST NOT appear — it was rolled back
      refute log =~ "settlement.generated"
    after
      Logger.configure(level: :warning)
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

  describe "Audit.reconcile/2" do
    test "re-emits unemitted rows and stamps emitted_at" do
      Logger.configure(level: :info)

      attrs = %{
        actor_id: "reconcile-test",
        actor_type: "system",
        action: "reconcile.test",
        outcome: "success"
      }

      {:ok, row1} = %AuditLog{} |> AuditLog.changeset(attrs) |> @repo.insert()
      {:ok, row2} = %AuditLog{} |> AuditLog.changeset(attrs) |> @repo.insert()

      assert row1.emitted_at == nil
      assert row2.emitted_at == nil

      log =
        capture_log(fn ->
          assert {:ok, 2} = Audit.reconcile(@repo, 100)
        end)

      assert log =~ "reconcile.test"
      assert String.count(log, "reconcile.test") == 2

      refute @repo.get!(AuditLog, row1.id).emitted_at == nil
      refute @repo.get!(AuditLog, row2.id).emitted_at == nil
    after
      Logger.configure(level: :warning)
    end

    test "is idempotent on second call with no new rows" do
      Logger.configure(level: :info)

      attrs = %{
        actor_id: "reconcile-idempotent",
        actor_type: "system",
        action: "reconcile.idempotent",
        outcome: "success"
      }

      {:ok, row} = %AuditLog{} |> AuditLog.changeset(attrs) |> @repo.insert()

      capture_log(fn ->
        assert {:ok, 1} = Audit.reconcile(@repo, 100)
      end)

      log =
        capture_log(fn ->
          assert {:ok, 0} = Audit.reconcile(@repo, 100)
        end)

      refute log =~ "reconcile.idempotent"
      refute @repo.get!(AuditLog, row.id).emitted_at == nil
    after
      Logger.configure(level: :warning)
    end

    test "metadata split places label fields at top level and body under details" do
      audit_log = %AuditLog{
        actor_id: "split-test-actor",
        actor_type: "system",
        action: "split.test",
        outcome: "success",
        category: "testcat",
        subject_id: "sub-1",
        subject_type: "user"
      }

      label_set = MapSet.new([:outcome, :category])
      metadata = Emitter.log_metadata(audit_log, label_set)

      top_keys = Keyword.keys(metadata)

      assert :outcome in top_keys
      assert :category in top_keys
      refute :actor_id in top_keys
      refute :actor_type in top_keys
      refute :subject_id in top_keys
      refute :subject_type in top_keys
      refute :audit_log_id in top_keys

      details = metadata[:details]
      assert details[:actor_id] == "split-test-actor"
      assert details[:actor_type] == "system"
      assert details[:subject_id] == "sub-1"
      assert details[:subject_type] == "user"
    end

    test "batch_size caps the number of rows processed per call" do
      Logger.configure(level: :info)

      attrs = %{
        actor_id: "reconcile-batch",
        actor_type: "system",
        action: "reconcile.batch",
        outcome: "success"
      }

      {:ok, _r1} = %AuditLog{} |> AuditLog.changeset(attrs) |> @repo.insert()
      {:ok, _r2} = %AuditLog{} |> AuditLog.changeset(attrs) |> @repo.insert()

      capture_log(fn ->
        assert {:ok, 1} = Audit.reconcile(@repo, 1)
      end)

      unemitted_count =
        @repo.one(from(al in AuditLog, select: count(al.id), where: is_nil(al.emitted_at)))

      assert unemitted_count == 1
    after
      Logger.configure(level: :warning)
    end
  end
end
