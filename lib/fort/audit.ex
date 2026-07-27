defmodule Fort.Audit do
  @moduledoc """
  Dual-routed audit logging: persisted to PostgreSQL and emitted as structured JSON via `:logger`.

  ## Configuration

  Set the Ecto repo in `config/config.exs`:

      config :fort, :repo, MyApp.Repo

  ## Usage

  See `Fort.Audit.transact/4`, `Fort.Audit.log/1`, `Fort.Audit.new/0`, and `Fort.Audit.wrap/1`.
  """

  require Logger

  alias Ecto.Changeset
  alias Ecto.Multi
  alias Fort.AuditedMulti
  alias Fort.MissingAuditStepError
  alias Fort.Schemas.AuditLog

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
  Accepts a static map or a function from accumulated changes.
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
        do_log(repo, attrs)
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

  def transact(%AuditedMulti{multi: multi}, action, actor_id, opts) do
    case repo().transaction(multi) do
      {:ok, changes} ->
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

  defp do_log(repo, attrs) do
    %AuditLog{}
    |> AuditLog.changeset(attrs)
    |> repo.insert()
    |> log_to_logger()
  end

  defp log_to_logger({:ok, %AuditLog{} = audit_log}) do
    Logger.info(fn ->
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

    {:ok, audit_log}
  end

  defp log_to_logger({:error, %Changeset{} = changeset} = error) do
    Logger.error(fn ->
      {"audit_log.persistence_failed", [errors: inspect(changeset.errors)]}
    end)

    error
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

  defp format_error(%Changeset{} = changeset), do: inspect(changeset.errors)
  defp format_error(reason) when is_atom(reason), do: reason
  defp format_error({key, value}) when is_atom(key), do: inspect({key, value})
  defp format_error(reason), do: inspect(reason)
end
