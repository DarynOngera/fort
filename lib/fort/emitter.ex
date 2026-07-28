defmodule Fort.Audit.Emitter do
  @moduledoc """
  Synchronous Logger emission for committed audit log rows.

  At-least-once: a crash between the Logger call and the `emitted_at`
  DB stamp may cause re-emission on restart. Downstream consumers should
  dedupe on `audit_logs.id` for exactly-once processing.

  ## Label/body metadata split

  To prevent accidental label-cardinality explosions in metrics-oriented
  backends (Loki, Datadog, Elasticsearch), Logger metadata is split into
  two tiers:

    * **Labels** — configured via `:logger_label_fields`; emitted as
      top-level metadata keys (indexed fields in most collectors).
      Default: `[:outcome, :actor_type, :subject_type]`.
    * **Body** — everything else nests under a single `:details` key
      (a single JSON object, not N individual indexed fields).

  This split is conservative by default: `:outcome` (2 values) and
  `:actor_type`/`:subject_type` (bounded by schema design) are safe
  as labels. `:action`, `:actor_id`, `:subject_id`, `:category`, and
  `:audit_log_id` are excluded from the default — applications with
  genuinely bounded action vocabularies can opt them in explicitly:

      config :fort_audit, :logger_label_fields, [:outcome, :action]
  """

  require Logger

  alias Fort.Schemas.AuditLog

  @doc """
  Emits a Logger line for the given `AuditLog` and stamps `emitted_at`.

  The log level is `:info` for `"success"` outcome and `:error` for
  `"failure"`, matching the field shape used by earlier versions of
  `Fort.Audit`.

  Logger metadata is split into two tiers based on `:logger_label_fields`
  config (default `[:outcome, :actor_type, :subject_type]`):

    * **Labels** — top-level metadata keys (indexed by Loki Promtail,
      Datadog, Elasticsearch, etc.)
    * **Body** — nested under a single `:details` key (a single JSON
      object, not individual indexed fields)

  This prevents accidentally unbounded fields (`actor_id`, `audit_log_id`,
  etc.) from creating label-cardinality explosions in metrics-oriented
  backends.

  Returns `{:ok, updated_audit_log}` where the returned struct has
  `emitted_at` populated.
  """
  @spec emit_and_stamp(Ecto.Repo.t(), AuditLog.t()) :: {:ok, AuditLog.t()}
  def emit_and_stamp(repo, %AuditLog{outcome: outcome} = audit_log) do
    log_level = if outcome == "success", do: :info, else: :error

    label_set = :persistent_term.get({:fort, :logger_label_fields})
    metadata = log_metadata(audit_log, label_set)

    Logger.log(log_level, fn ->
      {audit_log.action, metadata}
    end)

    now = DateTime.utc_now()

    {:ok, updated} =
      audit_log
      |> Ecto.Changeset.change(emitted_at: now)
      |> repo.update()

    {:ok, updated}
  end

  @doc false
  @spec log_metadata(AuditLog.t(), MapSet.t(atom())) :: Keyword.t()
  def log_metadata(%AuditLog{} = audit_log, label_set) do
    all_fields = [
      actor_id: audit_log.actor_id,
      actor_type: audit_log.actor_type,
      subject_id: audit_log.subject_id,
      subject_type: audit_log.subject_type,
      outcome: audit_log.outcome,
      category: audit_log.category,
      audit_log_id: audit_log.id
    ]

    {labels, body} = Enum.split_with(all_fields, fn {key, _val} -> key in label_set end)

    labels ++
      if body == [],
        do: [],
        else: [details: Map.new(body)]
  end
end
