defmodule Sweet.Sessions do
  @moduledoc """
  The registry of sessions: what there was at all, so that one can return to it.

  The paragraphs of conversations themselves lie in `Sweet.Recall`, as a common memory for all sessions.
  Here there is exactly the inventory: when it began, when the last turn was, what it was
  all about and how much it cost. Without it a session exists in the memory, but one cannot
  get to it — nobody remembers the name.

  Its own store, and not a shelf in the common one: the inventory and the memory live by different clocks —
  the inventory is rewritten on every turn and read in full on `/resume`, while the memory
  is only appended. Having mixed them, one would have to separate one from the other on
  every read.

  The title is the first question of the person. It almost always describes the matter better than
  any automatic retelling and costs not a single request to the model.
  """

  use GenServer
  require Logger

  @table :sweet_sessions

  # --- API ---

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Establish a session in the inventory."
  # The timeout is set explicitly: inside there is a write to disk, and the default of 5 seconds brings down
  # the CALLER — that is, the telegram bridge on the path of every /new. Five seconds for a
  # disk is not a reserve, but a coincidence.
  def register(id, chat_id), do: GenServer.call(__MODULE__, {:register, id, chat_id}, 30_000)

  @doc """
  The same, but without waiting: a write to disk must not hold anyone.

  It is called by the bridge on every establishment of a session, and the bridge is one for all chats.
  It does not need an answer: it does not read the established record.
  """
  def register_async(id, chat_id), do: GenServer.cast(__MODULE__, {:register, id, chat_id})

  @doc """
  Mark a turn: the time, the counter and, if it is not there yet, the topic.

  The topic is taken from the first question and does not change any more: a session is about that
  from which it began, and not about where it turned by the hundredth turn.
  """
  def touch(id, question, usage), do: GenServer.cast(__MODULE__, {:touch, id, question, usage})

  @doc "The last sessions of a chat, the fresh ones first."
  def list(chat_id, limit \\ 8) do
    @table
    |> :ets.match_object({:_, %{chat_id: chat_id}})
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.last_at, :desc)
    |> Enum.take(limit)
  end

  @doc "The freshest session of a chat, or nil if the chat is new."
  def latest(chat_id), do: chat_id |> list(1) |> List.first()

  def get(id) do
    case :ets.lookup(@table, id) do
      [{^id, entry}] -> entry
      [] -> nil
    end
  end

  @doc """
  The line for a button: the topic, the age and the cost.

  Telegram truncates the caption of a button, therefore the topic goes first — by it the session
  is recognized, while the figures complement it.
  """
  def label(entry) do
    title = entry.title || "(no topic)"
    "#{String.slice(title, 0, 40)} · #{ago(entry.last_at)} · $#{money(entry.cost)}"
  end

  # --- Callbacks ---

  # The table and the store are not ours: they are owned by `Sweet.Tables` and `Sweet.Memory`.
  # The inventory is read by the telegram bridge (`list/1` on every `/resume`), and a table
  # dying together with us would bring it down instead of answering.
  @store Sweet.Sessions.Store

  @impl true
  def init(_) do
    store = @store

    # We bring the inventory up into ETS: the list is read on every /resume, while writing into
    # it is needed rarely.
    CubDB.select(store) |> Enum.each(fn {id, entry} -> :ets.insert(@table, {id, entry}) end)

    {:ok, %{store: store}}
  end

  @impl true
  def handle_call({:register, id, chat_id}, _from, state) do
    {:reply, register_entry(state, id, chat_id), state}
  end

  @impl true
  def handle_cast({:register, id, chat_id}, state) do
    register_entry(state, id, chat_id)
    {:noreply, state}
  end

  def handle_cast({:touch, id, question, usage}, state) do
    case get(id) do
      nil ->
        Logger.warning("touch of an unknown session: #{id}")

      entry ->
        put(state, %{
          entry
          | last_at: System.os_time(:second),
            title: entry.title || title(question),
            turns: entry.turns + 1,
            cost: entry.cost + Sweet.Cost.of(usage)
        })
    end

    {:noreply, state}
  end

  # --- Internal ---

  # Establish a record, if it is not there yet, and return the one that is now in the inventory.
  #
  # By a separate function, because two paths call it — both with waiting and without.
  # Formerly `handle_cast` called `handle_call/3` directly, having substituted `nil`
  # instead of `from`: it worked exactly because `from` was not used, and it would have
  # diverged at the very first `GenServer.reply/2` in the handler. The common
  # place of two paths is work, and not a foreign handler.
  defp register_entry(state, id, chat_id) do
    case get(id) do
      nil ->
        now = System.os_time(:second)

        put(state, %{
          id: id,
          chat_id: chat_id,
          created_at: now,
          last_at: now,
          title: nil,
          turns: 0,
          cost: 0.0
        })

      existing ->
        existing
    end
  end

  defp put(state, entry) do
    :ets.insert(@table, {entry.id, entry})
    :ok = CubDB.put(state.store, entry.id, entry)
    entry
  end

  # The first line of the question: further on there are usually details, while in the caption of a button
  # little will fit anyway.
  defp title(nil), do: nil

  defp title(question) do
    question
    |> String.split("\n")
    |> List.first()
    |> String.trim()
    |> String.slice(0, 60)
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp ago(at) do
    case System.os_time(:second) - at do
      seconds when seconds < 3600 -> "#{div(seconds, 60)} min"
      seconds when seconds < 86_400 -> "#{div(seconds, 3600)} h"
      seconds -> "#{div(seconds, 86_400)} d"
    end
  end

  defp money(amount), do: :erlang.float_to_binary(amount * 1.0, decimals: 3)
end
