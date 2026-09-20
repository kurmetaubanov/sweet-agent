defmodule Sweet.CostTest do
  use ExUnit.Case, async: true

  alias Sweet.Cost

  test "a zero usage costs zero" do
    assert Cost.of(%{input: 0, output: 0}) == 0.0
  end

  test "the price grows with the number of tokens" do
    small = Cost.of(%{input: 1_000, output: 100})
    big = Cost.of(%{input: 100_000, output: 10_000})

    assert big > small
  end

  test "the usage report — a line with the figures of the turn and the session" do
    report = Cost.report(%{input: 1_000, output: 100}, %{input: 5_000, output: 500}, 1_200)

    assert is_binary(report)
    assert report =~ "1"
  end

  test "the time of the turn stands at the beginning of the line" do
    report = Cost.report(%{input: 0, output: 0}, %{input: 0, output: 0}, 1_200)

    assert String.starts_with?(report, "⏱ 1 200 ms ·")
  end

  test "the duration is shown in milliseconds at any length of a turn" do
    assert Cost.report(%{}, %{}, 42) =~ "⏱ 42 ms"
    assert Cost.report(%{}, %{}, 129_000) =~ "⏱ 129 000 ms"
  end
end
