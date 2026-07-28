# Fort

Drop-in, atomic audit logging for Elixir/Phoenix applications. Wrap existing `Ecto.Multi` at call site. No rewiring business logic, no new type to thread through helpers. Persists audit trail to PostgreSQL and emits structured JSON via `:logger`.

## Invariant

Why this library, it tackles a specific problem: 1:1 audit and transaction records 

> A business transaction can never be reported as complete (`{:ok, _}`) unless its audit trail is also complete, written atomically with it.

This is enforced by the type system at the `Fort.Audit.transact/4` boundary:

| What you pass | What happens |
|---|---|
| **`AuditedMulti` with ≥ 1 audit step** |  Runs atomically — business data and audit log commit or rollback together |
| Bare `Ecto.Multi` |  `FunctionClauseError` — call `Fort.Audit.wrap/1` first |
| `AuditedMulti` with 0 steps |  `MissingAuditStepError` — at least one audit step required |

On **Multi failure**, a failure audit is written automatically. If that failure-audit itself fails, `transact/4` returns `{:error, {:audit_failed, reason, audit_errors}}`.

## System Requirements

- **Elixir:** ~> 1.15
- **PostgreSQL:** 12+
- **Ecto:** ~> 3.14 (via `ecto_sql`)
- **Hex package manager** (bundled with Elixir)

## Quick Start

Add `fort` to your `mix.exs`:

```elixir
def deps do
  [
    {:fort, "~> 0.1"}
  ]
end
```

Configure the Ecto repo in `config/config.exs`:

```elixir
config :fort, :repo, MyApp.Repo
```

> **Note:** `Fort.Application` reads `:repo` at boot. If it's unconfigured, the host app will crash on startup, not on first audit call — intentional fail-fast behavior.

Install and run the migration to create the `audit_logs` table:

```bash
mix fort.install
mix ecto.migrate
```

## Two paths, different guarantees

- **Transactional** (`transact/4`): DB audit row is atomic with business steps. Logger is a secondary record, emitted after commit.
- **Logger-only** (`log/1`): No DB atomicity needed. Useful for pre-Multi validation failures, non-transactional code, or anywhere the DB audit is optional.

Choose `transact/4` when you need **"DB audit succeeds ⇔ business step succeeds"**. Choose `log/1` when the DB audit is a best-effort supplement to the Logger record.

## Canonical usage
That's it. The `audit_logs` table is ready. Now wrap any `Ecto.Multi`:

```elixir
Multi.new()
|> Multi.insert(:user, User.changeset(%User{}, user_params))
|> Fort.Audit.wrap()
|> Fort.Audit.append_to_multi(:audit, %{
  actor_id: actor.id,
  actor_type: "admin_user",
  action: "user.created"
})
|> Fort.Audit.transact("user.created", actor.id, actor_type: "admin_user")
```

## Project Structure

```
fort/
├── lib/
│   ├── fort.ex                    # Top-level module documentation
│   ├── fort/
│   │   ├── application.ex         # OTP startup — reads :repo config
│   │   ├── audit.ex               # Core API (transact, log, wrap, new, etc.)
│   │   ├── audited_multi.ex       # AuditedMulti struct (wraps Ecto.Multi + audit steps)
│   │   ├── missing_audit_step_error.ex  # Error for zero-step transactions
│   │   ├── schemas/
│   │   │   └── audit_log.ex       # Ecto schema for audit_logs table
│   └── mix/tasks/fort/
│       └── install.ex             # mix fort.install task
├── config/
│   ├── config.exs                 # Base config (imports env configs)
│   ├── dev.exs                    # Dev environment config
│   └── test.exs                   # Test config (TestRepo, PG connection)
├── priv/test_repo/migrations/     # Migration template copied by mix fort.install
├── test/                          # Test suite
├── mix.exs                        # Project definition
└── README.md
```

Your application only interacts with `Fort.Audit` and `Fort.AuditedMulti` — everything else is internal.

## Key Concepts

### Three Building Blocks

1. **`AuditedMulti`** — a wrapper around `Ecto.Multi` that tracks how many audit steps you've added
2. **`Fort.Audit.append_to_multi/3`** — adds an audit entry (static map or function) to the transaction
3. **`Fort.Audit.transact/4`** — runs the transaction atomically; on failure, writes a failure audit automatically

### Dual Routing

Every audit log entry goes to two destinations simultaneously:
1. **PostgreSQL** — `audit_logs` table (persistent, queryable)
2. **Logger** — `Logger.info` (success) or `Logger.error` (failure) with structured metadata

This enables SIEM integration, log aggregation, and real-time monitoring without additional infrastructure.

## Usage Patterns

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

### Deriving before/after/changes from a changeset

Instead of hand-building `before_data`/`after_data`/`changes` maps, use `Fort.Audit.from_changeset/1` to derive them directly from an `Ecto.Changeset`:

```elixir
changeset
|> Fort.Audit.from_changeset()
|> Map.merge(%{actor_id: actor.id, actor_type: "admin_user", action: "user.updated"})
|> then(&Fort.Audit.append_to_multi(multi, :audit, &1))
```

Fields marked `redact: true` in your Ecto schema are stripped entirely from all three maps — no masking, no placeholders.

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
| `scope_type` | string | no | Type of scoping entity (e.g. "organization", "tenant", "workspace") |
| `scope_id` | string | no | ID of the scoping entity |
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

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| App crashes on startup | `:repo` not configured | Add `config :fort, :repo, MyApp.Repo` |
| `FunctionClauseError` at transact | Passed bare `Ecto.Multi` | Call `Fort.Audit.wrap/1` first |
| `MissingAuditStepError` | No audit steps added | Call `Fort.Audit.append_to_multi/3` at least once |
| Audit log not in DB | Migration not run | Run `mix fort.install && mix ecto.migrate` |
| Logger output missing | Logger level too high | Check `config :logger, level: :info` |
