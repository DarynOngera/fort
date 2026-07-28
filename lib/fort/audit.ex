defmodule Fort.Audit do
  @moduledoc """
  Atomic audit logging with dual routing: persists to PostgreSQL and emits
  structured JSON via `:logger`.

  ## Two paths

  - **Transactional** (`transact/4`) — audit row committed atomically with
    business steps inside an `Ecto.Multi`. Logger emission is secondary.
  - **Standalone** (`log/1`) — single audit insert outside a Multi. Logger
    emission is synchronous with the DB write.

  ## Configuration

      config :fort_audit, :repo, MyApp.Repo
      config :fort_audit, :logger_label_fields, [:outcome, :action]

  ### `:repo` (required)

  The Ecto repo used for all audit log persistence.

  ### `:logger_label_fields` (optional)

  Controls which metadata fields are emitted as top-level Logger metadata keys
  (indexed as labels by Loki Promtail, Datadog, Elasticsearch, etc.).

  Default: `[:outcome, :actor_type, :subject_type]` — the three fields whose
  cardinality is bounded by design. All remaining fields (`actor_id`,
  `subject_id`, `category`, `audit_log_id`) nest under a single `:details` key
  to prevent accidental label-cardinality explosions.

  See `Fort.Audit.Emitter` for the full rationale.

  ## Usage

  ### Existing Multi

  Use `wrap/1` to attach audit to an already-assembled `Ecto.Multi`:

      Multi.new()
      |> Multi.insert(:user, user_changeset)
      |> Fort.Audit.wrap()
      |> Fort.Audit.append_to_multi(:audit, %{
        actor_id: actor.id,
        actor_type: "admin_user",
        action: "user.created"
      })
      |> Fort.Audit.transact("user.created", actor.id)

  ### Greenfield

  Use `new/0` when starting from scratch:

      Fort.Audit.new()
      |> then(fn %Fort.AuditedMulti{multi: multi} ->
        %{multi | multi: Multi.insert(multi, :org, org_changeset)}
      end)
      |> Fort.Audit.append_to_multi(:audit, %{
        actor_id: actor.id,
        actor_type: "admin_user",
        action: "org.created"
      })
      |> Fort.Audit.transact("org.created", actor.id)

  ### Standalone

  Use `log/1` outside a transaction:

      Fort.Audit.log(%{
        actor_id: actor.id,
        actor_type: "admin_user",
        action: "user.registration.rejected",
        outcome: "failure",
        metadata: %{reason: reason}
      })

  ## Logger metadata structure

  Logger lines emitted by `transact/4` and `log/1` follow a two-tier metadata
  structure to prevent accidental label-cardinality explosions:

    * **Labels** — top-level metadata keys (configured via
      `:logger_label_fields`, default `[:outcome, :actor_type, :subject_type]`)
    * **Body** — everything else nested under a single `:details` key (one JSON
      object, not N individual indexed fields)

  See `Fort.Audit.Emitter` for full rationale and configuration.

  ## Shipment to external systems

  Fort's responsibility ends at emitting a well-structured Elixir `Logger` line.
  Getting logs into Loki, Elasticsearch, Datadog, or any other collector is the
  job of the host application's existing observability pipeline — Promtail,
  Vector, Fluent Bit, `logger_json`, or any Elixir Logger backend already in use.
  Fort does not ship a dedicated Loki/Elasticsearch/Datadog client for the same
  reason it does not ship a web framework adapter in the core library: those are
  integration concerns best solved by the community or the host app against
  stable `Logger` output.

  ## Reconciliation

  Rows that were persisted but never emitted to Logger (e.g., a crash between
  the DB commit and the `emitted_at` stamp) can be recovered via:

      mix fort.reconcile

  This queries unemitted rows using the partial index `idx_audit_logs_unemitted`,
  re-emits each via `Logger`, and stamps `emitted_at`. The function
  `Fort.Audit.reconcile/2` is also public for host apps that want to
  schedule reconciliation from Oban, Quantum, or a `:timer.send_interval`.

  ## At-least-once

  Logger emission is **at-least-once** — a crash between the Logger call and
  the `emitted_at` DB stamp may cause re-emission on restart. Downstream
  consumers should dedupe on `audit_logs.id` for exactly-once processing. The
  mix fort.reconcile task is the recovery mechanism for the permanent case
  (crash before the stamp ever happens).
  """

  require Logger

  alias Ecto.Changeset
  alias Ecto.Multi
  alias Fort.Audit.Emitter
  alias Fort.AuditedMulti
  alias Fort.MissingAuditStepError
  alias Fort.Schemas.AuditLog

  @doc """
  Derives `before_data`, `after_data`, and `changes` directly from an
  `Ecto.Changeset`.

  Scoped to `changeset.data.__struct__.__schema__(:fields)` — this naturally
  excludes associations (which live in `__schema__(:associations)`), preventing
  `%Ecto.Association.NotLoaded{}` structs from reaching the jsonb column where
  they would crash with a `Jason.EncodeError` at insert time.

  Embeds (`embeds_one` / `embeds_many`) are included in `:fields` and pass
  through this filter — see the moduledoc for tested edge-case behaviour.

  Returns a plain map that plugs directly into `append_to_multi/3` or `log/1`:

      changeset
      |> Fort.Audit.from_changeset()
      |> Map.merge(%{actor_id: actor.id, actor_type: "admin_user", action: "user.updated"})
      |> then(&Fort.Audit.append_to_multi(multi, :audit, &1))

  """
  @spec from_changeset(Ecto.Changeset.t()) :: %{
          before_data: map(),
          after_data: map(),
          changes: map()
        }
  def from_changeset(%Ecto.Changeset{data: data} = changeset) do
    schema = data.__struct__
    fields = schema.__schema__(:fields)

    # Fort-specific semantic expansion of Ecto's redact: true.
    # Ecto uses it to hide values from inspect/logging output only.
    # Fort strips redacted fields entirely from the audit trail — a
    # present-but-nil key still leaks field existence and type to
    # anyone reading audit_logs.  Absence leaks nothing.
    redacted = redact_fields(schema)

    before_data = data |> Map.take(fields) |> Map.drop(redacted)
    after_data = changeset |> Changeset.apply_changes() |> Map.take(fields) |> Map.drop(redacted)
    changes = Map.take(changeset.changes, fields) |> Map.drop(redacted)

    %{before_data: before_data, after_data: after_data, changes: changes}
  end

  @doc """
  Returns a fresh `AuditedMulti` wrapping an empty `Ecto.Multi`.
  """
  @spec new() :: AuditedMulti.t()
  def new do
    %AuditedMulti{multi: Multi.new()}
  end

  @doc """
  Wraps an existing `Ecto.Multi` in an `AuditedMulti`.
  """
  @spec wrap(Ecto.Multi.t()) :: AuditedMulti.t()
  def wrap(%Multi{} = multi) do
    %AuditedMulti{multi: multi}
  end

  @doc """
  Appends a success audit step to an `AuditedMulti`.
  Accepts a static map or a 1-arity function from accumulated changes.
  """
  @spec append_to_multi(AuditedMulti.t(), atom(), map() | (map() -> map())) ::
          AuditedMulti.t()
  def append_to_multi(
        %AuditedMulti{multi: multi, audit_steps: steps} = audited,
        name,
        attrs_or_fn
      )
      when is_map(attrs_or_fn) or is_function(attrs_or_fn, 1) do
    attrs_fn = if is_function(attrs_or_fn, 1), do: attrs_or_fn, else: fn _ -> attrs_or_fn end

    updated_multi =
      Multi.run(multi, name, fn repo, changes ->
        attrs = Map.put(attrs_fn.(changes), :outcome, "success")
        insert_only(repo, attrs)
      end)

    %{audited | multi: updated_multi, audit_steps: [name | steps]}
  end

  @doc """
  Runs the transaction with audit guarantees.
  Raises `MissingAuditStepError` if no audit steps were appended.
  Writes a failure audit log when the Multi fails.
  """
  @spec transact(AuditedMulti.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def transact(audited_multi, action, actor_id \\ nil, opts \\ [])

  def transact(%AuditedMulti{audit_steps: []}, _action, _actor_id, _opts) do
    raise MissingAuditStepError
  end

  def transact(%AuditedMulti{multi: multi, audit_steps: steps}, action, actor_id, opts) do
    case repo().transaction(multi) do
      {:ok, changes} ->
        emit_audit_logs(steps, changes)
        {:ok, changes}

      {:error, _op, reason, _changes} ->
        case log_failure(action, actor_id, opts, reason) do
          :ok -> {:error, reason}
          {:error, audit_error} -> {:error, {:audit_failed, reason, audit_error}}
        end
    end
  end

  @doc """
  Standalone audit log insert outside a transaction.
  """
  @spec log(map()) :: {:ok, AuditLog.t()} | {:error, Changeset.t()}
  def log(attrs) do
    do_log(repo(), attrs)
  end

  @doc """
  Re-processes audit log rows that were never emitted to Logger.

  Queries rows where `emitted_at IS NULL` (using the partial index
  `idx_audit_logs_unemitted`) in `inserted_at` order, up to `batch_size`
  rows per call. Re-emits each row via `Emitter.emit_and_stamp/2`.

  Idempotent — rows already stamped are excluded by the query, so a
  second call with no new unemitted rows is a no-op.

  Returns `{:ok, count}` where count is the number of rows successfully
  re-processed. Individual row failures are logged at error level but
  do not halt the batch.
  """
  @spec reconcile(Ecto.Repo.t(), pos_integer()) :: {:ok, non_neg_integer()}
  def reconcile(repo, batch_size \\ 100)

  def reconcile(repo, batch_size) when is_integer(batch_size) and batch_size > 0 do
    import Ecto.Query

    query =
      from(al in AuditLog,
        where: is_nil(al.emitted_at),
        order_by: al.inserted_at,
        limit: ^batch_size
      )

    count =
      repo.all(query)
      |> Enum.reduce(0, fn audit_log, acc ->
        try do
          {:ok, _updated} = Emitter.emit_and_stamp(repo, audit_log)
          acc + 1
        rescue
          reason ->
            Logger.error(fn ->
              {"audit_log.reconcile_failed", [audit_log_id: audit_log.id, error: inspect(reason)]}
            end)

            acc
        end
      end)

    {:ok, count}
  end

  defp repo, do: :persistent_term.get({:fort, :repo})

  # Emit Logger lines for committed audit rows and stamp emitted_at.
  # Runs outside the Postgres transaction — if it crashes the audit rows
  # are already durable and will be re-emitted on restart.
  defp emit_audit_logs(steps, changes) do
    Enum.each(steps, fn step_name ->
      if audit_log = Map.get(changes, step_name) do
        Emitter.emit_and_stamp(repo(), audit_log)
      end
    end)
  end

  # Insert-only — no Logger emission.  Used inside the transactional path
  # (append_to_multi/3's Multi.run) where Logger would fire before commit,
  # producing ghost log lines on rollback.
  defp insert_only(repo, attrs) do
    %AuditLog{}
    |> AuditLog.changeset(attrs)
    |> repo.insert()
  end

  defp do_log(repo, attrs) do
    case %AuditLog{}
         |> AuditLog.changeset(attrs)
         |> repo.insert() do
      {:ok, %AuditLog{} = audit_log} ->
        {:ok, updated} = Emitter.emit_and_stamp(repo, audit_log)
        {:ok, updated}

      {:error, %Changeset{} = changeset} ->
        Logger.error(fn ->
          {"audit_log.persistence_failed", [errors: inspect(changeset.errors)]}
        end)

        {:error, changeset}
    end
  end

  defp log_failure(action, actor_id, opts, reason) do
    base = keyword_to_map(opts)
    existing_metadata = Map.get(base, :metadata, %{})

    attrs =
      base
      |> Map.put(:action, action)
      |> Map.put(:actor_id, actor_id)
      |> Map.put(:outcome, "failure")
      |> Map.put(:metadata, Map.merge(existing_metadata, %{error: format_error(reason)}))

    case log(attrs) do
      {:ok, _audit_log} ->
        :ok

      {:error, %Changeset{} = changeset} ->
        {:error, changeset.errors}
    end
  end

  defp keyword_to_map(keyword) when is_list(keyword), do: Map.new(keyword)
  defp keyword_to_map(map) when is_map(map), do: map

  defp redact_fields(schema) do
    # __schema__(:redact_fields) was added in Ecto 3.7+.
    # Gracefully degrade to empty list if unavailable.
    schema.__schema__(:redact_fields)
  rescue
    FunctionClauseError -> []
  end

  defp format_error(%Changeset{} = changeset), do: inspect(changeset.errors)
  defp format_error(reason) when is_atom(reason), do: reason
  defp format_error({key, value}) when is_atom(key), do: inspect({key, value})
  defp format_error(reason), do: inspect(reason)
end
