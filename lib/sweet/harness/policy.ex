defmodule Sweet.Harness.Policy do
  @moduledoc """
  Thresholds and decisions. Also CODE — because the threshold here is not a number, but a function
  of the context, and pattern matching expresses this more directly than any config.

  This is the first candidate for self-improvement: the agent adds a clause, and does not edit
  a number in json.
  """

  @doc """
  Whether to continue the loop after a turn with tools.

  We count in tokens, and not in turns: a turn with one `print` and a turn grinding
  two hundred megabytes cost differently, while the counter of turns does not distinguish them. Turns
  remain a coarse fuse against looping on a tool.
  """
  def continue?(%{usage: %{input: input, output: output}, turns: turns}) do
    input + output < Application.fetch_env!(:sweet, :token_budget) and
      turns < Application.fetch_env!(:sweet, :turn_limit)
  end

end
