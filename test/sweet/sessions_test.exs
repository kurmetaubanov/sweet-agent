defmodule Sweet.SessionsTest do
  @moduledoc """
  The inventory of conversations. The main thing here is that the establishment of a session no longer waits
  for the disk: the bridge calls `register_async/2` and goes on.
  """

  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "sweet-sessions-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:sweet, :sessions_dir)
    Application.put_env(:sweet, :sessions_dir, dir)

    on_exit(fn ->
      Application.put_env(:sweet, :sessions_dir, previous)
      File.rm_rf(dir)
    end)

    # The table of the inventory and its store are not its property: they are owned by
    # `Sweet.Tables` and `Sweet.Memory`. We bring them up in the same order as the tree.
    start_supervised!(Sweet.Tables)

    start_supervised!(%{
      id: Sweet.Sessions.Store,
      start: {CubDB, :start_link, [[data_dir: dir, name: Sweet.Sessions.Store]]}
    })

    start_supervised!(Sweet.Sessions)
    %{chat: System.unique_integer([:positive]), id: "s-#{System.unique_integer([:positive])}"}
  end

  # A cast has no answer, but the order of messages is there: an answer to the question means
  # that what was said before it has already been handled.
  defp sync, do: :sys.get_state(Sweet.Sessions)

  test "register_async establishes the same record as register", %{chat: chat, id: id} do
    Sweet.Sessions.register_async(id, chat)
    sync()

    entry = Sweet.Sessions.get(id)
    assert entry.id == id
    assert entry.chat_id == chat
    assert entry.turns == 0
    assert entry.title == nil
  end

  test "a repeated establishment does not overwrite what has accumulated", %{chat: chat, id: id} do
    Sweet.Sessions.register_async(id, chat)
    sync()
    Sweet.Sessions.touch(id, "first question", %{input: 1_000, output: 100})
    sync()

    Sweet.Sessions.register_async(id, chat)
    sync()

    entry = Sweet.Sessions.get(id)
    assert entry.turns == 1
    assert entry.title == "first question"
    assert entry.cost > 0.0
  end

  test "the topic is taken from the first question and does not change", %{chat: chat, id: id} do
    Sweet.Sessions.register_async(id, chat)
    sync()

    Sweet.Sessions.touch(id, "first question", %{input: 1, output: 1})
    Sweet.Sessions.touch(id, "second question", %{input: 1, output: 1})
    sync()

    assert Sweet.Sessions.get(id).title == "first question"
    assert Sweet.Sessions.get(id).turns == 2
  end

  test "the last session of a chat is the freshest", %{chat: chat} do
    old = "old-#{System.unique_integer([:positive])}"
    new = "new-#{System.unique_integer([:positive])}"

    Sweet.Sessions.register_async(old, chat)
    Sweet.Sessions.register_async(new, chat)
    sync()

    # The time in the inventory is SECONDS, and both records are established in one and the same. Neither a sleep
    # nor a `touch` will separate them: with an equal `last_at` the order is arbitrary.
    # Therefore we age the old one right in the table — this is the only place
    # where the test has the right to know about its design.
    entry = Sweet.Sessions.get(old)
    :ets.insert(:sweet_sessions, {old, %{entry | last_at: entry.last_at - 60}})

    assert Sweet.Sessions.latest(chat).id == new
    assert length(Sweet.Sessions.list(chat)) == 2
  end

  test "a foreign chat does not get into the inventory", %{chat: chat, id: id} do
    Sweet.Sessions.register_async(id, chat)
    sync()

    assert Sweet.Sessions.list(chat + 1) == []
  end
end
