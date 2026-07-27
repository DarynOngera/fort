# Fort

Dual-routed audit logging for Elixir/Phoenix applications: persists audit trail to PostgreSQL and emits structured JSON via `:logger`.

## Invariant

> **A business transaction must never be reported as complete (`{:ok, _}`) unless its audit trail is also complete, written atomically with it.**

This is enforced by the type system at the `Fort.Audit.transact/4` boundary: only an `AuditedMulti` with at least one audit step can be passed to it. A bare `Ecto.Multi` causes a `FunctionClauseError`; an `AuditedMulti` with zero audit steps raises `MissingAuditStepError`.

## Installation

Add `fort` to your `mix.exs`:

```elixir
def deps do
  [
    {:fort, path: "~/projects/fort"}
  ]
end
```

Configure the Ecto repo in `config/config.exs`:

```elixir
config :fort, :repo, MyApp.Repo
```

Run the migration to create the `audit_logs` table:

```bash
mix ecto.migrate
```

You'll need to copy the migration from `priv/test_repo/migrations/` to your app's `priv/repo/migrations/` directory.

## Canonical usage

### Existing Multi (wrap at the end)

When business steps are already assembled on a bare `Ecto.Multi`:

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

Key points:

- **Business steps stay on bare `Ecto.Multi`** — no need to thread an `AuditedMulti` through every helper.
- **Wrapping happens at the end**, right before audit is attached. `Fort.Audit.wrap/1` creates an `AuditedMulti` with zero audit steps.
- **`Fort.Audit.append_to_multi/3`** appends the audit step and records the step name — now the `AuditedMulti` is executable.
- **`Fort.Audit.transact/4`** runs the Multi, writes a failure audit on error, and returns `{:error, {:audit_failed, ...}}` if the failure-audit itself fails.

### Greenfield (no existing Multi)

```elixir
Fort.Audit.new()
|> then(fn %Fort.AuditedMulti{multi: multi} ->
  %{multi |
    multi: multi
    |> Multi.insert(:organization, Organization.changeset(%Organization{}, org_params))
    |> Multi.run(:owner, fn %{organization: org} -> create_owner(org, owner_params) end)
  }
end)
|> Fort.Audit.append_to_multi(:audit, %{
  actor_id: actor.id,
  actor_type: "admin_user",
  action: "organization.created"
})
|> Fort.Audit.transact("organization.created", actor.id, actor_type: "admin_user")
```

`Fort.Audit.new/0` wraps an empty `Ecto.Multi` in an `AuditedMulti`. Business steps are added by destructuring the `.multi` field and rebuilding the struct.

### Standalone log (no Multi)

For pre-Multi validation failures or non-transactional code paths:

```elixir
case validate_params(params) do
  :ok ->
    # proceed to Fort.Audit.transact

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

For simple state transitions inside `Repo.transaction(fn -> ... end)`:

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

If `Fort.Audit.log/1` returns `{:error, _}`, the `fn ->` returns `{:error, changeset}`, which rolls back the transaction — natural fail-closed without needing `Repo.rollback`.

### Dynamic attrs from accumulated changes

```elixir
Fort.Audit.new()
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

## Schema

| Field | Type | Required | Description |
|---|---|---|---|
| `actor_id` | string | yes | Who performed the action |
| `actor_type` | string | yes | Type of actor (e.g. "admin_user", "system") |
| `actor_name` | string | no | Human-readable name |
| `actor_identifier` | string | no | Contact/identifier (e.g. email) |
| `subject_id` | string | no | What the action was performed on |
| `subject_type` | string | no | Type of subject (e.g. "user", "settlement") |
| `subject_name` | string | no | Human-readable subject name |
| `subject_reference` | string | no | External reference code |
| `action` | string | yes | Dot-notation action name (e.g. "user.created") |
| `category` | string | no | Domain category |
| `description` | string | no | Human-readable summary |
| `outcome` | string | yes | "success" or "failure" |
| `profile_id` | string | no | Associated profile ID |
| `organization_id` | string | no | Associated organization ID |
| `before_data` | jsonb | no | State before the action |
| `after_data` | jsonb | no | State after the action |
| `changes` | jsonb | no | Summary of changes |
| `metadata` | jsonb | no | Extra context (source IP, error details, etc.) |

No foreign keys — audit records survive entity deletion. All IDs are plain strings.

## Guardrails

- **Bare `Ecto.Multi`** passed to `transact/4` raises `FunctionClauseError` — you must wrap it with `Fort.Audit.wrap/1` first.
- **Zero audit steps** raises `MissingAuditStepError` — every transaction must carry at least one audit.
- **On Multi failure**, a failure audit is automatically written. If the failure-audit itself fails, returns `{:error, {:audit_failed, reason, audit_errors}}`.
- **On success**, the audit log is committed atomically with business steps — no way to have a successful business outcome without a persisted audit record.

## Dual routing

Every audit log entry is:

1. **Persisted** to the `audit_logs` PostgreSQL table
2. **Emitted** via `Logger.info` (success) or `Logger.error` (failure) as structured metadata

This enables SIEM integration, log aggregation, and real-time monitoring without additional infrastructure.
