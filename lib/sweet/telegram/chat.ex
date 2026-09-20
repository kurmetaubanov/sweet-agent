defmodule Sweet.Telegram.Chat do
  @moduledoc """
  The process of one chat: everything outgoing into it and the state of the live output.

  Why a separate process. The bridge `Sweet.Telegram` is one for all: it parses the
  updates, runs the sessions, and it also went onto the network. And a trip onto the network is waiting:
  while the bridge uploads a two-megabyte file, it parses nobody's messages
  and shows nobody's answer. One slow chat stopped everyone.

  Now the bridge does not go onto the network at all. It only decides WHAT to say, and
  sends it to the chat; when and how it goes off is the concern of the chat. The conversations
  are isolated: a slow upload in one does not touch the others, and the fall of the
  process of a chat does not bring down the bridge.

  The order is preserved at the same time: messages to one process arrive in the
  order in which they were sent, and are handled one at a time. An answer will not overtake the
  code that preceded it, and the usage will not overtake the answer.

  ## The live output lives here too

  The output of a cell is shown as one message that is appended as the
  work goes: the first non-empty piece establishes it, the following ones edit it, but not more often than
  `telegram_edit_interval_ms`. For this one must remember the id of the message — and the id
  is returned by that very sending which we carried away from the bridge. So the accumulation of
  output moves here too: keep the state where the action happens.
  """

  use GenServer
  require Logger

  alias Sweet.Telegram

  # --- Outside ---

  @doc "Say into the chat. Without waiting: the queue of the chat will send everything in order."
  def say(chat_id, text, opts \\ %{}), do: cast(chat_id, {:say, text, opts})

  @doc "The answer of the agent — as a rich message, with a fallback to an ordinary one (see Telegram.send_rich/2)."
  def rich(chat_id, markdown), do: cast(chat_id, {:rich, markdown})

  @doc """
  Show the code that the agent went off to execute.

  At the same time it closes the previous live output: the next one will go as a new message, and
  will not be appended into a foreign one.
  """
  def code(chat_id, html, opts), do: cast(chat_id, {:code, html, opts})

  @doc "A piece of the output of a cell: establish a message or append to it."
  def output(chat_id, text), do: cast(chat_id, {:output, text})

  @doc "Give the person the files from outbox — after the turn, when everything is appended."
  def flush_outbox(chat_id), do: cast(chat_id, :flush_outbox)

  @doc "Take a sent file into inbox and say where it landed."
  def fetch(chat_id, file_id, name), do: cast(chat_id, {:fetch, file_id, name})

  @doc """
  Confirm a press of a button: without this it "spins" at the person until the
  timeout — Telegram waits for an answer to every callback_query.

  Also through the chat, and not from the bridge: this is a trip onto the network, while the bridge is one for all chats and
  must not stand.
  """
  def ack(chat_id, query_id), do: cast(chat_id, {:ack, query_id})

  @doc """
  Stop the process of a chat. It is called when the chat is closed: there is no reason
  to keep the process, and the live output in it is nobody's already.
  """
  def close(chat_id) do
    case Registry.lookup(Sweet.Telegram.Registry, chat_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Sweet.Telegram.Chats, pid)
      [] -> :ok
    end
  end

  # The process is started on the very first word into the chat and lives on by itself.
  # There is no race: under the key of a chat the Registry allows exactly one process, and
  # the losing start returns the already living one.
  defp cast(chat_id, message) do
    case whereis(chat_id) do
      {:ok, pid} ->
        GenServer.cast(pid, message)

      # The process of the chat did not come up (the supervisor ran into the limit of children, the tree
      # is stopping). Formerly a `case` of two outcomes stood here, and any
      # third threw a `CaseClauseError` in the CALLER — and the caller is the bridge,
      # one for all chats. Losing one message into a chat will not get worse; bringing down the bridge — it will.
      {:error, reason} ->
        Logger.warning("chat #{chat_id} did not come up (#{inspect(reason)}), the message did not go")
        :ok
    end
  end

  defp whereis(chat_id) do
    case Registry.lookup(Sweet.Telegram.Registry, chat_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(Sweet.Telegram.Chats, {__MODULE__, chat_id}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end
    end
  end

  def child_spec(chat_id) do
    %{id: {__MODULE__, chat_id}, start: {__MODULE__, :start_link, [chat_id]}, restart: :temporary}
  end

  def start_link(chat_id) do
    GenServer.start_link(__MODULE__, chat_id, name: {:via, Registry, {Sweet.Telegram.Registry, chat_id}})
  end

  # --- Callbacks ---

  @impl true
  def init(chat_id) do
    {:ok, %{chat_id: chat_id, output: "", output_message: nil, edited_at: 0}}
  end

  @impl true
  def handle_cast({:say, text, opts}, state) do
    Telegram.send_message(state.chat_id, text, opts)
    {:noreply, state}
  end

  def handle_cast({:rich, markdown}, state) do
    Telegram.send_rich(state.chat_id, markdown)
    {:noreply, state}
  end

  def handle_cast({:code, html, opts}, state) do
    Telegram.send_message(state.chat_id, html, opts)
    {:noreply, %{state | output: "", output_message: nil, edited_at: 0}}
  end

  def handle_cast({:output, text}, state) do
    state = %{state | output: state.output <> text}

    cond do
      is_nil(state.output_message) and String.trim(state.output) != "" ->
        case Telegram.send_message(state.chat_id, block(state.output), Telegram.code_opts()) do
          {:ok, id} -> {:noreply, %{state | output_message: id, edited_at: now()}}
          _ -> {:noreply, state}
        end

      state.output_message && now() - state.edited_at >= interval() ->
        Telegram.edit_message(
          state.chat_id,
          state.output_message,
          block(state.output),
          Telegram.code_opts()
        )

        {:noreply, %{state | edited_at: now()}}

      true ->
        {:noreply, state}
    end
  end

  def handle_cast(:flush_outbox, state) do
    Telegram.flush_outbox(state.chat_id)
    {:noreply, state}
  end

  def handle_cast({:ack, query_id}, state) do
    Telegram.answer_callback(query_id)
    {:noreply, state}
  end

  def handle_cast({:fetch, file_id, name}, state) do
    Telegram.fetch_to_inbox(state.chat_id, file_id, name)
    {:noreply, state}
  end

  defp block(output), do: Telegram.output_block(output)
  defp now, do: System.monotonic_time(:millisecond)
  defp interval, do: Application.fetch_env!(:sweet, :telegram_edit_interval_ms)
end
