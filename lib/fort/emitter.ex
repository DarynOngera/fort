defmodule Fort.Audit.Emitter do
  @moduledoc """
  Synchronous Logger emission for committed audit log rows.

  Each row is emitted once and its `emitted_at` timestamp is stamped
  immediately after emission.  This is **at-least-once**: a crash between
  the Logger call and the DB stamp may cause re-emission on restart.
  Downstream consumers should dedupe on `audit_logs.id` if exactly-once
  processing is required.
  """

  require Logger

  alias Fort.Schemas.AuditLog

  @doc """
  Emits a Logger line for the given `AuditLog` and stamps `emitted_at`.

  The log level is `:info` for `"success"` outcome and `:error` for
  `"failure"`, matching the field shape used by earlier versions of
  `Fort.Audit`.

  Returns `{:ok, updated_audit_log}` where the returned struct has
  `emitted_at` populated.
  """
  @spec emit_and_stamp(Ecto.Repo.t(), AuditLog.t()) :: {:ok, AuditLog.t()}
  def emit_and_stamp(repo, %AuditLog{outcome: outcome} = audit_log) do
    log_level = if outcome == "success", do: :info, else: :error

    Logger.log(log_level, fn ->
      {audit_log.action,
       [
         actor_id: audit_log.actor_id,
         actor_type: audit_log.actor_type,
         subject_id: audit_log.subject_id,
         subject_type: audit_log.subject_type,
         outcome: audit_log.outcome,
         category: audit_log.category,
         audit_log_id: audit_log.id
       ]}
    end)

    now = DateTime.utc_now()

    {:ok, updated} =
      audit_log
      |> Ecto.Changeset.change(emitted_at: now)
      |> repo.update()

    {:ok, updated}
  end
end
