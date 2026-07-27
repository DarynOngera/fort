defmodule Fort.NoDirectRepoTransactionTest do
  use ExUnit.Case

  @moduledoc """
  Guard that prevents new `Repo.transaction/1` calls from bypassing
  `Fort.Audit`.

  Existing call sites are allowlisted here.  If this test fails for a
  file you don't see in the list, you likely added a new bare call to
  `Repo.transaction/1` or `@repo.transaction/1` instead of going
  through `Fort.Audit.transact/4`.
  """

  @lib_root Path.expand(Path.join(__DIR__, "../../lib"))

  @allowed_files [
    # Audit itself (transact uses Repo.transaction internally)
    "fort/audit.ex"
  ]

  test "no unlisted file calls Repo.transaction/1 directly" do
    lib_root = @lib_root

    allowed_abs =
      MapSet.new(@allowed_files, fn f -> Path.join(lib_root, f) end)

    offenders =
      lib_root
      |> Path.join("/**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&MapSet.member?(allowed_abs, &1))
      |> Enum.filter(&file_calls_repo_transaction?/1)

    if offenders != [] do
      flunk("""
      The following files call Repo.transaction/1 directly without going through Fort.Audit.transact/4.
      Either migrate them to use Fort.Audit.transact/4 or add them to the allowlist in #{inspect(__MODULE__)}.

      Offenders:
      #{Enum.map_join(offenders, "\n", &"  - #{Path.relative_to_cwd(&1)}")}
      """)
    end
  end

  defp file_calls_repo_transaction?(path) do
    path
    |> File.stream!()
    |> Enum.any?(fn line ->
      String.contains?(line, "Repo.transaction(") or String.contains?(line, "@repo.transaction(")
    end)
  end
end
