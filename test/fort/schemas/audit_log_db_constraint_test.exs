defmodule Fort.AuditLogDbConstraintTest do
  use Fort.DataCase

  @repo Application.compile_env(:fort, :repo)

  @base_fields "id, inserted_at"
  @base_values "gen_random_uuid(), NOW()"

  test "DB NOT NULL on outcome rejects a raw SQL insert missing it" do
    assert_raise Postgrex.Error, ~r/null value in column "outcome"/, fn ->
      @repo.query!(
        "INSERT INTO audit_logs (#{@base_fields}, actor_id, actor_type, action) VALUES (#{@base_values}, 'a', 't', 'a')"
      )
    end
  end

  test "DB NOT NULL on action rejects a raw SQL insert missing it" do
    assert_raise Postgrex.Error, ~r/null value in column "action"/, fn ->
      @repo.query!(
        "INSERT INTO audit_logs (#{@base_fields}, actor_id, actor_type, outcome) VALUES (#{@base_values}, 'a', 't', 'success')"
      )
    end
  end

  test "DB NOT NULL on actor_id rejects a raw SQL insert missing it" do
    assert_raise Postgrex.Error, ~r/null value in column "actor_id"/, fn ->
      @repo.query!(
        "INSERT INTO audit_logs (#{@base_fields}, action, outcome) VALUES (#{@base_values}, 'test', 'success')"
      )
    end
  end
end
