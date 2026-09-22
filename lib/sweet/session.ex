defmodule Sweet.Session do
  @moduledoc """
  The agent loop. One session = one GenServer + one hand.

      ask → assemble the context → LLM → is there a tool_use? → execute in the hand
          → the result back to the LLM → ... → the answer

  The turn is performed NOT in the GenServer itself, but in a separate task under
  `Sweet.Tasks` and without a link to the session. Otherwise the session is busy for the whole time of the turn and
  hears nothing — including the command “stop”. The task sends the session pieces of
  text, while the hand and the mailbox are owned by the session: the task asks it for them.

  The state of the session lives HERE, and not in the harness modules — so that hot reload
  of the harness does not require `code_change/3`. The history is stored as a list of maps,
  not structs: a struct on a version swap breaks pattern matches in other
  processes, a map does not.
  """

  use GenServer, restart: :temporary
  require Logger

  # --- API ---

  @doc """
  Raise a session. The process name is the key in the registry, `session:<id>`, and by the same
  one the hand finds the session in order to send the event of a background job.

  The name is set HERE, and not by registration inside `init/1`, and this is not cosmetics.
  While the registration was a step of initialization, a second start with the same id
  went through: the key was taken, `Registry.register` returned an error, and the process
  came up all the same — nameless. After that the person talked to one session,
  while the events of jobs went by name to another, and the deferred result never
  reached the conversation.

  With `{:via, Registry, ...}` OTP settles the collision and settles it BEFORE `init/1`:
  the second start receives `{:error, {:already_started, pid}}`, and all that is left to the caller
  is to take that living session (see `Sweet.start/1`).
  """
  def start_link(opts) do
    # we invent the id HERE, if it was not given: the process name is needed before init/1, and
    # there are no more nameless sessions. The IEx front calls `Sweet.start()` without an
    # id — it will get a random one, as before.
    id = Keyword.get(opts, :id) || random_id()
    GenServer.start_link(__MODULE__, Keyword.put(opts, :id, id), name: via(id))
  end

  @doc "The name of the session in the registry. The hand looks it up by the same key."
  def via(id), do: {:via, Registry, {Sweet.Hand.Registry, "session:" <> id}}

  # The common deadline for waiting for a session's answer. The only place where it waits
  # for someone else is the raising of its own memory in `handle_continue(:open, _)`, and that
  # lasts up to a minute. That means the asker is obliged to wait just as long: both the one
  # who adopts the session (`adopt/2`) and the one who stops it (`cancel/1`).
  @call_timeout 60_000

  @doc """
  Ask a question. The answers come to the subscriber as messages:

      {:sweet_turn, session, question}       the turn began
      {:sweet_delta, session, text}          a piece of text as it is generated
      {:sweet_tool, session, code, lang}     the agent went to execute code
      {:sweet_done, session, {:ok, text}}    the turn is over

  About `{:sweet_turn, ...}`: the subscriber learned about the end of the turn by a message, and about
  the beginning it did not, and it had to start a record about the turn at its own
  discretion: a question came from the person — so it has begun. While a turn
  could be started only by a question, the guess coincided with the truth. With a turn that
  is raised by the end of a background job (see `start_turn/2`) — it stopped. The beginning of
  a turn deserves its own event: whoever leads the turn, that one announces it.

  The pid of the session comes first — a subscriber may listen to several sessions at once,
  and without it it would have to guess whose answer this is. The Telegram bridge guessed
  exactly that way: it took the first record from its map of waiting turns.
  """
  def ask_async(pid, text, subscriber \\ self()) do
    GenServer.cast(pid, {:ask, text, subscriber})
  end

  @doc """
  A forced stop. Kills the task of the turn and the hand together with the executing
  code; the waiter receives `{:sweet_done, session, {:error, :cancelled}}`.

  The history is preserved at the same time — the broken-off turn remains in it as it is,
  so that the next question goes with a comprehensible context.

  The deadline is set explicitly and coincides with the deadline of `adopt/2`, and for the same reason: a session
  is sometimes busy raising its own memory (`handle_continue(:open, _)`) for up to a minute.
  The default of five seconds is not a margin, but a coincidence, and it cost dearly: `/stop`
  calls the Telegram bridge DIRECTLY, an exit from the call would carry it away together with the session,
  that is, all the chats at once.

  We catch the exit right here too: not to wait for the stop is not a reason for the one who
  asked for it to fall. We answer `{:error, reason}`, as `adopt/2` does.
  """
  def cancel(pid) do
    GenServer.call(pid, :cancel, @call_timeout)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Tokens spent for the session."
  def usage(pid) do
    GenServer.call(pid, :usage, @call_timeout)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Name oneself the session's listener anew and learn whether it has a turn going.

  It is needed by the one who did not raise the session but is obliged to hear it — by the Telegram bridge
  after its own restart. The bridge keeps maps of chats and turns in memory,
  and its fall left living sessions without an addressee: the answer of an ongoing turn
  went into the warning “answer without a waiting turn”, and there was nobody
  to put out “typing…”.

  One ought to ask the one who knows: whether a turn is going is known to the session
  itself.

  It answers `:running` or `:idle`; `{:error, reason}` — if the session has died
  or has not answered. The adopter must not wait for it forever: it adopts them all,
  and one busy one must not leave the rest without an addressee.
  """
  # The deadline is common with `cancel/1` — see `@call_timeout`.
  def adopt(pid, subscriber) do
    GenServer.call(pid, {:adopt, subscriber}, @call_timeout)
  catch
    :exit, reason -> {:error, reason}
  end

  # --- Callbacks ---

  # The paragraph about leave for edits is not written here: it comes from `Sweet.Harness.Prompt`
  # (see `edits_rule/1`). One copy of the rule for the system prompt, for the reply of the person
  # and for the result of a tool — two versions of one rule diverge at the very first edit of one of them.

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)

    # Without trap_exit terminate/2 is not called: DynamicSupervisor.terminate_child
    # sends exit(:shutdown), and a process that does not catch exits dies at once. The hand
    # then outlives its session — in dev this is an abandoned python, in prod an
    # abandoned CONTAINER for every closed session.
    Process.flag(:trap_exit, true)

    # The hand is raised lazily, at the first execution of code: an empty conversation
    # is not worth a container.
    #
    # The session's memory is raised not here, but in `handle_continue(:open, _)`:
    # `Sweet.Recall.open/1` is a call to the ONE process of memory for the whole system,
    # and it goes through the session's history. While it stood in `init/1`, the one
    # who was raising the session stood behind it too — the Telegram bridge, one for all
    # chats. A busy memory stopped all the conversations at once. Now the start
    # returns immediately, and the memory is raised right after.
    {:ok,
     %{
       id: id,
       hand: nil,
       hand_ref: nil,
       history: [],
       turns: 0,
       usage: %{input: 0, output: 0},
       task: nil,
       # When the turn began by the monotonic clock. The turn's clock is held by the SESSION, and not
       # by the task: the turn ends for the person when the session has accepted the result and
       # given it to the bridge — while the task does not know about that moment and cannot
       # know. We count monotonically: setting the system clock in the middle of a turn must
       # not give a negative time.
       turn_started: nil,
       subscriber: nil,
       # There are no jobs among the fields, and this is a substantive edit. Formerly they lay
       # here as two maps — `jobs` and `job_asks` — and were filled in the task of the
       # turn, that is, NOT HERE: the task gives the session the history, the usage and the rounds,
       # while the state into which it wrote a job dies together with it.
       # The session was left with empty maps, and everything that looks at them silently
       # did not work. Now the accounting lives in the job itself, and the session asks
       # the registry. In detail — in Sweet.Job.
       # Who waits for the hand while it is coming up. The hand is owned by the session, and only
       # by it: formerly the handle also lived in the task's copy of the state, and two
       # truths diverged silently. The container starts within up to a minute, therefore
       # we raise it NOT in the handler — the session is obliged to hear both the person
       # and the hand all that time, — and we give the answer to the waiters when the hand is up.
       hand_waiting: [],
       hand_starting?: false,
       # The task that raises the hand. We keep it HERE, and do not forget it right after
       # the launch: while nobody watched it, its death meant nothing — and
       # the ones waiting for the hand stand `:infinity` (see `ensure_hand/1`) and would hang forever.
       hand_task: nil,
       # ONE mailbox for everything incoming: both the utterances of the person and the results of jobs.
       # Formerly there were two — the utterance went into the task's mail, the result lay
       # in its own queue, — and both paths branched by “a turn is going / is not going”.
       # There is no division any more: a turn waits for nothing, therefore one may put into the mailbox
       # always, and the turn takes the mailbox at the boundary of a round; what did not make it — the
       # next turn will pick it up, and it will begin straight away.
       #
       # A record is %{text: a headline for the person and the memory, block: a block of the model}.
       inbox: [],
       # The last subscriber, who is NOT forgotten with the end of a turn. Needed
       # for exactly one thing: to tell the person “the background work is over” when
       # there is no turn at all. A chat is not a task of the turn, it outlives both the turn and the pause.
       watcher: nil,
       # Whom the session owes a hand event: the name of the hand -> a function. The subscription lives
       # in the connection, but to forget it is the session's duty — otherwise after a long
       # silence the event will again turn out to be “nobody's”.
       job_events: []
     }, {:continue, :open}}
  end

  # The session's memory from disk: after a restart of the brain the conversation continues from
  # the place where it broke off.
  #
  # Here, and not in `init/1`: the one who raised the session is free from the first second, while
  # the session itself will wait for the memory. The first question arrives later anyway —
  # it comes as a separate message and will queue up behind this handler,
  # that is, the order “first we raised the memory, then we spoke” is preserved
  # by the message queue, and not by someone's waiting.
  @impl true
  def handle_continue(:open, state) do
    Sweet.Recall.open(state.id)
    {:noreply, state}
  end

  @impl true
  # The words of the person. The only path: into the mailbox — and, if there is no turn, start a turn.
  # Formerly there were two clauses here: a turn is going — the text went into the task's mail
  # ({:steer, ...}) and Ctrl-C went to the hand so that the boundary came sooner; there is no
  # turn — a turn was raised. The task's mail died together with the task, and an utterance
  # that arrived during the final generation was lost entirely. Ctrl-C is no longer
  # needed and is harmful: the cell now runs as a background job, and to interrupt
  # ordered work with it there is no reason — the boundary of a round comes by itself.
  def handle_cast({:ask, text, subscriber}, state) do
    state = put_inbox(state, text, %{"type" => "text", "text" => text})
    state = %{state | watcher: subscriber}

    if state.task do
      send(subscriber, {:sweet_steer, self(), text})
      {:noreply, %{state | subscriber: subscriber}}
    else
      {:noreply, start_turn(state, subscriber)}
    end
  end

  # The hand is alive as a process, but unfit: its connection (and with it the container) is dead,
  # and it answers only `{:error, :hand_gone}`. Such a one we forget and put out, without
  # waiting for the end of the turn — the next call of a tool will raise a fresh one.
  #
  # It comes from the TASK, because it is the one that learns about it: the hand's answer is visible at
  # the place of the call. To forget and to put out is the owner's business, that is, the session's.
  def handle_cast({:hand_broken, %{pid: pid}}, %{hand: %{pid: pid}} = state) do
    Logger.info("the hand is unfit (:hand_gone) — we forget it and put it out")
    if state.hand, do: safe_stop(state.hand)
    {:noreply, forget_hand(state)}
  end

  # We are talking about a hand that the session no longer has: a report came about one already forgotten.
  def handle_cast({:hand_broken, _hand}, state), do: {:noreply, state}

  @impl true
  def handle_call(:cancel, _from, %{task: nil} = state), do: {:reply, {:error, :idle}, state}

  def handle_call(:cancel, _from, state) do
    Task.shutdown(state.task, :brutal_kill)

    # We kill the hand too: without this python will go on computing what is already
    # needed by nobody, and the next exec will read its frame as its own answer.
    # Exactly kill, and not stop: the hand is now hanging inside exec and will reach a polite
    # request only when the code has finished computing — exactly what we
    # are interrupting.
    if state.hand, do: Sweet.Hand.kill(state.hand)

    # There may be no subscriber at all: a turn started by the end of a background job
    # takes `watcher` as its subscriber, and that one is sometimes empty. `send(nil, ...)` is
    # an ArgumentError right in the handler, that is, the death of the session and the fall
    # of the one who called `cancel`: the Telegram bridge.
    if state.subscriber, do: send(state.subscriber, {:sweet_done, self(), {:error, :cancelled}})

    # We forget the hand through forget_hand/1: to take off the monitor is half the job,
    # and it was exactly this half that was forgotten here by hand. The remaining monitor then brought
    # `:DOWN`, which is no longer parsed by anyone.
    {:reply, :ok, %{forget_hand(state) | task: nil, subscriber: nil, turn_started: nil}}
  end

  def handle_call(:usage, _from, state), do: {:reply, state.usage, state}

  # A new listener in place of the former one. We set `watcher` always — the ends of background
  # jobs are addressed to it, and they happen without a turn too. `subscriber` only
  # if a turn is going: it lives exactly as long as the turn, and to start it on
  # an empty place means to promise an answer that nobody is preparing.
  def handle_call({:adopt, subscriber}, _from, state) do
    state = %{state | watcher: subscriber}

    if state.task do
      {:reply, :running, %{state | subscriber: subscriber}}
    else
      {:reply, :idle, state}
    end
  end

  # The hand on a request from a task. There is one — we give it at once; there is none — we put the request in
  # a queue and raise it ONCE for all the waiters: two calls of a tool
  # that came together must not raise two containers.
  #
  # A live one — at once, as it is counted. We do not try to
  # distinguish here a hand that died a moment ago: its `:DOWN` is already on its way and will be parsed by the
  # regular handler when the queue reaches it.
  #
  # Formerly there stood here a manual `receive` by the monitor's reference: the session took
  # `:DOWN` out of its own mailbox ahead of the queue and recursively called its own
  # `handle_info/2` from `handle_call/3`. This gave the task a fresh hand instead of
  # `:hand_gone` — but at the price of bypassing the mail discipline of GenServer: the order
  # of messages stopped being the one in which they came, and the handler was called
  # not by the server, but by another handler.
  #
  # A doomed handle is no trouble: the task will receive `{:error, :hand_gone}`, will tell the
  # session about it through `hand_broken/3` — and that one will forget the hand, and the NEXT call
  # of a tool will raise a fresh one. This path already exists in the code and works.
  def handle_call(:hand, _from, %{hand: hand} = state) when not is_nil(hand) do
    {:reply, {:ok, hand}, state}
  end

  def handle_call(:hand, from, state) do
    state = %{state | hand_waiting: state.hand_waiting ++ [from]}

    if state.hand_starting? do
      {:noreply, state}
    else
      id = state.id

      # `async_nolink`, and not `start_child` with `send`: the answer to the waiters comes
      # only from the body of the task, and its death for any reason (an exception, kill,
      # the stopping of `Sweet.Tasks`) left `hand_starting?` raised forever, and
      # all those waiting for the hand — standing without a deadline. The observation gives a second outcome,
      # `:DOWN`, and it too answers the waiters — with a refusal.
      task = Task.Supervisor.async_nolink(Sweet.Tasks, fn -> Sweet.Hand.start(id) end)

      {:noreply, %{state | hand_starting?: true, hand_task: task}}
    end
  end

  # The task of the turn takes the mailbox at the boundary of a round. That is exactly how both the words of the person
  # and the events of jobs get into an ongoing turn: to keep them in the task's mail is impossible
  # — the task does not know when the boundary will come, while the session knows, and, unlike
  # the task, it outlives that boundary.
  def handle_call(:take_inbox, _from, state) do
    {blocks, state} = take_inbox(state)
    {:reply, blocks, state}
  end

  @impl true
  def handle_info({:delta, text}, state) do
    if state.subscriber, do: send(state.subscriber, {:sweet_delta, self(), text})
    {:noreply, state}
  end

  # The stream has fallen silent. We tell the person at once: it sees only “typing…” and
  # does not distinguish a thinking model from a hung request.
  def handle_info({:notice, text}, state) do
    if state.subscriber, do: send(state.subscriber, {:sweet_notice, self(), text})
    {:noreply, state}
  end

  # The word of the agent before the calls. Its own channel, and not `:notice`, for one
  # thing: they have a DIFFERENT meaning. “The stream has fallen silent” — about the fact that nothing
  # is happening; the remark — about the fact that quite a lot is happening. Under one
  # icon they read the same.
  def handle_info({:aside, text}, state) do
    if state.subscriber, do: send(state.subscriber, {:sweet_aside, self(), text})
    {:noreply, state}
  end

  # The language comes from the one who called the tool, and is not guessed from the text:
  # the hand executes python and bash by different operations, and which of them is working
  # is known at the place of the call. The subscriber needs it in order to label the block of code
  # honestly: without the language the Telegram client determines it itself and on a short
  # shell one-liner misses, showing bash as python.
  def handle_info({:tool, code, lang}, state) do
    if state.subscriber, do: send(state.subscriber, {:sweet_tool, self(), code, lang})
    {:noreply, state}
  end

  # The events of a background job. There are three kinds of them, and this is NOT one and the same:
  #
  #   * `finished` — the job is over, there is a return code. The work is done;
  #   * `waiting`  — the job stands ON A QUESTION. The process is alive and waits for a line in
  #     stdin (visible by the kernel: what the process sits on and which pipe its
  #     fd 0 points at). The work is not done and will not do itself;
  #   * `stale`    — there has been silence in the output for a long time. This is a DEADLINE, not a fact: a build and a
  #     snapshot are silent too, and one must not declare them hung.
  #
  # Formerly the kind was one, and any frame meant the end: the job was crossed out
  # of the accounting, and “finished” was substituted into the text. An event of waiting would have gone
  # by the same path — that is, it would have taken an ongoing job off the accounting, and the next
  # event about it would have fallen into “an event without a case”.
  def handle_info({:hand_event, %{"kind" => "job", "event" => "finished"} = event}, state) do
    Logger.info("job #{event["job"]} is over: code #{event["exit"]}")

    # To the person — at once, if it is still listening: it ordered the work and must
    # learn that it is over, even if in that time it asked nothing.
    if state.watcher, do: send(state.watcher, {:sweet_job, self(), job_headline(event)})

    # We take off the accounting HERE too, and not only by the event: the event about the end comes
    # not always — the hand could have been killed, and then there will be none at all.
    Sweet.Job.finish(state.id, event["job"])
    state = put_inbox(state, job_headline(event), %{"type" => "text", "text" => job_notice(event)}, :trace)

    {:noreply, if(state.task, do: state, else: start_turn(state, state.watcher))}
  end

  # The job asks for input. Background work has no turn, therefore nobody except
  # this note will tell the model about it: the work stands until it is answered.
  #
  # The job is NOT taken off the accounting: it is going, and `take_inbox` is obliged to see it
  # in the line “still running”. Taking off is a sign of the end, and its place is only in the
  # `finished`.
  def handle_info({:hand_event, %{"kind" => "job", "event" => "waiting"} = event}, state) do
    Logger.info("job #{event["job"]} asks for input: #{inspect(event["ask"])}")

    # We do not tell the person: the line “asks for input” gives it nothing — the answer
    # is needed not from it, but from the model (or a signal, if there is nothing to answer with).
    Sweet.Job.ask(state.id, event["job"], event["ask"] || "")
    state = put_inbox(state, job_headline(event), %{"type" => "text", "text" => job_notice(event)}, :trace)

    {:noreply, if(state.task, do: state, else: start_turn(state, state.watcher))}
  end

  # The job has been silent for a long time. The mark is by the same rights as “asks for input”:
  # into the mailbox, and a turn, if there is no turn.
  #
  # There will be no repeats: the hand sets the event once per band of silence and
  # takes it off when the output has started again.
  def handle_info({:hand_event, %{"kind" => "job", "event" => "stale"} = event}, state) do
    Logger.info("job #{event["job"]} has been silent for #{event["quiet_s"]} s")

    state = put_inbox(state, job_headline(event), %{"type" => "text", "text" => job_notice(event)}, :trace)

    {:noreply, if(state.task, do: state, else: start_turn(state, state.watcher))}
  end

  # The job received an answer and went on. The accounting of “waiting for input” is taken off, and
  # the reminder in `take_inbox` comes no more: without this the session would until the very
  # end of the job be telling the model about a question that was answered long ago.
  #
  # Nothing is put into the mailbox: “the job went on” is not something for which
  # it is worth raising a turn of the model.
  def handle_info({:hand_event, %{"kind" => "job", "event" => "resumed"} = event}, state) do
    Logger.debug("job #{event["job"]} received an answer and is going on")

    Sweet.Job.resumed(state.id, event["job"])
    {:noreply, state}
  end

  # The ceiling of a job. The hand's watchdog looks at the PROCESS: whether it asks for input and
  # how long it has been silent in the output. About a process that is going and waits for nothing
  # it has nothing to say. Here the count is different and external: “this job has been going
  # half an hour” the session knows itself, without the hand and without the network, — and this is the only
  # mark that will fire even if the hand's watchdog goes dumb together with the hand.
  def handle_info({:job_hard_limit, job}, state) do
    # The timer is set by the job itself and goes away together with it (see Sweet.Job):
    # “it is over, but the timer fired” is impossible by construction. The check is needed
    # for exactly one thing — between the sending and this handler the job could go away
    # together with the hand.
    if Sweet.Job.find(state.id, job) do
      Logger.info("job #{job}: the ceiling of #{Application.fetch_env!(:sweet, :job_hard_limit_ms)} ms has expired")
      text = job_notice(%{"event" => "overdue", "job" => job})

      state = put_inbox(state, text, %{"type" => "text", "text" => text}, :trace)
      {:noreply, if(state.task, do: state, else: start_turn(state, state.watcher))}
    else
      {:noreply, state}
    end
  end

  # The live output of a cell that runs in the background. It has no waiter — the brain received the
  # answer about the launch at once, — therefore the frame comes as an event. It does not go
  # to the model: it will get the result when the job is over. This is for the person.
  def handle_info({:hand_event, %{"kind" => "stream"} = event}, state) do
    watcher = state.subscriber || state.watcher
    if watcher, do: send(watcher, {:sweet_output, self(), event["name"] || "stdout", event["text"]})
    {:noreply, state}
  end

  def handle_info({:hand_event, other}, state) do
    Logger.debug("a hand event without a case: #{inspect(other)}")
    {:noreply, state}
  end

  # The output of the code as it appears — to show the person what is happening while
  # the turn is still going. It is not written into the history: the result will get there — whole, from
  # the message about the end of the job.
  def handle_info({:hand_output, name, text}, state) do
    if state.subscriber, do: send(state.subscriber, {:sweet_output, self(), name, text})
    {:noreply, state}
  end

  def handle_info({:hand_error, text}, state) do
    if state.subscriber, do: send(state.subscriber, {:sweet_error, self(), text})
    {:noreply, state}
  end

  # The hand is up (or is not up). We take it under observation here, and not in the task that
  # raised it: the task will die, while to own the hand and watch it must be done by
  # the one who outlives it.
  def handle_info({ref, result}, %{hand_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, hand_started(%{state | hand_task: nil}, result)}
  end

  # The task of the raising died without answering. We answer the waiters with a refusal: the next
  # call of a tool will try again, while for them to stand without a deadline is impossible.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{hand_task: %Task{ref: ref}} = state) do
    Logger.warning("the task of raising the hand died: #{inspect(reason)}")
    {:noreply, hand_started(%{state | hand_task: nil}, {:error, {:hand_start_crashed, reason}})}
  end

  def handle_info({ref, {status, reply, history, usage, turns}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    total = add_usage(state.usage, usage)

    # The usage as a separate message, BEFORE the answer: the subscriber needs both the figures of the turn and
    # the accumulated ones for the session, while the format {:sweet_done, ...} one does not want to change —
    # the IEx front is tied to it too.
    if state.subscriber do
      send(state.subscriber, {:sweet_usage, self(), usage, total, elapsed(state)})
      send(state.subscriber, {:sweet_done, self(), {status, reply}})
    end

    # `turns` came for one turn — the rounds of the cycle with a tool. In the session
    # we keep the sum: it is needed only for the inventory, while the fuse looks at
    # the turn (see Sweet.Harness.Policy).
    state = %{
      state
      | task: nil,
        subscriber: nil,
        history: history,
        turns: state.turns + turns,
        usage: total,
        turn_started: nil
    }

    # The mailbox could have filled up while the final generation was going: a job ended
    # or the person said another word. There are no more rounds with a tool at that moment,
    # and there was nowhere for the turn to take them — and formerly they lay until
    # the next question. Now the turn simply starts again, at once.
    {:noreply, if(state.inbox == [], do: state, else: start_turn(state, state.watcher))}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    if state.subscriber,
      do: send(state.subscriber, {:sweet_done, self(), {:error, {:turn_crashed, reason}}})
    {:noreply, %{state | task: nil, subscriber: nil, turn_started: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{hand_ref: ref} = state) do
    # The hand died by itself (fell, exited by timeout, was killed). The session is alive — we simply
    # forget the hand, the next need for execution will raise a fresh one.
    #
    # Jobs die TOGETHER with the hand: they are its processes. To be silent about this is impossible —
    # the model will decide that the work is going and will wait for an event that will not be.
    Logger.debug("hand died: #{inspect(reason)}")

    state = %{state | hand: nil, hand_ref: nil}

    case Sweet.Job.forget_all(state.id) do
      [] ->
        {:noreply, state}

      jobs ->
        lost = Enum.map_join(jobs, ", ", &"job #{&1.job}")

        notice =
          "the hand died (#{inspect(reason)}) together with its background jobs: #{lost}. " <>
            "They have no results — the kernel and their processes are lost."

        state = put_inbox(state, notice, %{"type" => "text", "text" => notice}, :trace)

        {:noreply, if(state.task, do: state, else: start_turn(state, state.watcher))}
    end
  end

  # Exits because of `trap_exit` in `init/1`: it stands for the sake of `terminate/2`, and not
  # for the sake of turns — a turn is now under a supervisor and is not linked (see `start_turn/2`).
  # A separate clause is needed so that `EXIT` does not vanish in the catch-all below: a silently
  # swallowed signal is a breakage that nobody will learn about.
  def handle_info({:EXIT, pid, reason}, state) do
    Logger.debug("exit of a linked process #{inspect(pid)}: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("session #{state.id}: a message without a case #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.hand, do: safe_stop(state.hand)
    Sweet.Recall.close(state.id)
  end

  # The outcome of raising the hand is one for both outcomes: the hand is up or the raising failed.
  # We answer the waiters always, otherwise they stand without a deadline.
  defp hand_started(state, result) do
    state = if match?({:ok, _}, result), do: track(state, elem(result, 1)), else: state

    for from <- state.hand_waiting, do: GenServer.reply(from, result)

    %{state | hand_waiting: [], hand_starting?: false}
  end

  # --- The turn, performed in a separate task ---

  # `question` is what was asked now. The context for it is assembled
  # anew on every round of the cycle: after the execution of code there are already
  # new paragraphs in the memory, and they may turn out to be needed.
  defp run(state, session, question, messages \\ nil) do
    messages = messages || Sweet.Harness.Prompt.build(state, question)
    on_delta = fn text -> send(session, {:delta, text}) end
    on_notice = fn text -> send(session, {:notice, text}) end

    case Sweet.LLM.stream(messages, on_delta,
           system: Sweet.Harness.Prompt.system(state),
           on_notice: on_notice
         ) do
      {:ok, %{stop_reason: "tool_use", content: content} = answer} ->
        state = account(state, answer)
        state = %{state | history: state.history ++ [%{role: "assistant", content: content}]}

        # What the agent said BEFORE taking up the tools. Formerly these
        # words were seen by nobody: from the answer with calls only the blocks
        # `tool_use` were taken, while the text lying next to them went into the turn's history and died
        # together with it. The person at the same time saw WHAT was being launched, and did not see
        # WHY — between the question and the answer there stood a wall of code blocks.
        #
        # As the channel we take `:notice` — the same one by which “the stream has fallen silent” is said:
        # it already reaches the chat and is already arranged as “a word along the way, and not an
        # answer”. Its own channel this does not require.
        say_aside(session, content)

        uses = tool_uses(content)
        {results, state} = Enum.map_reduce(uses, state, &run_tool(&1, &2, session))

        # The trace of the calls in the memory — HERE, for the whole batch at once: what exactly
        # is left of a call is visible only by its answer, while the answers come
        # from `run_tool/3` together with `results`.
        state = note_tools(state, uses, results)

        # Within one turn the messages grow as they are: the protocol requires
        # keeping the pair tool_use/tool_result next to each other, and by a selection from the memory it cannot
        # be substituted. Through the memory pass COMPLETED turns, not the current one.
        # Everything from the mailbox — both the words of the person and the ends of jobs — we put into THE SAME
        # user message as the results of the tools: between tool_use and
        # tool_result there is no room for a foreign message, while two user messages in a row
        # the API will not accept. Within the content the blocks are listed freely.
        #
        # Formerly the mailbox was glued on AFTER the results had already gone into the
        # history, and did not get into the history: one thing went off to the API, and
        # another remained in the memory of the turn.
        results = results ++ pull_inbox(session)

        state = %{
          state
          | history: state.history ++ [%{role: "user", content: results}],
            turns: state.turns + 1
        }

        messages =
          messages ++
            [
              %{"role" => "assistant", "content" => for_api(content)},
              %{"role" => "user", "content" => results}
            ]

        if Sweet.Harness.Policy.continue?(state) do
          run(state, session, question, messages)
        else
          {:error, :budget_exhausted, state.history, state.usage, state.turns}
        end

      {:ok, %{content: content} = answer} ->
        state = account(state, answer)
        state = %{state | history: state.history ++ [%{role: "assistant", content: content}]}
        reply = text_of(content)
        Sweet.Recall.append(state.id, "assistant", reply)
        {:ok, reply, state.history, state.usage, state.turns}

      {:error, reason} ->
        {:error, reason, state.history, state.usage, state.turns}
    end
  end

  # The trace of tool calls in the memory — ONE SHORT LINE per call.
  #
  # The output of a background job does not enter here and cannot: a job answers
  # with a handle, while the output will arrive later — with its own message about the end, and into the memory it
  # will fall from there (see `job_headline/1`), also as one line.
  #
  # Formerly there lay here the call WHOLE — the name of the tool and its input in JSON, that
  # is, the whole launched script, — plus the answer. A script of a hundred lines got into the
  # memory verbatim, and all that for one thing: so that later it could be seen what was done.
  # For “what was done” the first line of the code and the job's hash are enough, while all
  # the rest lies in the log and is retrieved through read_log.
  #
  # A vector is never computed from such a record: calls are not searched by meaning.
  # They get into the selection ATTACHED to their utterance (see Sweet.Recall.search/2) —
  # that is what the hash in the line is for.
  defp note_tools(state, uses, results) do
    for {use, result} <- Enum.zip(uses, results) do
      Sweet.Recall.note_tool(state.id, tool_note(use, result))
    end

    state
  end

  # The launch of work: what was launched and what job it became.
  defp tool_note(%{"name" => name, "input" => input}, result)
       when name in ["python", "bash", "elixir"] do
    "#{name} #{first_line(input["code"])}#{job_of(result)}"
  end

  # Reading a log: ONLY the call itself, without what was read. What was read is re-readable
  # by the same command — to keep it in the memory as well means to store a copy of a file
  # that has an address.
  defp tool_note(%{"name" => "read_log", "input" => input}, _result) do
    "read_log #{input["job"]}"
  end

  # The list of jobs has no parameters: the generic branch below would glue "{}" to the
  # name as if it meant something.
  defp tool_note(%{"name" => "job_list"}, _result), do: "job_list"

  # A question to one's own memory. The QUERY travels into the trace, and not the summary of the
  # answer: the query is what this call is recognized by and what it is later found by.
  defp tool_note(%{"name" => "recall", "input" => input}, _result) do
    "recall #{first_line(input["query"])}"
  end

  # Interference in an ongoing job: the call and what it answered. Their answer is short
  # by construction (“sent to job ...”, “interrupted”), and it is genuine here —
  # these tools answer at once.
  defp tool_note(%{"name" => name, "input" => input}, result) do
    call = "#{name} #{input["job"] || first_line(JSON.encode!(input))}"

    case result["content"] do
      content when is_binary(content) and content != "" ->
        call <> " — " <> first_line(content)

      _other ->
        call
    end
  end

  # The job's hash from the tool's answer. We take it by parsing the string, and not by a separate
  # field: the tool's answer is text for the model, and to start next to it
  # a second, service channel for the sake of one hash is dearer than to read it here.
  defp job_of(%{"content" => content}) when is_binary(content) do
    case Regex.run(~r/job started in background, (\S+)/, content) do
      [_, job] -> " -> job #{job}"
      _ -> ""
    end
  end

  defp job_of(_result), do: ""

  # The first non-empty line, briefly: into the trace goes what the call is recognized by,
  # and not what it did as a whole.
  defp first_line(nil), do: ""

  defp first_line(text) do
    text
    |> String.split("\n")
    |> Enum.find("", &(String.trim(&1) != ""))
    |> String.trim()
    |> String.slice(0, 100)
  end

  # A cell of the kernel. It answers with a handle at once, like a shell command: the turn waits
  # for nothing, the result will come as an event and will fall into the mailbox. Formerly `exec` held the turn
  # for as long as the cell was computing — because of this the turn was divided into “while we
  # compute” and “between calls”, and everything that arrived in the first half
  # waited for the second.
  defp run_tool(%{"id" => id, "name" => "python", "input" => %{"code" => code}}, state, session) do
    job = Sweet.Job.new_id()
    send(session, {:tool, with_job(job, code), cell_lang(code)})

    # The code of the call — into the log. It deliberately does not get into the memory (see below), into the chat
    # it goes off and is lost there, while when a turn hits the limit one has to sort it out
    # by the figures “request went off / answer in N ms” — from them one cannot see
    # what exactly the agent was spinning round and round.
    Logger.info("python call (job #{job}):\n#{code}")

    # The trace of the call in the memory is set by `run/4`, when the answer becomes visible too. Here
    # it is absent deliberately: the cell answers with the job's handle, and not with output.
    #
    # A vector is NEVER computed from a call (see `Sweet.Recall.note_tool/2`), and
    # this is the main thing. While it was computed, the calls squeezed everything
    # else out of the selection: a script as a whole is one paragraph without empty lines, there are tens of
    # such per turn, they resemble one another, and the first places by closeness
    # went to them, and not to what the person and the agent said in words.
    start_job(id, job, state, session, fn hand -> Sweet.Hand.exec(hand, code, job) end, code)
  end

  # A background shell command. It answers with a handle at once — this is exactly the
  # non-blocking turn: the work goes on in the hand, while the head is free. About the end the hand
  # will report itself, and the result will arrive at the boundary of the next round or with a new
  # turn (see handle_info/2 and take_inbox/1).
  defp run_tool(%{"id" => id, "name" => "bash", "input" => input}, state, session) do
    code = input["code"] || ""
    job = Sweet.Job.new_id()
    send(session, {:tool, with_job(job, code), "bash"})
    Logger.info("bash call (job #{job}):\n#{code}")

    start_job(id, job, state, session, fn hand -> Sweet.Hand.shell(hand, code, job, input["cwd"]) end, code)
  end

  # A script in Elixir. By its own tool, and not `bash` with `elixir -e`, for two
  # reasons: through the shell the code travels with foreign escaping — quotation marks, sigils
  # and heredocs are mangled even before the launch, — and the person in the chat sees the label
  # `bash` under what is in fact Elixir.
  #
  # There is no kernel here: every call is its own BEAM, the state between calls does not
  # live. This is more honest than to imitate a kernel: to keep a living node in the hand means
  # to start a second long-liver similar to the `python` kernel, with its own death,
  # restart and loss of state — while `python` for state already exists.
  defp run_tool(%{"id" => id, "name" => "elixir", "input" => input}, state, session) do
    code = input["code"] || ""
    job = Sweet.Job.new_id()
    send(session, {:tool, with_job(job, code), "elixir"})
    Logger.info("elixir call (job #{job}):\n#{code}")

    start_job(
      id,
      job,
      state,
      session,
      fn hand -> Sweet.Hand.shell(hand, elixir_script(code), job, input["cwd"]) end,
      code
    )
  end

  # Reading a background job's log. This is a REQUEST: it waits for an answer and does not
  # touch the work — that way one can look into an ongoing command without hindering it.
  #
  # The only path to a job's output. The event about the end shows the head and the
  # tail (see output_block/1), everything else lives in the log and is addressed
  # by the job's HASH: where the file lies the model does not know and has no need to know.
  defp run_tool(%{"id" => id, "name" => "read_log", "input" => input}, state, session) do
    # Into the chat and into the log — the CALL ITSELF, without what was read. The model can read a log
    # in tens of kilobytes, and to dump that on the person would mean to give it
    # exactly what we spared the context from. We show the parameters: without them
    # one cannot distinguish “read the whole log” from “took three lines by a mask”.
    call = read_log_call(input)
    send(session, {:tool, call, "tool"})
    Logger.info("call #{call}")

    payload = %{
      "job" => input["job"],
      "head" => input["head"],
      "tail" => input["tail"],
      "grep" => input["grep"]
    }

    ask(id, state, session, fn hand -> Sweet.Hand.job_read(hand, payload) end)
  end

  # What the hand is doing at all. Two sources, and one line out of them:
  #
  #   * the accounting of the BRAIN (`Sweet.Job.list/1`) — the hash, the number of the process, the
  #     launch, the ceiling and what was launched;
  #   * the table of the HAND (`job_list` in the handout) — what state each process is in right now
  #     and how long ago it last spoke.
  #
  # The hashes agree, and the numbers of the processes too (the hand gives out the number at the
  # launch, and the brain writes it into the accounting), therefore the two lines speak about one and
  # the same job. The hand also sees jobs the brain does NOT know — those started from inside a
  # cell (`bash()`): the line about them comes without a hash of the brain.
  #
  # The records of the brain that the hand does NOT know are dropped right here (see
  # `forget_missing/3`): this is the only place where both accounts lie side by side.
  #
  # The line is assembled by `Sweet.Job.line/1` here, and by the hand — `describe_job/1` there. They
  # are assembled in one order and out of the same parts on purpose: a second picture of one state
  # would be a second truth.
  defp run_tool(%{"id" => id, "name" => "job_list", "input" => input}, state, session) do
    send(session, {:tool, "job_list", "tool"})
    Logger.info("job_list call, jobs_in_hand: #{inspect(input)}")

    ours = Map.new(Sweet.Job.list(state.id), &{&1.job, &1})

    case ensure_hand(session) do
      {:ok, hand} ->
        case Sweet.Hand.job_list(hand) do
          {:ok, %{"result" => jobs, "error" => ""}} when is_list(jobs) ->
            forget_missing(state.id, ours, jobs)
            {tool_result(id, job_list_text(ours, jobs)), state}

          {:ok, %{} = answer} ->
            {tool_result(id, "the hand answered with something else: #{inspect(answer)}", true), state}

          {:error, reason} ->
            hand_broken(session, hand, reason)
            {tool_result(id, "the hand is unavailable: #{inspect(reason)}", true), state}

          other ->
            {tool_result(id, "unexpected answer from the hand: #{inspect(other)}", true), state}
        end

      {:error, reason} ->
        {tool_result(id, "the hand is unavailable: #{inspect(reason)}", true), state}
    end
  end

  # A signal into the process group of ONE job. The kernel and the rest of the work are intact —
  # that is the difference from /stop, which kills the hand entirely.
  defp run_tool(%{"id" => id, "name" => "job_signal", "input" => input}, state, session) do
    what = if input["signal"] == "kill", do: :kill, else: :interrupt

    # We take the job's command BEFORE the signal: after it the job is taken off the accounting,
    # and there would be nothing to show. “Killed job 59hd” tells the person
    # nothing, “killed the build of the image” tells everything.
    call = signal_call(state, input["job"], what)
    send(session, {:tool, call, "tool"})
    Logger.info("job_signal call: job #{input["job"]} #{what}")

    ask(id, state, session, fn hand -> Sweet.Hand.job_signal(hand, input["job"], what) end)
  end

  # An answer into the stdin of a background job — the thing by which a prompt is let go. The channel existed
  # on both sides from the very beginning (`job_send` in the hand, `Sweet.Hand.job_send`
  # here), but it had no caller: it was not given to the model. Without it
  # the only answer to “Shall I install Hex?” remained a signal.
  defp run_tool(%{"id" => id, "name" => "job_send", "input" => input}, state, session) do
    # We add the newline here, and do not ask the model for it: `read` and
    # `IO.gets` wait for a newline, while “answer exactly y” and “send y with a newline”
    # are two different things, and there is no way to err here.
    text = input["text"] || ""
    text = if String.ends_with?(text, "\n"), do: text, else: text <> "\n"

    # This is the ONLY tool that writes into a living process, and to show
    # one answer alone is not enough: “y” by itself says nothing, while the difference between
    # “y to continue the build” and “y to delete the volume” is everything. Therefore next to it
    # go the job's command and its question.
    #
    # We ask BEFORE the sending: the answer takes off the sign of waiting, and after the call
    # there is no longer a question in the accounting.
    call = send_call(state, input["job"], text)
    send(session, {:tool, call, "tool"})
    Logger.info("job_send call: job #{input["job"]} <- #{inspect(String.trim_trailing(text))}")

    ask(id, state, session, fn hand -> Sweet.Hand.job_send(hand, input["job"], text) end)
  end

  # A question to one's own memory. It is answered here, without the hand: the memory lies
  # in the brain, and the hand is not mounted there at all — in its container there are only
  # /workspace, /skills and the CA. The model's query goes to the same search by meaning as the
  # automatic block, only with a query of its own instead of the window with the question.
  #
  # The trace of the call is written by `note_tools/3` along with the rest, as one short line
  # and without a vector. The paragraphs that came back are NOT written anywhere: they would
  # then be found by the next automatic query and arrive a second time as "what was said".
  # The answer itself, like any `tool_result`, lives only in this turn.
  defp run_tool(%{"id" => id, "name" => "recall", "input" => input}, state, session) do
    query = input["query"] || ""

    call = "recall #{first_line(query)}"
    send(session, {:tool, call, "tool"})
    Logger.info("call #{call}")

    answer =
      case Sweet.Recall.search(query, input["take"]) do
        {:ok, []} ->
          tool_result(id, "nothing found by meaning for this query.")

        {:ok, found} ->
          found = Enum.map(found, fn {_score, entry} -> {0.0, :memory, entry} end)
          tool_result(id, Sweet.Harness.Prompt.found_text(found))

        {:error, reason} ->
          tool_result(id, "the memory is unavailable: #{inspect(reason)}", true)
      end

    {answer, state}
  end

  defp run_tool(%{"id" => id, "name" => name}, state, _session) do
    {tool_result(id, "unknown tool: #{name}", true), state}
  end

  # The hand answered with a refusal by which it is visible that it is unfit: its connection is
  # dead (:hand_gone) or it is stuck (:timeout). We tell the session — it is the
  # owner, it must forget and put out. The other reasons do not concern the hand.
  defp hand_broken(session, hand, reason) when reason in [:hand_gone, :timeout] do
    GenServer.cast(session, {:hand_broken, hand})
  end

  defp hand_broken(_session, _hand, _reason), do: :ok


  # A request to the hand: the answer comes and is given to the model RIGHT HERE.
  #
  # These three tools launch nothing — they read a file, write a line into
  # stdin, send a signal. All this is already done by the moment of the answer, and their answer is
  # the result itself, and not a hash. To give instead of it a receipt “the answer will come
  # as a message” would mean to drive the model after something ready a second time, paying
  # with an extra boundary of the turn for work that does not exist.
  #
  # The deadline of the exchange is 30 seconds, but this is a ceiling in case the hand goes dumb: by
  # measurements the exchange takes units of milliseconds.
  defp ask(id, state, session, call) do
    case ensure_hand(session) do
      {:ok, hand} ->
        case call.(hand) do
          {:ok, %{"stdout" => text, "error" => ""}} ->
            {tool_result(id, if(String.trim(text) == "", do: "(empty)", else: text)), state}

          {:ok, %{"error" => error}} when is_binary(error) and error != "" ->
            {tool_result(id, error, true), state}

          {:error, reason} ->
            hand_broken(session, hand, reason)
            {tool_result(id, "the hand is unavailable: #{inspect(reason)}", true), state}

          other ->
            {tool_result(id, "unexpected answer from the hand: #{inspect(other)}", true), state}
        end

      {:error, reason} ->
        {tool_result(id, "the hand is unavailable: #{inspect(reason)}", true), state}
    end
  end

  # The number of the process inside the container of the hand. An old hand may not give it at all —
  # then the accounting says nothing about the process, and the line simply has no "pid" in it.
  defp pid_of(%{"pid" => pid}) when is_integer(pid), do: pid
  defp pid_of(_answer), do: nil

  # The launch of a job: for the cell and for the shell command it is one and the same. The difference
  # is only in which operation of the hand this is done by — and it comes
  # as an argument. The model's answer is the same: the job's hash, and that is all.
  #
  # The job's name comes HERE already ready, started by the caller: it is needed
  # by it earlier than the hand answers (see `with_job/2`). The hand answers with the same
  # name, and we check against the answer, and not against our own expectation — the name in
  # the answer is the one under which the job lives.
  defp start_job(id, _job, state, session, start, code) do
    case ensure_hand(session) do
      {:ok, hand} ->
        case start.(hand) do
          {:ok, %{"job" => job} = answer} ->
            started = with_reminder("job started in background, #{job}", state)

            # The job is taken into account BY ITS OWN PROCESS, and not by a record in the
            # state: this function runs in the task of the turn, and everything it
            # writes into `state` will die together with the task. The accounting, the job's deadline and
            # the question by which it asks live in Sweet.Job — and it is written there
            # why.
            #
            # The number of the process comes from THIS answer, and not from a separate request: the
            # hand gives it out together with the hash, and it is the same number that it will show
            # later in the list of its jobs. It is a LABEL for matching the two accounts up,
            # not a handle (see Sweet.Job.start/5).
            Sweet.Job.start(session, state.id, job, code, pid_of(answer))
            {tool_result(id, started), state}

          {:ok, %{"error" => error}} when is_binary(error) and error != "" ->
            {tool_result(id, "the hand did not start the job: " <> error, true), state}

          {:error, reason} ->
            hand_broken(session, hand, reason)
            {tool_result(id, "the hand is unavailable: #{inspect(reason)}", true), state}

          other ->
            {tool_result(id, "unexpected answer from the hand: #{inspect(other)}", true), state}
        end

      {:error, reason} ->
        {tool_result(id, "the hand is unavailable: #{inspect(reason)}", true), state}
    end
  end

  # The code travels to the hand as base64, and not as text in a heredoc or in quotation marks.
  # There is no escaping here at all, and this is not an excess of caution: any delimiter of a
  # heredoc is a string that the code has the right to contain, while single quotation marks
  # in Elixir occur in every second sigil. base64 consists of letters, digits,
  # `+`, `/` and `=`, therefore inside single shell quotation marks it means exactly
  # itself.
  #
  # We do not remove the file in /tmp: it lives exactly as long as the hand's container,
  # and by it one can see what exactly was executed — the same consideration as with
  # a job's log.
  #
  # A folder, and not a file by a template: `mktemp` requires X's at the END of the name, therefore
  # “/tmp/sweet-elixir-XXXXXX.exs” it does not accept at all, while the extension `.exs`
  # is needed here — by it both the person and `elixir` see that this is a script.
  defp elixir_script(code) do
    """
    set -e
    sweet_dir=$(mktemp -d /tmp/sweet-elixir-XXXXXX)
    sweet_script="$sweet_dir/cell.exs"
    printf %s '#{Base.encode64(code)}' | base64 -d > "$sweet_script"
    elixir "$sweet_script"
    """
  end

  # The language label for a cell of the kernel. `%%bash` in the first line is not a guess about
  # the language, but a magic invocation of IPython declared by the cell itself: after it there follows
  # the shell, and to show this as python means to label the code incorrectly.
  # We determine NOTHING else by the content of the code — the language comes from
  # the place of the call, see `Sweet.Telegram.code_block/2`.
  defp cell_lang(code) do
    first = code |> String.split("\n", parts: 2) |> List.first() |> String.trim()
    if String.starts_with?(first, "%%bash"), do: "bash", else: "python"
  end

  # The job's hash as the first line above the code — so that by what is shown in the chat one can
  # at once name the job: read its log, answer it, put it out.
  # Formerly the code and the hash lived in different messages, and there was nothing to link them with.
  #
  # The line stands ABOVE the code, and not inside: `cell_lang/1` looks at the first
  # line of the code itself (`%%bash`), and a label inserted into it would upset
  # the determination of the language.
  defp with_job(job, code), do: "#{job}\n#{code}"

  # --- What the person sees in the chat when the model touches an ongoing job ---
  #
  # The three tools below were formerly not shown AT ALL: neither in the chat nor in the log.
  # The blindness was total — by the conversation one could not distinguish “read the log” from
  # “said that it had read”, while `job_send` wrote into someone else's process in silence.
  #
  # The common rule for all three: we show the CALL, and not what it returned.
  # A read log is sometimes tens of kilobytes, and to dump it on the person
  # would mean to give it exactly what we spared the context from.

  # `read_log 59hdjfyYue tail=40 grep="Error"` — with the parameters, if there were any:
  # without them one cannot distinguish “read the whole log” from “took three lines by a mask”.
  #
  # The three assemblers below are open (`@doc false`) for the sake of checks: they are pure
  # functions of the job accounting, and to check them through a living turn would mean
  # to raise the model and the network for the sake of a line of text. The same device as with
  # `Sweet.Telegram.code_block/2`.
  @doc false
  def read_log_call(input) do
    args =
      [{"head", input["head"]}, {"tail", input["tail"]}, {"grep", input["grep"]}]
      |> Enum.reject(fn {_name, value} -> value in [nil, "", 0] end)
      |> Enum.map_join(" ", fn
        {"grep", value} -> "grep=#{inspect(value)}"
        {name, value} -> "#{name}=#{value}"
      end)

    String.trim("read_log #{input["job"]} #{args}")
  end

  # The whole picture at once: the accounting of the brain and the state from the hand, stitched by
  # the hash of the job. A job of the hand that the brain does not know is shown all the same — with
  # the first line of its code, which the hand remembers by itself.
  #
  # The time from the hand is added to the line of the brain, and not put in its place: the clock of
  # the brain counts the whole life of a job (the ceiling is counted by it), while the hand answers
  # about its own process — "it is running, it is waiting for input, it has been silent for so long".
  @doc false
  #
  # A job that the hand does not know is over. Brain learns about the end of a job not from the
  # process — the process lives behind the network, in the container of the hand — but from the
  # event "finished", and that event is lost when the hand is restarted or the channel breaks. Such
  # a record lives in the accounting until the hand itself dies, and the model sees it as running at
  # every turn while the process is long gone.
  #
  # The list of jobs is the only place where the two accounts lie side by side, therefore the record
  # is dropped here, and NOT by a timer: a ceiling that has expired says nothing about death, and a
  # job after its ceiling is alive and well. The hand answers about its own table as a whole, so a
  # record missing from it is missing for real; the hashes of the brain and of the hand agree, and a
  # job started from inside a cell (`bash()`) is known to the hand alone and is not touched here.
  #
  # It returns the hashes that were dropped. They go into the log, and not into the answer of the
  # model: the job is over, there is nothing to be done about it, and a line about it would only
  # take room in the context. Losing a record without a word would be the same lie as showing a
  # dead job as running — therefore the word is said, but to us.
  def forget_missing(session_id, ours, jobs) do
    known = MapSet.new(jobs, & &1["job"])

    dropped =
      ours
      |> Enum.reject(fn {job, _record} -> MapSet.member?(known, job) end)
      |> Enum.map(fn {job, _record} ->
        Sweet.Job.finish(session_id, job)
        job
      end)
      |> Enum.sort()

    if dropped != [], do: Logger.info("jobs taken off the accounting: #{Enum.join(dropped, ", ")}")
    dropped
  end

  @doc false
  def job_list_text(ours, jobs) do
    lines = Enum.map(jobs, &job_list_line(ours, &1))

    if lines == [] do
      "there are no background jobs: neither in the accounting nor in the hand."
    else
      Enum.join(lines, "\n")
    end
  end

  defp job_list_line(ours, state) do
    job = state["job"]

    line =
      case ours do
        %{^job => record} ->
          Sweet.Job.line(record)

        _ ->
          # Two reasons at once: a job started from inside a cell (`bash()`) never gets into the
          # accounting of the brain, while a job that has just ended is already taken off it. The
          # first says so itself; the second answers "it is over" by its own state.
          note =
            if state["state"] == "running",
              do: "it was started from inside a cell",
              else: "it is over, or it was started from inside a cell"

          "job #{job}  (the hand knows it, the brain does not: #{note})"
      end

    line <> hand_part(state)
  end

  # What the hand says about the process: the state, how long it has lived, how long it has been
  # silent, whether it waits for input and what it asks with.
  defp hand_part(%{"state" => "running"} = state) do
    how = "running #{state["runtime_s"]} s"
    how = if state["quiet_s"] > 10, do: how <> ", quiet for #{state["quiet_s"]} s", else: how

    ask =
      case state["ask"] do
        ask when is_binary(ask) and ask != "" -> "\n  waiting for input: #{first_line(ask)}"
        _ -> ""
      end

    "\n  #{how}#{ask}"
  end

  defp hand_part(state) do
    "\n  finished in #{state["runtime_s"]} s, exit code #{state["exit"]}"
  end

  @doc false
  def send_call(state, job, text) do
    answer = String.trim_trailing(text)

    # A one-line answer — into the same line, a multi-line one — under itself: otherwise
    # “answer: first line” lies about what went into the process as a whole.
    answer =
      if String.contains?(answer, "\n"),
        do: "answer:\n#{answer}",
        else: "answer:   #{answer}"

    ["job_send -> job #{job}", job_line(state, job), ask_line(state, job), answer]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc false
  def signal_call(state, job, what) do
    "job_signal -> job #{job}  (#{what})\n" <> job_line(state, job)
  end

  # The job's command from the accounting. The job may already be gone — it ended between
  # the question and the answer, — and this is worth saying directly, and not showing emptiness.
  defp job_line(state, job) do
    case job_entry(state, job) do
      %{code: code} -> "job:      #{first_line(code)}"
      nil -> "job:      (no longer in the accounting — it is over)"
    end
  end

  # What the job asked with. Three cases, and they are DIFFERENT:
  #
  #   * there is a line — we show it;
  #   * the line is empty — the question was asked, but the prompt did not get into the log (`read -p`
  #     prints it only to the terminal);
  #   * `nil` — no question was asked at all.
  #
  # When the job is not in the accounting at all, there is no line either: about a finished
  # job we do not know whether it asked or not, and “it did not ask” here would be
  # an invention. The line above, in `job_line/2`, will say about the fact itself.
  defp ask_line(state, job) do
    case job_entry(state, job) do
      %{ask: ask} when is_binary(ask) and ask != "" -> "question: #{first_line(ask)}"
      %{ask: ask} when is_binary(ask) -> "question: (there is no prompt in the log)"
      %{} -> "question: (the job did not ask)"
      nil -> nil
    end
  end

  defp job_entry(state, job) do
    Enum.find(Sweet.Job.list(state.id), &(&1.job == job))
  end

  # A postscript to the result of a tool: the same paragraph about leave for edits as
  # stands in the system prompt, and in the same wording. The system prompt
  # was read once at the beginning of the turn, while the decision “to edit or not” is taken
  # where the model reads the result of the work — by the hundred and first round nobody
  # remembers the first paragraph any more.
  #
  # The mode — from the config, the default :off (see config.exs):
  #   :off — do not append;
  #   :turn — once per turn, to the FIRST result: after that it is a repetition;
  #   :each — to every step.
  #
  # We count by the rounds: turns grows on every round of the cycle, while the state
  # is given to the tool before that increment. That means :turn is turns == 0.
  defp with_reminder(text, state) do
    case Application.fetch_env!(:sweet, :reminder_edits) do
      :off -> text
      :each -> text <> "\n\n" <> Sweet.Harness.Prompt.edits_rule(state)
      :turn ->
        if state.turns == 0, do: text <> "\n\n" <> Sweet.Harness.Prompt.edits_rule(state), else: text
    end
  end

  defp tool_result(id, content, error? \\ false) do
    %{"type" => "tool_result", "tool_use_id" => id, "content" => content}
    |> then(fn result -> if error?, do: Map.put(result, "is_error", true), else: result end)
  end

  # The hand belongs to the session. The task does not remember it and does not raise it: it asks and waits.
  # We wait without a timeout — the container comes up within up to a minute, and to invent here
  # a second deadline there is no reason: the hand already has its own deadline (see Sweet.Hand.boot_timeout).
  # A dead session is not a breakage of the task: the turn is needed by nobody anyway.
  defp ensure_hand(session) do
    GenServer.call(session, :hand, :infinity)
  catch
    :exit, {:noproc, _} -> {:error, :session_gone}
    :exit, {:normal, _} -> {:error, :session_gone}
    :exit, {:shutdown, _} -> {:error, :session_gone}
  end

  defp account(state, %{usage: usage}), do: %{state | usage: add_usage(state.usage, usage)}

  # The clock of the turn: from `start_turn/2` to the acceptance of the result. Monotonic — and “the clock has started”
  # remains true even if the system time has shifted between the beginning and the end.
  #
  # There may be no mark: the field is nillable, and a subtraction from `nil` is an
  # ArithmeticError right in the handler of the result, that is, the death of the session because of a
  # figure in a report. The figure is not worth that: without a mark we answer zero.
  defp elapsed(%{turn_started: nil}), do: 0
  defp elapsed(%{turn_started: started}), do: System.monotonic_time(:millisecond) - started

  defp add_usage(acc, usage) do
    Map.merge(acc, usage, fn _key, old, new -> old + new end)
  end

  # We put what is incoming into the mailbox. The headline — for the person and for the memory, the block — for
  # the model; the form of both paths is one, therefore the function is one too.
  #
  # Here is also the record into the memory, and also one for everything incoming: we write BEFORE the turn,
  # so that what was said is in the history even if the turn breaks off. The full history
  # lives in the memory, and a selection will travel to the model.
  #
  # `how` decides WHAT this lies down as, and the difference here is fundamental.
  #
  # `:reply` — what was said in words: a paragraph with a vector, searched by meaning.
  # `:trace` — a trace of work (the end of a job, a job's question, the death of the hand):
  # a record of the role `tool`, WITHOUT a vector.
  #
  # Formerly the second went first: the event about the end of a job lay down through
  # `append`, that is, the output of scripts was embedded on a par with the words of the person and
  # surfaced in the selection by meaning days later. Now in the memory there remains of a job
  # one line with the hash (see job_headline/1), while the output is taken from
  # the log on demand — through read_log.
  #
  # One can find this line through days even without a vector: it lies in the same
  # utterance (`:msg`) as the conversation around it, and the search gives the utterance back
  # WHOLE, together with the traces (see Sweet.Recall.search/2).
  defp put_inbox(state, text, block, how \\ :reply)

  defp put_inbox(state, text, block, :reply) do
    Sweet.Recall.append(state.id, "user", text)
    %{state | inbox: state.inbox ++ [%{text: text, block: block}]}
  end

  defp put_inbox(state, text, block, :trace) do
    Sweet.Recall.note_tool(state.id, text)
    %{state | inbox: state.inbox ++ [%{text: text, block: block}]}
  end

  # We take the mailbox dry. From the TASK this is visible only by a request: the mailbox lives in the
  # session, while the turn is counted in a separate process.
  defp take_inbox(state) do
    # Jobs are asked of the registry, and not read from the state, and this is the same
    # trade as with the accounting: the session's state is edited only by the session itself, while
    # the turn goes on in a task — a record from there would land in someone else's copy of the state.
    jobs = Sweet.Job.list(state.id)

        running =
      case jobs do
        [] ->
          ""

        _ ->
          "\n\nstill running: " <> Enum.map_join(jobs, "\n  ", &Sweet.Job.line/1)
      end# About a job that waits for an answer we remind NOT ONLY in the event about it.
    # The event comes once, while the mailbox is taken at every boundary of a round:
    # without this line the model, having seen a question at the beginning of the turn and having answered
    # something else later, will not remember about it any more.
    asking =
      case waiting_jobs(jobs) do
        [] -> ""
        names -> "

waiting for input: " <> Enum.join(names, ", ")
      end

    blocks =
      case state.inbox do
        [] -> []
        inbox ->
          Enum.map(inbox, & &1.block) ++
            [%{"type" => "text", "text" => "end of inbox" <> running <> asking}]
      end

    {blocks, %{state | inbox: []}}
  end

  # We turn a job's event into text. Briefly and without service hints:
  # how it ended, where the log is and the output itself whole. To hint “this is not a new
  # question” there is no reason — it is visible by the role and by the form of the block.
  #
  # Three kinds of a job — three different texts, and the difference here is not in politeness.
  # “It is over” — a fact, and one goes on by it. “It asks for input” — also a fact
  # (visible by the kernel), and it has exactly two outcomes: `job_send` with an answer
  # or `job_signal`, if there is nothing to answer with. “It has been silent for a long time” — an estimate by
  # time, and the text is obliged to show this, otherwise the model will start to react
  # in the same way to a question and to silence.
  defp job_notice(%{"event" => "waiting"} = event) do
    """
    job #{event["job"]} is waiting for input#{prompt_text(event)}
    output so far:
    #{output_block(event)}

    Answer it with job_send (the text goes to the job stdin), or stop it with
    job_signal if there is nothing to answer with.
    """
  end

  defp job_notice(%{"event" => "overdue"} = event) do
    """
    job #{event["job"]} has been running past its limit (#{div(Application.fetch_env!(:sweet, :job_hard_limit_ms), 60_000)} min).
    Maybe stuck — ask the human whether to kill it (job_signal) or let it run.
    """
  end

  defp job_notice(%{"event" => "stale"} = event) do
    """
    job #{event["job"]} has been quiet for #{round(event["quiet_s"])} s — maybe
    stuck: it may be waiting for a prompt nobody sees, or simply working
    without output. Ask the human whether to kill it or give it more time.
    The job is still running, so its log cannot be read yet — what it printed
    so far is right here, and that is all there is to go on.
    output so far:
    #{output_block(event)}
    """
  end

  defp job_notice(event) do
    """
    job #{event["job"]} finished, exit code #{event["exit"]}#{size_text(event)}
    output:
    #{output_block(event)}#{kernel_names(event)}
    """
  end

  # The output of a job in the event: the head, the seam, the tail. The path to the log does NOT enter here
  # in any form — the log is addressed by the job's hash and is read through read_log.
  #
  # Why it is no pity to cut here: what is cut out goes nowhere. The log lies with
  # the hand whole, the hash stands in this same line, and any piece is retrieved by one
  # call. To keep in the context what is re-readable on demand is to
  # pay with tokens for an archive that already has an address.
  #
  # The limit is double: lines AND bytes. A count in lines alone would have let through one
  # line of two hundred kilobytes (base64, minified json, an array dump),
  # a count in bytes alone would have cut a line in the middle.
  defp output_block(event) do
    head_limit = Application.fetch_env!(:sweet, :tool_output_head_lines)
    tail_limit = Application.fetch_env!(:sweet, :tool_output_tail_lines)
    cap = Application.fetch_env!(:sweet, :tool_output_bytes)

    head = event["head"] || ""
    tail = event["tail"] || ""
    lines = event["lines"] || 0
    bytes = event["bytes"] || 0

    cond do
      String.trim(head) == "" and String.trim(tail) == "" ->
        "(empty)"

      # It fits whole — we show it as it is, without a seam and without a head: with a
      # short output the head and the tail are the same text, and to print
      # it twice would mean to lie about the volume.
      lines <= head_limit + tail_limit and bytes <= cap ->
        String.trim_trailing(tail)

      true ->
        {head_text, head_lines} = first_lines(head, head_limit, div(cap, 3))
        {tail_text, tail_lines} = last_lines(tail, tail_limit, cap - div(cap, 3))
        cut = max(lines - head_lines - tail_lines, 0)

        Enum.join(
          [
            String.trim_trailing(head_text),
            "... [cut #{cut} lines of #{lines}, #{size(bytes)} in total " <>
              "— the whole log: read_log #{event["job"]}] ...",
            String.trim_trailing(tail_text)
          ],
          "\n"
        )
    end
  end

  # The first n lines, but not more than cap bytes. It also returns how many lines were taken:
  # without this there is nothing to count how much was cut out with.
  defp first_lines(text, n, cap) do
    taken = text |> String.split("\n") |> Enum.take(n) |> Enum.join("\n") |> String.slice(0, cap)
    {taken, length(String.split(taken, "\n"))}
  end

  # The last n lines, but not more than cap bytes. The first line of the tail the hand almost
  # always gives back as a cropped middle — we discard it, and do not pass off a stub
  # as a line.
  defp last_lines(text, n, cap) do
    lines = text |> String.split("\n") |> Enum.drop(1)
    taken = lines |> Enum.take(-n) |> Enum.join("\n")
    taken = if byte_size(taken) > cap, do: String.slice(taken, -cap..-1//1), else: taken
    {taken, length(String.split(taken, "\n"))}
  end

  defp size_text(event) do
    case {event["lines"], event["bytes"]} do
      {nil, _} -> ""
      {lines, bytes} -> ", #{lines} lines, #{size(bytes || 0)}"
    end
  end

  defp size(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp size(bytes) when bytes >= 1024, do: "#{div(bytes, 1024)} KB"
  defp size(bytes), do: "#{bytes} B"

  # What the job asks with. There may be no line: `read -p` prints
  # the prompt only when stdin is a terminal, while a job's stdin is a pipe (checked:
  # nothing of it remains in the log). The fact of waiting does not disappear because of this —
  # only the hint disappears, and to lie “here is the question” with emptiness in the place
  # of the question is impossible. Therefore an empty line is called empty.
  defp prompt_text(%{"ask" => ask}) when is_binary(ask) and ask != "", do: ": #{ask}"
  defp prompt_text(_event), do: " (the prompt is not in the log)"

  # Jobs waiting for an answer in stdin. The order is taken from `Sweet.Job.list/1` — it is already
  # by hash, and this is not cosmetics: the line goes off into the context, and the context would
  # change from the order in it for no reason at all.
  #
  # An empty question line and its absence are different things: with the first the job
  # stands and will not end by itself, with the second no question was asked at all.
  defp waiting_jobs(jobs) do
    for %{job: job, ask: ask} <- jobs, not is_nil(ask), do: "job #{job} (#{ask})"
  end

  # What remained in the kernel after the cell. A shell command does not have this line:
  # it does not touch the kernel.
  defp kernel_names(%{"namespace" => names}) when is_list(names) and names != [] do
    "\n\nin the kernel: " <> Enum.join(names, ", ")
  end

  defp kernel_names(_event), do: ""

  # The beginning of a turn. One path for everything: both a question of the person and the end of a job come
  # here already lying in the mailbox, and the turn takes the mailbox whole. Formerly there were
  # two such paths — `handle_cast({:ask, ...})` and `wake/2`, — and they diverged:
  # one had a question, the other did not, and each parsed the queue of jobs
  # in its own way.
  #
  # `question` for the assembly of the context is the headline of the last incoming: by it
  # the memory is raised. As the subscriber we set the one who listens; a dead pid
  # is no trouble here — `send` will do nothing to it, while the turn will work out and lie down
  # in the memory.
  #
  # The mailbox here is certainly not empty: this is called right after putting something into it.
  defp start_turn(state, subscriber) do
    question = state.inbox |> List.last() |> Map.fetch!(:text)

    # A turn counts ONLY itself: both the tokens and the rounds of the cycle from zero. The session
    # total is accumulated by `handle_info` above, exactly once.
    #
    # Formerly a turn started from the accumulated total of the session, added its own
    # usage to it and returned the sum — and the session added it to the same total
    # again. The result was `total = total + (total + turn)`, that is, a DOUBLING on
    # every question.
    {blocks, state} = take_inbox(state)
    history = state.history ++ [%{role: "user", content: blocks}]
    session = self()

    turn_state = %{state | history: history, usage: %{input: 0, output: 0}, turns: 0}
    started = System.monotonic_time(:millisecond)

    # Under a supervisor and WITHOUT a link. Formerly `Task.async` stood here, and it links:
    # a fallen turn sent the session `EXIT`, and the fact that the session survived
    # rested on `trap_exit` and on the fact that a foreign `EXIT` was swallowed by the catch-all
    # clause of `handle_info/2`. A fall of a turn is an ordinary thing (network, model,
    # an error in a tool), and the session must not depend on whether
    # someone caught the signal. `async_nolink` gives the same `{ref, result}` and the same
    # `:DOWN`, but by definition does not bring the owner down.
    task = Task.Supervisor.async_nolink(Sweet.Tasks, fn -> run(turn_state, session, question) end)

    if subscriber, do: send(subscriber, {:sweet_turn, self(), question})

    %{
      state
      | task: task,
        subscriber: subscriber,
        watcher: subscriber || state.watcher,
        history: history,
        turn_started: started
    }
  end

  # The headline of the event is what is for the person and the memory. One for all three kinds, for
  # the same reason as the text: the person must be able to read what happened.
  # One line about the event — both to the person in the chat and into the memory. This is THAT VERY trace
  # by which the log is later found: the job's hash is always in it, while there is
  # no output in it at all. There is deliberately no path to the log (see output_block/1).
  defp job_headline(%{"event" => "waiting"} = event) do
    "job #{event["job"]} is waiting for input#{prompt_text(event)}"
  end

  defp job_headline(%{"event" => "stale"} = event) do
    "job #{event["job"]} has been quiet for #{round(event["quiet_s"])} s, maybe stuck"
  end

  defp job_headline(event) do
    "job #{event["job"]} finished, exit code #{event["exit"]}#{size_text(event)}"
  end

  # We take what has accumulated from the session's mailbox. Dry: the boundary of a turn is not a place
  # where one may stand and wait for something NEW, but to wait for an ANSWER here is obligatory.
  # The session comes as an argument, as in run/4.
  #
  # We wait without a timeout deliberately. Formerly 5_000 stood here — and that was a loss, and
  # not insurance: a timeout on the client's side does not cancel the server-side processing,
  # the session would reach `:take_inbox` all the same, clean out the mailbox and
  # answer into emptiness. The words of the person and the ends of jobs would disappear silently.
  # To wait is safe: the handler there is two operations over a list, it does not go
  # outside and has nothing to hang on.
  #
  # We catch only the death of the session: the mailbox is no longer there with it, and a turn without a session
  # is needed by nobody — there is no one to give the answer to. Everything else let it fall:
  # it is a breakage, and it is better to know about it at once.
  defp pull_inbox(session) do
    GenServer.call(session, :take_inbox, :infinity)
  catch
    :exit, {:noproc, _} -> []
    :exit, {:normal, _} -> []
    :exit, {:shutdown, _} -> []
  end

  defp tool_uses(content), do: Enum.filter(content, &(&1["type"] == "tool_use"))

  # What of the answer travels back to the provider. The reasoning does NOT travel.
  #
  # With DeepSeek this is a direct rule: the reasoning relates to the previous step, and
  # not to the conversation, and to return it in the next request is impossible. We also do not
  # know how to return it correctly: the signature of a block arrives with its own delta,
  # which the stream assembler does not accumulate, — that is, a block without a signature would travel,
  # invalid. Plus money: the reasoning is the longest part of the answer, while
  # there are sometimes ten rounds in a turn, and the same text would be paid for on
  # each.
  #
  # Coherence does not suffer from this: between the rounds the model conducts not
  # reasoning, but work — the results of the calls with facts arrive to it.
  #
  # If we ever move to a model to which the reasoning must be returned
  # OBLIGATORILY (Claude with extended thinking), this place will have to be done
  # anew and for real: with the signature, and not simply ceasing to filter.
  defp for_api(content), do: Enum.filter(content, &(&1["type"] in ["text", "tool_use"]))

  # What the agent says when taking up the tools. There are two kinds, and they are DIFFERENT.
  #
  # `text` — speech addressed to the person: it is written for it, and is not
  # controlled by the flag. Formerly it was controlled: both entities were glued into one lump and
  # put out together, therefore with `show_thinking: false` the speech disappeared from the chat
  # too. It was visible right in the log — “an utterance of 2947 characters” with `text(112)`:
  # 2834 characters of reasoning carried away 112 characters of words.
  #
  # `thinking` — the internal, and this is what `show_thinking` hides. It goes as a separate
  # message, and not glued to the speech: to dump them into one would mean to lose again
  # the boundary between “said to the person” and “thought to oneself”.
  #
  # Empty — we are silent: an empty message cannot be sent to the chat.
  defp say_aside(session, content) do
    speech = blocks_text(content, ["text"])
    thought = blocks_text(content, ["thinking", "reasoning"])

    Logger.info("before the calls: speech #{String.length(speech)}, thoughts #{String.length(thought)}")

    if speech != "", do: send(session, {:aside, speech})

    if thought != "" and Application.fetch_env!(:sweet, :show_thinking),
      do: send(session, {:aside, thought})
  end

  # The words from blocks of the needed kinds — in the order in which they are in the answer.
  # `thinking` and `reasoning` are two names of one and the same in different
  # providers, therefore they are asked together.
  defp blocks_text(content, types) do
    content
    |> Enum.filter(&(&1["type"] in types))
    |> Enum.map(fn block -> block["text"] || block["thinking"] || block["reasoning"] end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> String.trim()
  end


  defp text_of(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", & &1["text"])
  end

  # We monitor the hand exactly once — on the one we already track we do not hang the monitor
  # a second time.
  defp track(%{hand: %{pid: pid}} = state, %{pid: pid}), do: state

  defp track(state, hand) do
    if state.hand_ref, do: Process.demonitor(state.hand_ref, [:flush])
    %{state | hand: hand, hand_ref: Process.monitor(hand.pid)}
  end

  # Forget the hand: both the handle and the monitor. In one place, because to forget half
  # means to leave a monitor on a dead process or a handle without a monitor.
  defp forget_hand(state) do
    if state.hand_ref, do: Process.demonitor(state.hand_ref, [:flush])
    %{state | hand: nil, hand_ref: nil}
  end

  defp safe_stop(hand) do
    Sweet.Hand.stop(hand)
  catch
    # The hand could have died a moment earlier — this is no reason to make a noise on the way out.
    :exit, _ -> :ok
  end

  defp random_id, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
end
