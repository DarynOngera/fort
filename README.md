# Fort

Drop-in, atomic audit logging for Elixir/Phoenix applications. Persists audit trail to PostgreSQL and emits structured JSON via `:logger`. Business transactions and their audit records are always committed atomically — enforced at the `transact/4` boundary by the `AuditedMulti` type.

## Installation

Add `fort_audit` to your `mix.exs`:

```elixir
def deps do
  [
    {:fort_audit, "~> 0.1"}
  ]
end
```

Configure the Ecto repo in `config/config.exs`:

```elixir
config :fort_audit, :repo, MyApp.Repo
```

> **Note:** `Fort.Application` reads `:repo` at boot. If unconfigured, the host app crashes on startup — intentional fail-fast behavior.

Install and run the migration to create the `audit_logs` table:

```bash
mix fort.install
mix ecto.migrate
```

## Three paths

| Function | Guarantee | Cost |
|---|---|---|
| `audited_transaction/4` / `transact/4` | Atomic — no business success without a durable audit row | Extra insert inside the business transaction |
| `log_best_effort/4` | None — audit event can be lost on crash between commit and this call | Zero added cost to the business transaction |
| `log/1` | Durable — synchronous DB insert + Logger emission | Standalone write, no transaction |

## Usage

### Quick start (recommended)

For a single business `Ecto.Multi` with one audit step — the common case:

```elixir
Fort.Audit.audited_transaction(multi, "user.created",
  actor_id: actor.id,
  actor_type: "admin_user",
  audit_attrs: %{subject_id: user.id, subject_type: "user"}
)
```

Actor identity (`actor_id`, `actor_type`) and `action` are stated exactly once.
The audit step is constructed correctly inside — `MissingAuditStepError` is
structurally unreachable through this entry point.

### Standalone log (no Multi)

For pre-Multi validation failures or non-transactional code paths:

```elixir
case validate_params(params) do
  :ok ->
    # proceed to Fort.Audit.audited_transaction

  {:error, reason} ->
    Fort.Audit.log(%{
      actor_id: actor.id,
      actor_type: "admin_user",
      action: "user.registration.rejected",
      outcome: "failure",
      metadata: %{reason: reason}
    })

    {:error, reason}
end
```

### Audited procedural (inside Repo.transaction)

For state transitions inside `Repo.transaction(fn -> ... end)`:

```elixir
def execute(settlement_id, attrs) do
  Repo.transaction(fn ->
    settlement = cancel(settlement_id, attrs)

    {:ok, _audit_log} = Fort.Audit.log(%{
      actor_id: attrs.actor_id,
      actor_type: attrs.actor_type,
      action: "settlement.cancelled",
      outcome: "success",
      subject_id: settlement.id,
      subject_type: "settlement",
      changes: %{status: "cancelled"}
    })

    settlement
  end)
end
```

### Advanced: multiple audit steps in one Multi

When you need more than one audit step inside a single transaction (e.g. auditing
two related entities), use the lower-level `wrap/1`, `append_to_multi/3`, and
`transact/4` directly.

#### Wrapping a Multi (existing or new)

Build a plain `Ecto.Multi` first, then wrap it — same path whether starting from scratch or wrapping an already-assembled Multi:

```elixir
multi =
  Multi.new()
  |> Multi.insert(:user, User.changeset(%User{}, user_params))
  |> Multi.run(:profile, fn %{user: user} ->
    Profile.changeset(%Profile{}, %{user_id: user.id})
    |> Repo.insert()
  end)

multi
|> Fort.Audit.wrap()
|> Fort.Audit.append_to_multi(:audit, %{
  actor_id: actor.id,
  actor_type: "admin_user",
  action: "user.created",
  subject_id: user.id,
  subject_type: "user"
})
|> Fort.Audit.transact("user.created", actor.id, actor_type: "admin_user")
```

#### Dynamic attrs from accumulated changes

```elixir
Multi.new()
|> Multi.run(:data, fn _repo, _changes -> {:ok, %{user_id: "user-1"}} end)
|> Fort.Audit.wrap()
|> Fort.Audit.append_to_multi(:audit, fn changes ->
  %{
    actor_id: "actor-1",
    actor_type: "system",
    action: "test",
    subject_id: changes.data.user_id
  }
end)
|> Fort.Audit.transact("test.action", "actor-1", actor_type: "system")
```

#### Deriving before/after/changes from a changeset

Derive `before_data`, `after_data`, and `changes` from an `Ecto.Changeset`. Fields marked `redact: true` are stripped entirely:

```elixir
changeset
|> Fort.Audit.from_changeset()
|> Map.merge(%{actor_id: actor.id, actor_type: "admin_user", action: "user.updated"})
|> then(&Fort.Audit.append_to_multi(multi, :audit, &1))
```

## Schema

No foreign keys — audit records survive entity deletion. All IDs are plain strings.

| Field | Type | Required | Description |
|---|---|---|---|
| `actor_id` | string | yes | Who performed the action |
| `actor_type` | string | yes | Type of actor |
| `subject_id` | string | no | What the action was performed on |
| `subject_type` | string | no | Type of subject |
| `action` | string | yes | Dot-notation action name |
| `outcome` | string | yes | "success" or "failure" |
| `before_data` | jsonb | no | State before the action |
| `after_data` | jsonb | no | State after the action |
| `changes` | jsonb | no | Summary of changes |
| `metadata` | jsonb | no | Extra context |
| `category` | string | no | Domain category |
| `description` | string | no | Human-readable summary |
| `scope_type` | string | no | Scoping entity type |
| `scope_id` | string | no | Scoping entity ID |

## Guardrails

- **Bare `Ecto.Multi`** passed to `transact/4` raises `FunctionClauseError` — must wrap with `Fort.Audit.wrap/1` first.
- **Zero audit steps** raises `MissingAuditStepError` — every transaction must carry at least one audit.
- **On Multi failure**, a failure audit is written automatically. If the failure-audit itself fails, returns `{:error, {:audit_failed, reason, audit_errors}}`.
