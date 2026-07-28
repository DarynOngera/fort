defmodule Fort.AuditedMulti do
  @moduledoc """
  Opaque wrapper around `Ecto.Multi` that enforces audit step presence.

  Only an `AuditedMulti` with at least one audit step can be passed to
  `Fort.Audit.transact/4`. Business steps are added to the underlying
  `Ecto.Multi` via the `multi` field or standard `Ecto.Multi.*` pipes.
  """

  @enforce_keys [:multi]
  defstruct [:multi, audit_steps: []]

  @type t :: %__MODULE__{multi: term(), audit_steps: [atom()]}

  @doc """
  Returns the underlying `Ecto.Multi`.
  """
  @spec multi(t()) :: Ecto.Multi.t()
  def multi(%__MODULE__{multi: multi}), do: multi

  @doc """
  Returns the list of audit step names.
  """
  @spec audit_steps(t()) :: [atom()]
  def audit_steps(%__MODULE__{audit_steps: steps}), do: steps
end
