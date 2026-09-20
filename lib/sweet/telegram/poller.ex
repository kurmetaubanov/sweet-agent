defmodule Sweet.Telegram.Poller do
  @moduledoc """
  Polling Telegram. A separate process, because it hangs almost all the time in
  waiting for an answer: long polling is a request that Telegram keeps
  open until a message appears.

  It decides nothing — it only receives the updates and forwards them to
  `Sweet.Telegram`. It fell (the network, a 502, anything) — the supervisor will bring it up again,
  and the conversations will not be touched: they live in the sessions.

  The offset is stored in the state: Telegram considers an update
  delivered when we have requested the next one after it. To lose it on a
  restart is not scary — Telegram will give the unread ones again.
  """

  use GenServer
  require Logger

  @poll_timeout 25
  @retry_delay_ms 2_000

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    {:ok, %{offset: 0}, {:continue, :poll}}
  end

  @impl true
  def handle_continue(:poll, state) do
    state =
      case Sweet.Telegram.get_updates(state.offset, @poll_timeout) do
        {:ok, updates} ->
          Enum.each(updates, &Sweet.Telegram.incoming/1)
          %{state | offset: next_offset(updates, state.offset)}

        {:error, reason} ->
          # We do not fall on every network hiccup, but we do not stay silent either.
          Logger.warning("telegram: #{inspect(reason)}")
          {:pause, state}

        # An answer of the wrong shape: `{"ok": false, …}` instead of a list of updates,
        # a page from a proxy instead of JSON. Formerly such an outcome matched not a
        # single clause and the polling fell with `CaseClauseError` — and it restarted
        # right there and fell again, exhausting the stock of restarts of the whole node.
        # An external cause is not a reason to die: we wait and try again.
        other ->
          Logger.warning("telegram: unexpected getUpdates answer: #{inspect(other)}")
          {:pause, state}
      end

    case state do
      # A pause after a failure — by a message to ourselves, and not by `Process.sleep`: a sleeping
      # process does not answer even the question "are you alive", and a stop of the stack
      # would wait for its awakening.
      {:pause, state} ->
        Process.send_after(self(), :poll, @retry_delay_ms)
        {:noreply, state}

      state ->
        {:noreply, state, {:continue, :poll}}
    end
  end

  @impl true
  def handle_info(:poll, state), do: {:noreply, state, {:continue, :poll}}

  defp next_offset([], offset), do: offset

  defp next_offset(updates, _offset) do
    updates |> Enum.map(& &1["update_id"]) |> Enum.max() |> Kernel.+(1)
  end
end
