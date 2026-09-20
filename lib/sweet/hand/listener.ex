defmodule Sweet.Hand.Listener do
  @moduledoc """
  Accepting connections from the hands and the embedder. The direction is inverted: it is not the brain
  that knocks on the container, but the container on the brain.

  Why it is so:

    * one does not have to guess when the container has managed to come up — formerly there were 40
      connection attempts with pauses in the loop, now the container itself reports
      readiness;
    * the container does not open ports at all — from the point of view of boundary 2 this is cleaner;
    * one listening socket for all instead of a port for each.

  The framing `{:packet, 4}` + JSON is common to all who connect,
  therefore `server.py` and `embedder.py` speak the same way.

  ## About the reading modes

  The socket is read ONLY by messages, through `handle_data`. Manual
  `Socket.recv/3` is not here and must not be: Thousand Island switches the
  socket into active mode after `handle_connection`, and a frame that arrived at
  the junction of the two modes is lost forever — the request hangs until the timeout.
  That is how it was while the handshake was read out manually.

  Therefore the handshake is not a separate stage of reading, but a STATE of the connection:

      :hello  — we wait for a frame of the representation {"op":"hello","id":...}
      :ready  — the working state

  There is no race by construction, and not because we watch for it.

  ## An answer and an event are different things

  In the `:ready` state a frame is of two kinds, and to distinguish them is obligatory:

    * `{"kind":"result"}` — an ANSWER to a request. It is given to the one who waits
      (`waiting`), and the waiting ends on it;
    * `{"kind":"job"}` — an EVENT on its own initiative: background work
      is over. Nobody waits for it and nobody requested it — it came in the
      middle of someone else's request or in complete silence.

  Formerly any frame except `stream` was considered an answer: the waiter took
  the first one that came. The very first event about a background job would have travelled to the model
  as the result of its request — it would have received someone else's result, and lost
  its own. Therefore the kind of the frame is now stated explicitly, and not derived from
  “everything that is not stream”.

  ## The request number

  There may be several waiters: the hand is free during `exec`, and while
  the cell computes, it is legitimately asked about background jobs. Since that is so,
  the answers must be distinguished — otherwise the second request would overwrite the waiter of the first, and
  that one would receive someone else's frame. We distinguish by a number: `rid` is put on the request here
  and is returned in the answer by that side (`server.py`, `embedder.py`).

  The number is needed for the streaming output too: a `stream` knows whose cell it
  belongs to, and goes to the one who asked for notifications about exactly that one.

  A frame that could not be parsed at all has no number: then ALL the waiters
  learn about the error. To leave them hanging until the timeout is worse —
  it broke for one, while the silence falls to everyone.
  """

  use ThousandIsland.Handler

  require Logger

  @doc """
  Execute code through the connection with the hand.

  `notify` — to whom to send the output appearing WHILE the code works. The listener sends
  it directly, bypassing `Sweet.Hand`: that one is blocked inside its `handle_call`
  and will sort out the mail only after the end of the execution — that is, the live output
  would stop being live.
  """
  def exec(conn, code, job, timeout, notify \\ nil) do
    request(conn, %{op: "exec", code: code, job: job}, timeout, notify)
  end

  @doc """
  Start a shell command as a background job.

  It returns at once, with a handle: to wait for the end of the work here is impossible — that is exactly
  the point. About the end the hand will report itself with the `kind: job` frame, and it will go to the
  subscriber of events, and not to the waiter.
  """
  def shell(conn, code, job, timeout, cwd \\ nil) do
    request(conn, %{op: "shell", code: code, cwd: cwd, job: job}, timeout)
  end

  @doc "Read the state and the log of a background job. It waits for an answer: this is a request."
  def job_read(conn, payload, timeout) do
    request(conn, Map.put(payload, :op, "job_read"), timeout)
  end

  @doc """
  Send a request and wait for an answer frame.

  Not only the hand uses this same connection: the embedder lives in its own
  container and speaks by this same protocol, only the content of the
  frame differs.
  """
  def request(conn, payload, timeout, notify \\ nil) do
    GenServer.call(conn, {:request, payload, notify}, timeout + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :hand_gone}
  end

  @doc """
  Send a frame WITHOUT waiting for an answer and without taking the place of a waiter.

  Needed for interruption: while the hand computes, `Sweet.Hand` is locked inside its
  `handle_call`, while this connection is free — it does not wait for an answer, but merely
  remembers whom to give it to. Therefore the signal goes here and now, bypassing
  the queue.
  """
  def signal(conn, payload), do: GenServer.cast(conn, {:signal, payload})

  @impl ThousandIsland.Handler
  def handle_connection(_socket, state) do
    # We read nothing: the first frame will come by itself, in handle_data.
    {:continue,
     Map.merge(state, %{stage: :hello, id: nil, waiting: %{}, next_rid: 1, on_event: nil})}
  end

  @impl ThousandIsland.Handler
  def handle_data(frame, _socket, %{stage: :hello} = state) do
    with {:ok, %{"op" => "hello", "id" => id}} <- JSON.decode(frame),
         [{owner, _}] <- Registry.lookup(Sweet.Hand.Registry, id) do
      send(owner, {:hand_connected, self()})
      {:continue, %{state | stage: :ready, id: id}}
    else
      other ->
        # A stranger, or nobody waits for it — there is no reason to keep the connection.
        Logger.warning("handshake failed: #{inspect(other)}")
        {:close, state}
    end
  end

  def handle_data(frame, _socket, %{stage: :ready} = state) do
    case decode(frame) do
      # A frame on its own initiative: output that appeared while the code is still working.
      # It is not an answer to a request and does not release the waiter.
      {:ok, %{"kind" => "stream", "text" => text} = live} ->
        # The cell has no waiter any more: the brain received the answer about its launch
        # at once, before the first line of output. Therefore the live output is just as much an
        # event as the end of a job, and goes to the same place: to the session, which alone
        # knows whom to show it to.
        case waiting_notify(state, live["rid"]) do
          nil -> deliver_event(state, live)
          notify -> send(notify, {:hand_output, live["name"] || "stdout", text})
        end

        {:continue, state}

      # An event of a background job. Nobody can wait for it: the turn of the model by
      # that moment is either busy with something else or long over. It goes to
      # the subscriber of events — and does NOT touch the waiter.
      {:ok, %{"kind" => "job"} = event} ->
        deliver_event(state, event)
        {:continue, state}

      {:ok, %{"kind" => "result"} = answer} ->
        {:continue, answer_to(state, answer["rid"], {:ok, answer})}

      # The frame was not parsed: whose it is is unknown, and there is no number in it either.
      # We tell everyone who waits: this answer was intended for one of them, while
      # the rest had better learn about the breakage at once than hang until the timeout.
      {:error, reason} ->
        case Map.values(state.waiting) do
          [] ->
            Logger.warning("an unrecognized frame from the hand: #{inspect(reason)}")

          waiting ->
            Logger.warning("an unrecognized frame from the hand: #{inspect(reason)}")
            for {from, _notify} <- waiting, do: GenServer.reply(from, {:error, reason})
        end

        {:continue, %{state | waiting: %{}}}

      {:ok, other} ->
        # A frame not by our protocol: there are three kinds of frame, and the fourth is
        # an error on that side, and not an answer.
        Logger.warning("an unfamiliar frame from the hand: #{short(other)}")
        {:continue, state}
    end
  end

  # The answer — to the one who waits under this number. There is no number, or the waiter has already
  # fallen off by timeout — we throw the frame away: to give it to someone else
  # means to slip a foreign result to the model.
  defp answer_to(state, rid, reply) do
    case Map.pop(state.waiting, rid) do
      {nil, _} ->
        Logger.warning("an answer frame without a waiting request: rid=#{inspect(rid)}")
        state

      {{from, _notify}, waiting} ->
        GenServer.reply(from, reply)
        %{state | waiting: waiting}
    end
  end

  defp waiting_notify(state, rid) do
    case Map.get(state.waiting, rid) do
      {_from, notify} -> notify
      nil -> nil
    end
  end

  defp deliver_event(%{on_event: nil}, event) do
    Logger.warning("a hand event without a subscriber: #{short(event)}")
  end

  defp deliver_event(%{on_event: fun}, event), do: fun.(event)

  defp short(map) when is_map(map) do
    map |> Map.take(["kind", "rid", "job", "event", "error"]) |> inspect()
  end

  defp short(other), do: inspect(other)

  # We do not wait for the answer here synchronously (see above about the modes): we remember whom to
  # answer to, and give the result from handle_data when the frame arrives.
  @impl GenServer
  def handle_call({:request, payload, notify}, from, {socket, state}) do
    rid = state.next_rid
    waiting = sweep(state.waiting)

    case ThousandIsland.Socket.send(socket, JSON.encode!(Map.put(payload, :rid, rid))) do
      :ok ->
        {:noreply,
         {socket, %{state | waiting: Map.put(waiting, rid, {from, notify}), next_rid: rid + 1}}}

      {:error, reason} ->
        {:reply, {:error, reason}, {socket, %{state | waiting: waiting}}}
    end
  end

  # Forget the waiters that are no longer there.
  #
  # A waiter exits by its own deadline (`request/4` catches `:timeout`), while its
  # place in the map remained until the arrival of the frame or until the death of the connection —
  # that is, the map grew on every answer that did not return, and on a long-lived connection
  # of a hand that is hours of work. The callers here are the short-lived tasks `relay/2`:
  # having waited out the deadline, they leave at once, and the sign “there is no process” is exact.
  #
  # The cleanup is lazy, at the entrance of a new request, and not by a monitor: a monitor
  # would demand its own `handle_info/2` in the connection handler, where
  # the socket messages are disposed of by Thousand Island, — a superfluous link for the sake
  # of a map of a few records.
  defp sweep(waiting) do
    Map.reject(waiting, fn {_rid, {{pid, _tag}, _notify}} -> not Process.alive?(pid) end)
  end

  @doc """
  Subscribe to the events of the hand. The function is called from the connection process —
  that is, by the one who is free, and not by the one who is now waiting for an answer.
  """
  def subscribe(conn, fun) when is_function(fun, 1) do
    GenServer.cast(conn, {:subscribe, fun})
  end

  @impl GenServer
  def handle_cast({:subscribe, fun}, {socket, state}) do
    {:noreply, {socket, %{state | on_event: fun}}}
  end

  def handle_cast({:signal, payload}, {socket, state}) do
    ThousandIsland.Socket.send(socket, JSON.encode!(payload))
    {:noreply, {socket, state}}
  end

  defp decode(frame) do
    case JSON.decode(frame) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:bad_frame, reason}}
    end
  end
end
