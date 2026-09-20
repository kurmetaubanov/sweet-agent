defmodule Sweet.RecallTest do
  @moduledoc """
  The memory of a conversation: writing, the window tail, the marks and re-indexing.

  The processes here are brought up by hand — the application does not start. There is no embedder in
  the suite deliberately: `Sweet.Recall.encode/3` catches its absence, and this is
  exactly the path along which a paragraph lies down without a vector. So what is checked is
  what the memory must do EVEN when there are no vectors.
  """

  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "sweet-recall-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:sweet, :recall_dir)
    Application.put_env(:sweet, :recall_dir, dir)

    on_exit(fn ->
      Application.put_env(:sweet, :recall_dir, previous)
      File.rm_rf(dir)
    end)

    # The tasks are needed by the memory itself: the vectorization goes off into them.
    start_supervised!({Task.Supervisor, name: Sweet.Tasks})
    # The table and the store of the memory live OUTSIDE its process (Sweet.Tables and
    # Sweet.Memory), therefore the suite brings them up itself and in the same order as
    # the tree: first the place, then the one who uses it.
    start_supervised!(Sweet.Tables)
    start_supervised!(store(Sweet.Recall.Store, dir))
    start_supervised!(Sweet.Recall)

    %{dir: dir, session: "s-#{System.unique_integer([:positive])}"}
  end

  # The store — with the same description as in `Sweet.Memory`: under its own name, in
  # its own folder. We write it here, and do not call the supervisor as a whole: it also has
  # the inventory and the skills, while this suite needs one memory.
  defp store(name, dir) do
    %{id: name, start: {CubDB, :start_link, [[data_dir: dir, name: name]]}}
  end

  # The write goes as a cast, and it has no answer. We synchronize with a call:
  # messages to one process are handled in order, therefore an answer to the
  # question means that everything said before it has already been handled.
  defp sync, do: :sys.get_state(Sweet.Recall)

  defp append(session, role, text) do
    Sweet.Recall.append(session, role, text)
    sync()
  end

  test "paragraphs lie down at once, even before the vectors", %{session: session} do
    Sweet.Recall.open(session)
    append(session, "user", "first paragraph\n\nsecond paragraph")

    texts = session |> Sweet.Recall.history() |> Enum.map(& &1.text)
    assert texts == ["first paragraph", "second paragraph"]

    # There is no vector and there cannot be: there is no embedder in the suite. The paragraph is not
    # lost because of this — it is simply not searched for.
    assert Enum.all?(Sweet.Recall.history(session), &is_nil(&1.vector))
  end

  test "the window tail does not grow together with the conversation", %{session: session} do
    Sweet.Recall.open(session)
    window = Application.fetch_env!(:sweet, :recall_window)

    for n <- 1..(window + 5), do: append(session, "user", "paragraph #{n}")

    tail = :sys.get_state(Sweet.Recall).tails[session]

    # Exactly the window, and these are the last paragraphs — it is for their sake that the tail is kept.
    assert length(tail) == window
    assert Enum.map(tail, &elem(&1, 1)) == for(n <- 2..(window + 5)//1, do: "paragraph #{n}") |> Enum.take(-window)
    assert Enum.all?(tail, fn {role, _text} -> role == "user" end)

    # The history at the same time is whole: the tail is a working cache, and not the limit of the memory.
    assert length(Sweet.Recall.history(session)) == window + 5
  end

  test "the same call in a row leaves one trace", %{session: session} do
    Sweet.Recall.open(session)
    append(session, "user", "question")

    for _ <- 1..3, do: Sweet.Recall.note_tool(session, "<truncated>")

    marks = session |> Sweet.Recall.history() |> Enum.filter(&(&1.role == "tool"))
    assert length(marks) == 1

    # After an ordinary replica the series is counted anew.
    append(session, "assistant", "answer")
    Sweet.Recall.note_tool(session, "<truncated>")

    marks = session |> Sweet.Recall.history() |> Enum.filter(&(&1.role == "tool"))
    assert length(marks) == 2
  end

  test "different calls in a row leave different traces", %{session: session} do
    Sweet.Recall.open(session)
    append(session, "user", "question")

    # This is how records lie down with `truncate_tool_calls: false`: each text has its own.
    Sweet.Recall.note_tool(session, "bash ls -la")
    Sweet.Recall.note_tool(session, "python print(1)")

    texts = session |> Sweet.Recall.history() |> Enum.filter(&(&1.role == "tool")) |> Enum.map(& &1.text)
    assert texts == ["bash ls -la", "python print(1)"]
  end

  test "the trace of a call enters the window tail on a par with the paragraphs", %{session: session} do
    Sweet.Recall.open(session)
    append(session, "user", "question")
    Sweet.Recall.note_tool(session, "<truncated>")

    assert List.last(:sys.get_state(Sweet.Recall).tails[session]) == {"tool", "<truncated>"}
  end

  test "the trace of a call does not weigh in the window of replicas", %{session: session} do
    Sweet.Recall.open(session)
    append(session, "user", "question")
    Sweet.Recall.note_tool(session, "<truncated>")
    append(session, "assistant", "answer")

    # Two replicas are the question and the answer; the trace between them does not eat the window.
    texts = session |> Sweet.Recall.tail(2) |> Enum.map(& &1.text)
    assert "question" in texts
    assert "answer" in texts
  end

  test "a restart of the memory raises both the history and the tail", %{session: session} do
    Sweet.Recall.open(session)
    append(session, "user", "before the restart")

    # We put it out TOGETHER with the table, and not the memory alone. The table is now owned by
    # `Sweet.Tables`, and a restart of the memory alone would leave the index untouched —
    # the check would pass without checking anything. In the tree these two are linked by
    # the strategy `:rest_for_one`: the death of the owner of the table raises anew also
    # the one who fills it. Here we reproduce exactly this, and the bringing up goes
    # honestly — from disk.
    stop_supervised!(Sweet.Recall)
    stop_supervised!(Sweet.Tables)
    start_supervised!(Sweet.Tables)
    start_supervised!(Sweet.Recall)

    assert {:ok, 1} = Sweet.Recall.open(session)
    assert [%{text: "before the restart"}] = Sweet.Recall.history(session)
    assert :sys.get_state(Sweet.Recall).tails[session] == [{"user", "before the restart"}]
  end

  test "a closed session is forgotten from the working maps", %{session: session} do
    Sweet.Recall.open(session)
    append(session, "user", "replica")
    Sweet.Recall.close(session)

    state = :sys.get_state(Sweet.Recall)
    refute Map.has_key?(state.tails, session)
    refute Map.has_key?(state.counters, session)

    # The record itself is in place: they closed the session, and did not erase the conversation.
    assert [%{text: "replica"}] = Sweet.Recall.history(session)
  end

  # A stub embedder: it occupies the name `Sweet.Embed` and forwards to the test that
  # which it was given to encode. Otherwise the window of a paragraph is the only thing that from outside
  # is not visible at all: it exists exactly in order to travel into a vector.
  defmodule FakeEmbed do
    use GenServer

    def start_link(test), do: GenServer.start_link(__MODULE__, test, name: Sweet.Embed)

    @impl true
    def init(test), do: {:ok, test}

    @impl true
    def handle_call({:encode, texts, _kind, _cut}, _from, test) do
      send(test, {:encoded, texts})
      {:reply, {:ok, Enum.map(texts, fn _ -> [1.0, 0.0] end)}, test}
    end
  end

  describe "the window of a paragraph" do
    setup %{session: session} do
      start_supervised!({FakeEmbed, self()})
      Sweet.Recall.open(session)
      :ok
    end

    test "the first paragraph of a session has no window — only itself", %{session: session} do
      append(session, "user", "first")

      assert_receive {:encoded, ["first"]}
    end

    test "the PREVIOUS paragraphs go into the window, and not the following ones", %{session: session} do
      append(session, "user", "one\n\ntwo\n\nthree")

      # Each paragraph — with its own past and without a future. Formerly the first one
      # got "one\n\ntwo\n\nthree": the length of the piece was constant, and
      # the missing past was gathered forward.
      assert_receive {:encoded, ["one", "one\n\ntwo", "one\n\ntwo\n\nthree"]}
    end

    test "further than the window we do not look back", %{session: session} do
      window = Application.fetch_env!(:sweet, :recall_window)
      for n <- 1..(window + 1), do: append(session, "user", "paragraph #{n}")

      # The last paragraph: it itself plus exactly `window` previous ones.
      expected =
        for(n <- 1..(window + 1), do: "paragraph #{n}")
        |> Enum.take(-(window + 1))
        |> Enum.join("\n\n")

      assert_receive {:encoded, [^expected]}
    end
  end

  describe "re-indexing" do
    test "the vector is written by the owner of the table, over the current record", %{session: session} do
      Sweet.Recall.open(session)
      append(session, "user", "paragraph")

      vector = Sweet.Vec.pack([1.0, 0.0, 0.0])
      send(Sweet.Recall, {:reindexed, [{{session, 0}, vector}]})
      sync()

      assert [entry] = Sweet.Recall.history(session)
      assert entry.vector == vector
      assert entry.norm > 0.0
      assert entry.attempts == 1
    end

    test "a failed attempt is counted, the vector is not spoiled", %{session: session} do
      Sweet.Recall.open(session)
      append(session, "user", "paragraph")

      send(Sweet.Recall, {:reindexed, [{{session, 0}, nil}]})
      sync()

      assert [entry] = Sweet.Recall.history(session)
      assert is_nil(entry.vector)
      assert entry.attempts == 1
    end

    test "a paragraph that disappeared during the counting does not come back to life", %{session: session} do
      Sweet.Recall.open(session)

      send(Sweet.Recall, {:reindexed, [{{session, 7}, Sweet.Vec.pack([1.0])}]})
      sync()

      assert Sweet.Recall.history(session) == []
    end
  end
end
