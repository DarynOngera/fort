defmodule Fort.AuditedMulti do
  @moduledoc """
  Opaque wrapper around `Ecto.Multi` that tracks audit step presence.

  Only an `AuditedMulti` with at least one audit step can be passed to
  `Fort.Audit.transact/4`.  The struct is intentionally minimal:
  business steps are added to the underlying `Ecto.Multi` directly via
  the `multi` field (or via the standard `Ecto.Multi.*` pipe before
  wrapping with `Fort.Audit.wrap/1`).
  """

  @enforce_keys [:multi]
  defstruct [:multi, audit_steps: []]

  @type t :: %__MODULE__{multi: Ecto.Multi.t(), audit_steps: [atom()]}
end
