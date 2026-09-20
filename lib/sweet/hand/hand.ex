defmodule Sweet.Hand do
  @moduledoc """
  The hand is a disposable container with a Python kernel, living under a DynamicSupervisor.

  BOUNDARY 2 (container) and BOUNDARY 3 (socket) both pass here:

    * the container is brought up with `cap-drop=ALL`, `no-new-privileges`,
      a read-only rootfs, mem/cpu/pids limits and the `internal` network;
    * communication is TCP with length-framing, NOT distribution and NOT an NIF: the code of the hand
      never gets into the address space of the BEAM.

  The fall of the hand = the fall of one container and one GenServer. The session and the
  brain node are untouched.

  ## Two ways to execute work

  The hand can do two things, and the difference between them is not in the size of the code, but in who
  waits for what:

    * `exec/3` — A CELL. The head waits for its end: this is the answer to a call of the
      tool, and without it the turn of the model will not go further. A timeout here
      means the loss of the state of the kernel, therefore on it the hand dies as a whole.
    * `shell/4` — A BACKGROUND JOB. The head waits for nothing: the command gets a
      name, a log and a return code, the answer comes at once, and about the end the hand will report
      itself with a frame `kind: job` (see `subscribe/2`).

  The second is exactly "the hand works, the head does not". The life of the container at the same time is
  no LONGER tied to one turn of the model: background work survives both the
  end of a cell and the end of a turn.
  """

  use GenServer, restart: :temporary
  require Logger

  defstruct [:pid, :container_id, :name, :conn]

  # --- API ---

  @doc """
  Bring up a hand for the session `session_id`.

  The caller waits for a ready hand — otherwise it has nothing to do with it. But it waits for an
  ANSWER TO THE CALL, and not for the start of the process: `init/1` returns at once, and
  the DynamicSupervisor is free all the time while the container is coming up. Formerly the
  bringing up went inside init, and the supervisor started children one at a time — the hand of one
  session held the hands of all the others.
  """
  def start(session_id) do
    case DynamicSupervisor.start_child(Sweet.Hand.Supervisor, {__MODULE__, session_id}) do
      {:ok, pid} ->
        try do
          {:ok, GenServer.call(pid, :handle, boot_timeout())}
        catch
          :exit, reason -> {:error, {:hand_start_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A reserve on top of waiting for the connection: the same amount goes on tearing down the namesake,
  # creating and starting the container.
  defp boot_timeout, do: Application.fetch_env!(:sweet, :hand_connect_timeout_ms) + 15_000

  @doc """
  Start a shell command as a background job. It answers with a handle, it does not wait.

  There is nothing and no reason to wait here: a command of minutes does not fit into a cell — its
  result is not needed by the model right now, but is needed when the work
  is over. About that the hand will speak itself, through `subscribe/2`.
  """
  def shell(%__MODULE__{pid: pid}, code, job, cwd \\ nil) do
    GenServer.call(pid, {:shell, code, job, cwd}, 30_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :hand_gone}
  end

  @doc """
  Read the state and the log of a background job.

  This is a REQUEST: it waits for an answer and therefore is safe at any moment — the hand
  answers it without touching the work itself.
  """
  def job_read(%__MODULE__{pid: pid}, payload) do
    GenServer.call(pid, {:job_read, payload}, 30_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :hand_gone}
  end

  @doc "Send text into the stdin of a background job: that is how one answers a prompt."
  def job_send(%__MODULE__{pid: pid}, job, text) do
    GenServer.call(pid, {:job_send, job, text}, 30_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :hand_gone}
  end

  @doc """
  A signal into the process group of a job: `:interrupt` (Ctrl-C) or `:kill`.

  It strikes ONE job, and not the hand: the kernel, the variables and the remaining
  jobs are whole: a cell and a shell command are both jobs, and the signal strikes
  exactly the one that is named.
  """
  def job_signal(%__MODULE__{pid: pid}, job, what) do
    GenServer.call(pid, {:job_signal, job, what}, 30_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :hand_gone}
  end

  @doc """
  Subscribe to the events of the hand. `fun` receives an event frame, for example:

      %{"kind" => "job", "event" => "finished", "job" => "j3", "exit" => 0}

  The function is called in the process of the connection (`Sweet.Hand.Listener`), and not in the one
  that is waiting for an answer right now: an event arrives when nobody is there to wait for it.
  """
  def subscribe(%__MODULE__{conn: conn}, fun) do
    if conn, do: Sweet.Hand.Listener.subscribe(conn, fun)
  end

  @doc """
  Run code in the kernel as a background job. It answers with a handle, it does not wait.

  There is nothing and no reason to wait for a cell any longer: it is the same kind of job as a shell
  command, and about its end the hand will speak itself, through `subscribe/2`. The timeout
  remains a watchdog of the hand itself: it did not answer the LAUNCH within
  `hand_exec_timeout_ms` — so it is stuck, and a fresh one will take its place.
  """
  def exec(%__MODULE__{pid: pid}, code, job, notify \\ nil) do
    timeout = Application.fetch_env!(:sweet, :hand_exec_timeout_ms)

    try do
      GenServer.call(pid, {:exec, code, job, notify}, timeout + 5_000)
    catch
      # The hand did not answer even within the external deadline. Dying is its business, and it will
      # do it itself: the waiting task sends it `{:exec_timeout, _}`, by
      # which the hand goes away in its own order and tidies up the container.
      #
      # Formerly `GenServer.stop(pid, :timeout)` stood here, and it held the
      # CALLER: the deadline of `stop` by default is infinite, the hand catches
      # exits, and in its `terminate/2` there is a talk with docker lasting tens of seconds.
      # That is, on an interrupted cell the task of the turn also stopped on the cleanup.
      :exit, {:timeout, _} ->
        {:error, :timeout}

      # The hand has already died by its own timeout — this is a normal outcome, and not a failure.
      :exit, {:noproc, _} ->
        {:error, :timeout}
    end
  end

  def stop(%__MODULE__{pid: pid}), do: GenServer.stop(pid, :normal)

  @doc """
  Kill the hand immediately, without waiting for its consent.

  It is needed for a forced stop: at that moment the hand hangs inside `exec`
  and will get to the messages only when the code finishes counting — that is, `stop/1`
  will wait exactly as long as we are trying to interrupt.

  Since `terminate/2` is not called on `:kill`, we remove the container right here,
  by the id from the handle. `Docker.remove` is idempotent, a repeated call does no harm.
  """
  def kill(%__MODULE__{pid: pid, container_id: container_id}) do
    Process.exit(pid, :kill)

    # Cleanup — by a task, and not here. This is called when the person pressed
    # "stop" and waits for an immediate reaction; there is no reason to make them wait also for
    # a talk with docker. The process of the hand is already dead, the order of cleanup affects nothing.
    if container_id do
      Task.Supervisor.start_child(Sweet.Tasks, fn -> Sweet.Hand.Docker.remove(container_id) end)
    end

    :ok
  end

  # --- Callbacks ---

  def child_spec(session_id) do
    %{id: {__MODULE__, session_id}, start: {__MODULE__, :start_link, [session_id]},
      restart: :temporary}
  end

  def start_link(session_id), do: GenServer.start_link(__MODULE__, session_id)

  # In init — only what cannot be postponed: the name, the registration and the watching over
  # the session. The hand connects ITSELF, therefore one must be listed under one's name
  # BEFORE the start of the container, otherwise it will knock earlier than we are found.
  #
  # Everything else — in handle_continue, and not in this process: the talk with
  # docker goes as a task. To hold it inside one's handler would mean
  # to stand all that time and, worse, to drain foreign messages from one's
  # mailbox (see Sweet.Hand.Docker.recv/5 — that is exactly about this).
  @impl true
  def init(session_id) do
    Process.flag(:trap_exit, true)
    name = "sweet-hand-#{session_id}"
    {:ok, _} = Registry.register(Sweet.Hand.Registry, name, nil)

    # We watch over the session AT ONCE, even before the container: its owner is it, and
    # the hand must not outlive it for a second. Formerly the cleanup rested on
    # `Session.terminate/2`, and it is not always called: the session is temporary
    # (`restart: :temporary`), on an accidental death or `:kill` the termination does not
    # happen at all, and the hand with the container stayed alive until
    # brain — only the removal of the namesake at the next start of the same session saved it.
    # Ownership is supposed to be expressed by watching, and not by cleanup on exit.
    {session, session_ref} = watch_session(name)

    {:ok,
     %{
       name: name,
       container_id: nil,
       conn: nil,
       waiting: [],
       session: session,
       session_ref: session_ref
     }, {:continue, :boot}}
  end

  # We look for the session in the registry by the name of the hand: the name of the session and the name of the hand are linked by one
  # prefix, and this link lives exactly here.
  #
  # There may be no session at all — the hand is also brought up manually, for a check.
  # Then there is nobody to watch over, and the hand lives on its own, as before.
  defp watch_session(name) do
    session_key = "session:" <> String.replace_prefix(name, "sweet-hand-", "")

    case Registry.lookup(Sweet.Hand.Registry, session_key) do
      [{session, _}] ->
        {session, Process.monitor(session)}

      _ ->
        Logger.debug("hand #{name}: there is no session in the registry, nobody to watch over")
        {nil, nil}
    end
  end

  @impl true
  def handle_continue(:boot, state) do
    hand = self()
    name = state.name

    Task.Supervisor.start_child(Sweet.Tasks, fn ->
      # We tear down the namesake, if one remains. The name of the container is constant — by the session,
      # — and docker does not allow creating a second one with the same name, even when the old one
      # has long been dead. And a dead one remains after EVERY restart of brain: the hand
      # loses its master, goes away itself, but there is no one left to remove it. Without this
      # line the agent, after any rebuild, stopped executing code,
      # answering 409.
      Sweet.Hand.Docker.remove(name)

      with {:ok, container_id} <- Sweet.Hand.Docker.create(name),
           :ok <- Sweet.Hand.Docker.start(container_id) do
        send(hand, {:booted, container_id})
      else
        {:error, reason} -> send(hand, {:boot_failed, reason})
      end
    end)

    # The hand may not knock at all — the container did not come up, the network did not let it.
    # Then the waiting ones must learn about it, and not hang until their timeout.
    Process.send_after(self(), :boot_timeout, Application.fetch_env!(:sweet, :hand_connect_timeout_ms))

    {:noreply, state}
  end

  defp handle(state) do
    %__MODULE__{
      pid: self(),
      container_id: state.container_id,
      name: state.name,
      conn: state.conn
    }
  end

  # The session has already been found in `init/1` — the same one we watch over. To look for it
  # in the registry a second time means to assume that the events are owned by one session,
  # while we watch over another.
  defp subscribe_session(%{session: nil} = state, _conn) do
    # Not an error: the hand can be brought up without a session too (a check, a manual launch).
    Logger.debug("events of hand #{state.name} have nobody to go to: there is no session")
  end

  defp subscribe_session(%{session: session}, conn) do
    Sweet.Hand.Listener.subscribe(conn, fn event -> send(session, {:hand_event, event}) end)
  end

  # We give the handle only ready. The hand is still coming up — we postpone the answer,
  # as the listener does with frames: the asker waits for an answer, and we do not
  # wait inside its call.
  @impl true
  def handle_call(:handle, from, %{conn: nil} = state) do
    {:noreply, %{state | waiting: [from | state.waiting]}}
  end

  def handle_call(:handle, _from, state), do: {:reply, handle(state), state}

  # The hand is not (or no longer) in touch, while they ask about work. We answer with a refusal
  # here: having gone into a task with `conn: nil`, we would have called `GenServer.call(nil, …)`
  # — that is an ArgumentError inside the task, that is, there will be no answer at all, and
  # the caller will stand until their timeout. It understands `:hand_gone`: by it the session
  # forgets the hand and brings up a fresh one (see `Sweet.Session.hand_broken/3`).
  def handle_call(_request, _from, %{conn: nil} = state) do
    {:reply, {:error, :hand_gone}, state}
  end

  # Further — requests to the hand, and not one of them is waited for HERE. The answer arrives
  # to the connection, and not to this process, and it can be given to the caller from
  # anywhere: `GenServer.reply/2` exists for that.
  #
  # Formerly every such handler stood in `{:reply, Listener.exec(...), ...}`
  # all the time of the work — for minutes. While it stood, the hand answered NOTHING:
  # neither "show the log of the job", nor "interrupt". A process whose only work
  # is to wait occupied everyone.
  #
  # The waiting is entrusted to a short-lived task. It is not linked to the hand: its fall is
  # not a reason to kill the kernel. The answer to the caller goes off all the same, and as
  # an error, and not as silence (see `relay/2`).
  def handle_call({:shell, code, job, cwd}, from, state) do
    relay(from, fn -> Sweet.Hand.Listener.shell(state.conn, code, job, 30_000, cwd) end)
    {:noreply, state}
  end

  def handle_call({:job_read, payload}, from, state) do
    relay(from, fn -> Sweet.Hand.Listener.job_read(state.conn, payload, 30_000) end)
    {:noreply, state}
  end

  def handle_call({:job_send, job, text}, from, state) do
    payload = %{op: "job_send", job: job, text: text}
    relay(from, fn -> Sweet.Hand.Listener.request(state.conn, payload, 30_000) end)
    {:noreply, state}
  end

  def handle_call({:job_signal, job, what}, from, state) do
    payload = %{op: "job_signal", job: job, signal: to_string(what)}
    relay(from, fn -> Sweet.Hand.Listener.request(state.conn, payload, 30_000) end)
    {:noreply, state}
  end

  # A cell is the same postponed answer, but with a reservation: on a timeout the hand must
  # die, and it decides this itself, not the task. Therefore the task, having answered the
  # caller, calls `stop` — and the hand goes away in its own order, through terminate,
  # having tidied up the container.
  def handle_call({:exec, code, job, notify}, from, state) do
    timeout = Application.fetch_env!(:sweet, :hand_exec_timeout_ms)
    hand = self()

    relay(from, fn ->
      result = Sweet.Hand.Listener.exec(state.conn, code, job, timeout, notify)
      if match?({:error, :timeout}, result), do: send(hand, {:exec_timeout, result})
      result
    end)

    {:noreply, state}
  end

  # The answer to the caller is given by the task: the process of the hand is free at that time.
  #
  # The answer must go off whatever the outcome. The task is not linked either to the hand or to the
  # caller, and nobody noticed its fall: `from` remained without an answer, and the
  # asker stood until their own timeout — thirty seconds of silence
  # instead of an instant error. Therefore an exception and an exit are also an answer.
  defp relay(from, fun) do
    Task.Supervisor.start_child(Sweet.Tasks, fn -> GenServer.reply(from, safely(fun)) end)
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, {:hand_call_crashed, error}}
  catch
    :exit, reason -> {:error, {:hand_call_exit, reason}}
    kind, value -> {:error, {:hand_call_crashed, {kind, value}}}
  end

  # The container is created and started. We wait for the hand to knock itself.
  @impl true
  def handle_info({:booted, container_id}, state) do
    {:noreply, %{state | container_id: container_id}}
  end

  def handle_info({:boot_failed, reason}, state) do
    {:stop, {:hand_start_failed, reason}, state}
  end

  # The hand is in touch: we subscribe the session to its events and release the waiting ones.
  #
  # Events (the end of a background job) are addressed to the SESSION: only it knows, in
  # which turn this happened in and what to do with the result. We look for it in the registry by
  # the name of the hand — the name of the session and the name of the hand are linked by one prefix, and this link
  # lives exactly here.
  def handle_info({:hand_connected, conn}, state) do
    # A monitor on the CONNECTION. Without it the hand outlived its container: the process
    # of the connection died together with it, while `Sweet.Hand` went on living with a dead
    # pid in state.conn and answered `{:error, :hand_gone}` to every request —
    # until the end of the session. The session at the same time watched over the hand ITSELF, and it
    # was alive, therefore the handle was considered good and was handed out again and again.
    # A fresh hand was never brought up.
    Process.monitor(conn)

    state = %{state | conn: conn}
    subscribe_session(state, conn)

    for from <- Enum.reverse(state.waiting), do: GenServer.reply(from, handle(state))

    {:noreply, %{state | waiting: []}}
  end

  # The connection died — so the container died, and there is no hand any more. To pretend
  # that there is one is impossible: the only thing it will be able to do is answer
  # `:hand_gone`. We die ourselves; the session will learn about it through its monitor, forget
  # the handle and at the next call of the tool lazily bring up a fresh hand.
  #
  # The reason :normal: the death of the container is a normal outcome (a timeout, OOM, removal
  # from outside), an error-report with a stacktrace is not needed here. `terminate/2` will remove
  # the container, if it is still whole.
  def handle_info({:DOWN, _ref, :process, conn, reason}, %{conn: conn} = state) do
    Logger.debug("hand #{state.name}: the connection died (#{inspect(reason)})")
    {:stop, :normal, state}
  end

  # The session died — the hand no longer belongs to anyone. We go away in our own
  # order: `terminate/2` will remove the container. The reason :normal — the death of the
  # owner is a normal outcome for the hand, whatever it was for the owner itself.
  def handle_info({:DOWN, ref, :process, _session, reason}, %{session_ref: ref} = state) do
    Logger.debug("hand #{state.name}: the session died (#{inspect(reason)}) — we follow")
    {:stop, :normal, state}
  end

  # It did not knock. There is nothing to answer the waiting ones with — we simply die: their call
  # will come out with this same reason, and there will be no need to sort out two outcomes.
  def handle_info(:boot_timeout, %{conn: nil} = state) do
    {:stop, {:hand_start_failed, {:hand_never_connected, state.name}}, state}
  end

  def handle_info(:boot_timeout, state), do: {:noreply, state}

  # The timeout expired — the hand is dead, full stop. It cannot be left alive for two
  # reasons: it will go on burning cpu in an endless loop, and if the cell
  # does finish writing the answer after all, this frame will be read as the result of the NEXT
  # exec — the protocol will diverge, and the model will silently get a foreign result.
  # The state of the kernel is lost at the same time; the message about the end of the job will honestly
  # tell the model about it.
  #
  # The reason is :normal, and not its own: a timeout of the hand is a normal outcome, and OTP must not
  # print an error-report with a stacktrace for it. What exactly happened is written by
  # Logger.debug in terminate.
  #
  # The decision is made by the hand itself, and not by the task that waited: dying is the business of the process,
  # and not of the one who learned about the death.
  def handle_info({:exec_timeout, _result}, state), do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    Logger.debug("hand #{state.name} down: #{inspect(reason)}")

    # We tidy up ALWAYS, including an accidental exit: otherwise orphans will remain,
    # which will go on eating cpu and the memory of the host.
    # The socket will close by itself together with the container — the handler process of
    # Thousand Island lives exactly as long as the connection.
    Sweet.Hand.Docker.remove(state.container_id)

    :ok
  end
end
