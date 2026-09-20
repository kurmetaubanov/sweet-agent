defmodule Sweet.MemoryTest do
  @moduledoc """
  The memory tree itself, and not the functions inside it.

  What is checked is exactly that for the sake of which `:rest_for_one` stands in `Sweet.Memory`:
  the tables live separately from those who use them, and the death of the owner of the
  tables must raise anew ALL those who fill them. Otherwise the table
  is recreated empty, and there is no one to fill it anew — the conversation is whole on the disk
  and lost in the memory.

  There is neither docker nor network here: the embedder is not brought up in the suite, the paragraphs lie down
  without vectors — the same path as with a lying embedder.
  """

  use ExUnit.Case, async: false

  @session "s-memory"

  setup do
    root = Path.join(System.tmp_dir!(), "sweet-memory-#{System.unique_integer([:positive])}")

    previous = %{
      recall_dir: Application.get_env(:sweet, :recall_dir),
      sessions_dir: Application.get_env(:sweet, :sessions_dir),
      skills_root: Application.get_env(:sweet, :skills_root)
    }

    Application.put_env(:sweet, :recall_dir, Path.join(root, "recall"))
    Application.put_env(:sweet, :sessions_dir, Path.join(root, "sessions"))
    # There is no skills folder — and this is a normal case: `Sweet.Skills` reads both folders
    # and survives their absence. For the suite it only matters that it does not climb into
    # the real skills of the host.
    Application.put_env(:sweet, :skills_root, Path.join(root, "skills"))

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:sweet, key, value) end)
      File.rm_rf(root)
    end)

    # The vectorization goes off into the tasks — they are needed by the memory in the test too.
    start_supervised!({Task.Supervisor, name: Sweet.Tasks})
    start_supervised!(Sweet.Memory)

    :ok
  end

  test "the death of the owner of the tables raises the memory too: the paragraphs come back from disk" do
    {:ok, 0} = Sweet.Recall.open(@session)
    Sweet.Recall.append(@session, "user", "first word")
    # The write goes as a cast: we wait for it with a call to the same process, and not with a sleep.
    _ = :sys.get_state(Sweet.Recall)

    assert [%{text: "first word"}] = Sweet.Recall.history(@session)

    recall = Process.whereis(Sweet.Recall)
    tables = Process.whereis(Sweet.Tables)
    ref = Process.monitor(recall)

    Process.exit(tables, :kill)

    # The owner of the tables dragged the memory along with it — that is what was intended: without a table
    # it is an empty process under the same name.
    assert_receive {:DOWN, ^ref, :process, ^recall, _reason}, 1_000

    restarted = await_restart(Sweet.Recall, recall)
    assert restarted != recall

    # The main thing: the table is not simply recreated, but FILLED anew. The paragraph lies
    # in CubDB, and the raised `Sweet.Recall` reads it in `init/1`.
    assert [%{text: "first word"}] = Sweet.Recall.history(@session)
  end

  test "the death of the memory does not carry away the owner of the tables" do
    {:ok, 0} = Sweet.Recall.open(@session)
    tables = Process.whereis(Sweet.Tables)
    recall = Process.whereis(Sweet.Recall)

    Process.exit(recall, :kill)
    assert await_restart(Sweet.Recall, recall) != recall

    # `:rest_for_one` looks forward, and not backward: the one who stands EARLIER
    # than the fallen one has not deserved a restart.
    assert Process.whereis(Sweet.Tables) == tables
  end

  # We wait for a change of the pid under the name, and do not sleep at random: a restart takes
  # as long as it takes, and an exact number here would be a guess.
  defp await_restart(name, was, attempts \\ 50)

  defp await_restart(name, was, 0), do: flunk("#{inspect(name)} did not come up again after #{inspect(was)}")

  defp await_restart(name, was, attempts) do
    case Process.whereis(name) do
      nil ->
        Process.sleep(20)
        await_restart(name, was, attempts - 1)

      ^was ->
        Process.sleep(20)
        await_restart(name, was, attempts - 1)

      pid ->
        pid
    end
  end
end
