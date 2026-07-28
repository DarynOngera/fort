defmodule Fort.Audit do
  @moduledoc """
  Atomic audit logging with a best-effort Logger projection.

  ## Invariant

  The persisted `audit_logs` PostgreSQL row is atomic with the business
  transaction — this is enforced via `AuditedMulti` / `transact/4`.
  Logger emission is a **downstream, best-effort projection** of that
  persisted row.  It is not required to be atomic with the business
  transaction, may lag, may batch, and its absence or delay is an
  observability gap, not a compliance violation.

  **Postgres is the single source of truth; Logger output is always
  derived from it, never written independently of it.**

  Logger emission is handled by `Fort.Audit.Emitter`.  Each committed
  row is emitted synchronously and its `emitted_at` timestamp is
  stamped.  This is **at-least-once**: a crash between the Logger call
  and the DB stamp may cause re-emission on restart.  The `emitted_at`
  column also serves as a bookmark for downstream consumers — rows where
  `emitted_at IS NULL` have not yet been processed by Fort.

  ## Configuration

  Set the Ecto repo in `config/config.exs`:

      config :fort, :repo, MyApp.Repo

  ## Usage

  See `Fort.Audit.transact/4`, `Fort.Audit.log/1`, `Fort.Audit.new/0`, `Fort.Audit.wrap/1`,
  and `Fort.Audit.from_changeset/1`.

  ### Deriving audit data from a changeset

  Use `from_changeset/1` to derive `before_data`, `after_data`, and `changes` directly
  from an `Ecto.Changeset`, then merge with actor/action attrs:

      changeset
      |> Fort.Audit.from_changeset()
      |> Map.merge(%{actor_id: actor.id, actor_type: "admin_user", action: "user.updated"})
      |> then(&Fort.Audit.append_to_multi(multi, :audit, &1))

  Fields marked `redact: true` in the schema are stripped entirely from all three
  maps — see `from_changeset/1` for details.

  ## Verified limitations

  ### Embeds

  `__schema__(:fields)` includes `embeds_one` / `embeds_many` columns.  When a
  changeset carries a changed embed, `from_changeset/1` places the resolved
  embed struct directly into the output map (e.g.
  `%MyApp.Address{...}`).  If that struct has no `Jason.Encoder` implementation,
  `Jason.encode/1` raises `Protocol.UndefinedError` at serialisation time
  (inside postgrex), not at the `from_changeset/1` call site.

  **Observed behaviour (Ecto 3.14):** `from_changeset/1` succeeds; the caller
  receives a map containing the embed struct.  The crash occurs later when the
  map is inserted into the jsonb column.

  Workaround: either `@derive Jason.Encoder` on your embed schemas, or avoid
  passing embed-carrying changesets through `from_changeset/1` and build the
  audit maps by hand.

  ### Custom Ecto.Type values without `Jason.Encoder`

  If a schema field uses an `Ecto.Type` whose `cast/1` or in-memory
  representation returns a struct (or other term) without a `Jason.Encoder`
  implementation, the value passes through `from_changeset/1` unchanged and
  fails at jsonb serialisation time with `Protocol.UndefinedError`.

  **Observed behaviour (Ecto 3.14):** identical to the embed case —
  `from_changeset/1` succeeds, the crash is deferred to postgrex.

  Workaround: ensure custom types return natively encodable terms (strings,
  numbers, maps, lists) or derive `Jason.Encoder` for any struct they produce.

  Both limitations are inherent to the library's design: `from_changeset/1` is
  Ecto-layer sugar only.  Real change-data-capture (WAL, Debezium, outbox
  pattern) is a different architecture with a different identity model and is
  explicitly out of scope.

  ## Ideas for later

  - Recursive resolution of nested embed/association changesets into their own
    `before_data` / `after_data` / `changes` maps.
  - Normalising values via `Ecto.Type.dump/2` to get database-wire
    representation instead of in-memory struct values.
  - Any WAL-level, logical-replication, Debezium-style, or outbox-pattern CDC
    (different architecture, no actor identity available at that layer without
    session correlation or an outbox).
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
