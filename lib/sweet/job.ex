defmodule Sweet.Job do
  @moduledoc """
  A background job — with its own process and its own record in the registry.

  A job outlives the turn that started it: the turn ends, while the work in the
  hand goes on. So the account of the job must also live longer than the turn. Formerly it lived in
  two maps of the session state — `jobs` and `job_asks` — and was filled in where the
  job is started, that is, IN THE TASK OF THE TURN (`Sweet.Session.run_tool/3` goes
  under `Task.Supervisor`). And the task returns to the session only the history, the cost and the
  turns: the state with the recorded job died together with it. The session
  remained with empty maps — and silently everything that looks at them broke:

    * the "still running" line in `take_inbox` showed NOT A SINGLE job;
    * the death of the hand did not find the jobs about which the model had to be told — it
      decided that the work was going on and waited for an event that would not come;
    * the ceiling of a job never fired, exactly in the case for the sake of
      which it was established;
    * the `Map.delete` in the handler of the end of a job deleted out of emptiness.

  Six tests written for the previous edit did not catch this: they set
  the state directly through `:sys.replace_state/2`, that is, they check the
  HANDLERS of events, and not the recording into the account. While the recording goes where the state
  of the session is inaccessible altogether.

  Why a process, and not a common table. The account is the fact "the work is going on", and it has
  an owner: the job itself. While the owner is alive, the record exists; it died — the registry
  took it off itself (the owner of a record in `Registry` is the process that established it).
  A separate record remains from exactly one thing: the job ended otherwise than
  expected. A forgotten record is worse than a missing one — the session counts the work as going and
  tells the model about it.

  The deadline of a job is also here, and not in the session. Formerly the timer was set for the session, and on a
  firing for a long-finished job one had to answer with the check
  "and is it still in the maps". Now the timer belongs to the job and goes away
  together with it: there is nothing to check.
  """

  use GenServer, restart: :temporary
  require Logger

  @registry Sweet.Job.Registry
  @supervisor Sweet.Job.Supervisor

  # --- API ---

  @doc """
  Establish a name for a job — BEFORE it is launched.

  The name is needed earlier than the answer of the hand: the call is shown to the person at once, and without a
  name there is nothing to write above the code. To wait for the answer for the sake of a line in the chat would mean
  making the rendering depend on the network, and "there is no answer — show without a
  hash" would have to be built as a separate branch. Its own name removes both
  at once.

  The hand takes the name sent to it as it is and does not invent its own; by itself it establishes
  names only for jobs started from inside a cell (`bash()`) — no request goes there.
  Both ends take six random bytes, therefore there are two sources, while the
  form of the name is still one.

  Six bytes, and not `make_ref/0`: the name travels to the model and the person, and it must
  be short and pronounceable. For the same reason there is a hash here, and not a counter —
  the model would take a number for "how many jobs there were before".
  """
  def new_id, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  @doc """
  Take a job into the account. `job` is the hash of the hand, `code` is what was launched.

  It is called FROM THE TASK OF THE TURN, and this is the only place where the account is established.
  It returns at once: establishing a record is not work, there is no reason to wait for it.

  `pid` is the number of the process INSIDE the container of the hand. It is not addressable from
  here — the hand lives in its own PID namespace, and there is no channel between us except frames —
  therefore it is a LABEL, and not a handle: by it the person and the model see that the line of the brain
  and the line of the hand speak about one and the same process. To act on a job is possible
  only by its hash.
  """
  def start(session, session_id, job, code, pid \\ nil) do
    DynamicSupervisor.start_child(
      @supervisor,
      {__MODULE__, %{session: session, session_id: session_id, job: job, code: code, pid: pid}}
    )
  end

  @doc """
  What is going on at the session: the name, the code, the question if the job asked it, the process,
  the launch and the ceiling.

  The order is by the hash of the job. This travels into the context, and the context would change
  from the order for no reason at all: the model would see different hints on one
  and the same state.
  """
  def list(session_id) do
    # A record in the registry is `{key, owner, value}`: in the selection the third
    # is the value, and not the process. We do not take the owner at all — by it we have anyway
    # chosen our jobs — and the selection by a key-pair is exactly the reason
    # for which the jobs have their own registry: the registry of hands has one key, and there is
    # nothing to assemble the jobs of a session by it with.
    @registry
    |> Registry.select([{{{session_id, :"$1"}, :_, :"$3"}, [], [{{:"$1", :"$3"}}]}])
    |> Enum.map(fn {job, record} -> Map.put(record, :job, job) end)
    |> Enum.sort_by(& &1.job)
  end

  @doc """
  One line about a job: the name, the process, the launch and the deadline.

  The SAME line goes both into the inbox (the "still running" line of `take_inbox/1`) and into
  the answer of `job_list`: the model must not see two different pictures of one state.
  The code of the job does not go here — the line travels into the context at every turn, while
  "what was launched" is asked for separately and rarely (see `Sweet.Session.run_tool/3`).
  """
  def line(%{job: job} = record) do
    parts =
      [
        where(record),
        "started #{clock(record.started_at)} (#{ago(record.started_at)}), hard limit #{short(record.limit_ms)}, " <>
          "deadline #{clock(deadline(record))} (#{left(record)})"
      ]

    Enum.join(["job #{job}" | Enum.reject(parts, &is_nil/1)], "  ")
  end

  # --- the parts of the line ---

  # A separate line for the pid, and not a field in the middle: for a job started by a hand of an
  # older shape the number does not come at all, and an empty place in the middle would read as zero.
  defp where(%{pid: pid}) when is_integer(pid), do: "pid #{pid}"
  defp where(_record), do: nil

  defp deadline(%{started_at: started, limit_ms: limit}), do: started + limit

  defp clock(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_time()
    |> Time.to_iso8601()
    |> String.slice(0, 8)
    |> Kernel.<>("Z")
  end

  defp ago(started), do: short(System.system_time(:millisecond) - started)

  defp left(record) do
    case deadline(record) - System.system_time(:millisecond) do
      ms when ms > 0 -> "in #{short(ms)}"
      _ms -> "overdue"
    end
  end

  # A length of time in the units in which it is read: seconds up to a minute, then minutes and seconds.
  defp short(ms) when ms < 60_000, do: "#{max(div(ms, 1_000), 0)} s"
  defp short(ms), do: "#{div(ms, 60_000)} m #{div(rem(ms, 60_000), 1_000)} s"

  @doc "The process of a job, if it is still running. `nil` — it is no longer there."
  def find(session_id, job) do
    case Registry.lookup(@registry, {session_id, job}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  A job asks for input: we remember WHAT it asks with. This travels to the model.

  There may be no line at all — the prompt does not always go into the log (`read -p`
  prints it only when stdin is a terminal). "A question without a line" and "it does not
  ask at all" are different things, and `nil` differs from an empty string here.
  """
  def ask(session_id, job, ask), do: cast(session_id, job, {:ask, ask})

  @doc "A job received an answer and went on: the waiting account is taken off."
  def resumed(session_id, job), do: cast(session_id, job, :resumed)

  @doc """
  A job is over. The cleanup of the account is the business of the session, and not of the handler of the event, and
  by a separate function: the event about the end may not arrive (the hand died), while
  the record must go away.
  """
  def finish(session_id, job) do
    case find(session_id, job) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@supervisor, pid)
    end
  end

  @doc """
  Forget all the jobs of a session: their processes are the processes of the hand and died together with it.

  It returns what was listed — the session must tell the model which exactly
  work is lost. The list is taken BEFORE the stop: after it the registry is empty.
  """
  def forget_all(session_id) do
    jobs = list(session_id)
    for %{job: job} <- jobs, do: finish(session_id, job)
    jobs
  end

  defp cast(session_id, job, message) do
    case find(session_id, job) do
      nil -> :ok
      pid -> GenServer.cast(pid, message)
    end
  end

  # --- Callbacks ---

  def child_spec(%{job: job} = arg) do
    %{id: {__MODULE__, job}, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}
  end

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(%{session: session, session_id: session_id, job: job, code: code, pid: pid}) do
    # The ceiling is taken from the config HERE, and not at the firing of the timer: the config is
    # read once at the launch of the job, so that an edit of the number does not move the deadline
    # of a job that is already going. The same number goes into the line of the accounting.
    limit = Application.fetch_env!(:sweet, :job_hard_limit_ms)

    # The record is established by the PROCESS of the job ITSELF: the owner of a record in `Registry` is the one
    # who established it, so with its death the record goes away by itself. To establish it from
    # the session would mean to keep the account on a process that the job outlives.
    {:ok, _} =
      Registry.register(@registry, {session_id, job}, %{
        code: code,
        ask: nil,
        pid: pid,
        started_at: System.system_time(:millisecond),
        limit_ms: limit
      })

    # A job belongs to the session: its death is ours too. There are no abandoned
    # jobs, and the cleanup after a session is the responsibility of its own supervisor.
    session_ref = Process.monitor(session)

    timer = Process.send_after(self(), :overdue, limit)

    {:ok,
     %{
       session: session,
       session_id: session_id,
       job: job,
       session_ref: session_ref,
       timer: timer
     }}
  end

  @impl true
  def handle_cast({:ask, ask}, state) do
    update(state, ask)
    {:noreply, state}
  end

  def handle_cast(:resumed, state) do
    update(state, nil)
    {:noreply, state}
  end

  # The ceiling. It is counted by the session, and not by the hand: the watchdog of the hand looks at the process, while
  # a process is sometimes alive and silent, waiting for nothing. A job speaks about itself to the
  # session — it alone knows how to put a line into the inbox and raise a turn.
  @impl true
  def handle_info(:overdue, state) do
    Logger.info(
      "job #{state.job}: the ceiling of #{Application.fetch_env!(:sweet, :job_hard_limit_ms)} ms expired"
    )

    send(state.session, {:job_hard_limit, state.job})
    {:noreply, state}
  end

  # The session is gone — the job follows it: the work of the hand without a conversation is needed
  # by no one, and its processes live only as long as the container is alive.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{session_ref: ref} = state) do
    Logger.debug("the session is gone (#{inspect(reason)}) — job #{state.job} follows it")
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp update(state, ask) do
    Registry.update_value(@registry, {state.session_id, state.job}, &Map.put(&1, :ask, ask))
  end
end
