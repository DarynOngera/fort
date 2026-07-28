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

## Two paths

- **Transactional** (`transact/4`): DB audit row is atomic with business steps. Logger emission is secondary, after commit.
- **Standalone** (`log/1`): Single insert outside a transaction. Useful for pre-Multi validation failures or non-transactional code.

## Usage

### Existing Multi (wrap at the end)

Attach audit to an already-assembled `Ecto.Multi` by wrapping it right before `transact/4`:

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

### Greenfield (no existing Multi)

Start from scratch with `new/0`. Business steps are added by destructuring the `.multi` field:

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

### Deriving before/after/changes from a changeset

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
