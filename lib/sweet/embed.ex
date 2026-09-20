defmodule Sweet.Embed do
  @moduledoc """
  A bridge to the embedding calculator — a separate OS process behind a port.

  BERT does not live in the BEAM deliberately: an NIF with torch inside the VM would mean that
  a segfault or an OOM in the model lays down the whole agent. The port gives the same boundary as
  the hand has — only the calculator dies, the supervisor brings up a fresh one.

  The first answer of the model is awaited longer than the rest: it is loading the weights.
  """

  use GenServer
  require Logger

  @doc """
  Vectors for a list of texts.

  `kind` — passage (what we store) or query; this is the prefix that
  e5 requires, and it has no other values.

  `cut` — from which end to cut a text that does not fit into the window of the model: `"left"`
  or `"right"`. Separately from `kind` deliberately: a paragraph of memory is encoded as a
  passage, but it must be cut on the left — it goes last in the window of the previous
  paragraphs. `nil` leaves the default of the embedder (query on the left, passage on the right).
  """
  def encode(texts, kind \\ "passage", cut \\ nil) when is_list(texts) do
    if texts == [] do
      {:ok, []}
    else
      GenServer.call(
        __MODULE__,
        {:encode, texts, kind, cut},
        Application.fetch_env!(:sweet, :embed_timeout_ms)
      )
    end
  end

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    {:ok, %{conn: nil, container: nil, ready: false, waiting: []}, {:continue, :boot}}
  end

  # The name is constant: under it the embedder is listed in the registry, and under it
  # its container connects.
  @name "sweet-embedder"

  # Registration is the only thing that cannot be postponed: the container will knock
  # itself, and by that moment we must be findable by name.
  #
  # The talk with docker goes as a TASK, and not here. Formerly the creation and start of
  # the container stood right in the handler: the process was silent all that time, and
  # moreover a manual `receive` inside the docker client drained from OUR [mailbox]
  # foreign messages (see Sweet.Hand.Docker.recv/5 — the postponing of foreign messages is written
  # there exactly because of this case). In the hand this has long been done with a task;
  # here it remained the old way.
  @impl true
  def handle_continue(:boot, state) do
    {:ok, _} = Registry.register(Sweet.Hand.Registry, @name, nil)
    embed = self()

    Task.Supervisor.start_child(Sweet.Tasks, fn ->
      Sweet.Hand.Docker.remove(@name)

      case boot_docker() do
        {:ok, container} -> send(embed, {:booted, container})
        {:error, reason} -> send(embed, {:boot_failed, reason})
      end
    end)

    # If it does not knock — we learn it by the deadline, and do not hang forever.
    Process.send_after(self(), :boot_timeout, Application.fetch_env!(:sweet, :embed_timeout_ms))

    {:noreply, state}
  end

  # Prod: its own container with its own memory limit. This is not about the isolation of code —
  # the embedder is ours and does not execute the code of the model — but about resources: inside brain
  # its OOM would drag the whole container with it, that is, the entire agent.
  defp boot_docker do
    name = @name

    with {:ok, container} <-
           Sweet.Hand.Docker.create(name,
             image: Application.fetch_env!(:sweet, :embed_image),
             memory: Application.fetch_env!(:sweet, :embed_memory_bytes),
             nano_cpus: Application.fetch_env!(:sweet, :embed_nano_cpus),
             # The rootfs of the container is read-only, while the weights of the model need
             # somewhere to lie down. A named volume: they survive a restart and are not
             # downloaded anew (470 MB for every start).
             #
             # Through Mounts, and not Binds: in Binds a volume is written as `name:/path`,
             # without a leading slash, and docker-filter rejects such an entry —
             # it expects a host path there. In Mounts the type of the volume is named explicitly.
             binds: [],
             mounts: [
               %{
                 "Type" => "volume",
                 "Source" => Application.fetch_env!(:sweet, :embed_cache_volume),
                 "Target" => "/home/embedder/.cache",
                 "ReadOnly" => false
               }
             ],
             env: [
               # The network of the embedder is closed, there is no route outward. Without these two
               # variables sentence-transformers at every start goes to
               # huggingface to check the config of the model, does not resolve the name and spends
               # a minute on five attempts. The weights lie in the volume — there is nothing to check.
               "HF_HUB_OFFLINE=1",
               "TRANSFORMERS_OFFLINE=1",
               "SWEET_EMBED_TRANSPORT=connect",
               "SWEET_EMBED_ID=#{name}",
               "SWEET_EMBED_MODEL=#{Application.fetch_env!(:sweet, :embed_model)}",
               "SWEET_EMBED_THREADS=#{Application.fetch_env!(:sweet, :embed_threads)}"
             ]
           ),
         :ok <- Sweet.Hand.Docker.start(container) do
      {:ok, container}
    end
  end

  # We do NOT wait for an answer here: by the same technique as in the hand and in the listener itself.
  #
  # Formerly this handler stood inside itself for up to 180 seconds, and all that time
  # the process did not answer anyone: neither the next vectorization, nor the question of whether
  # it was alive. And through it goes all the memory — that is, every conversation waited
  # for a foreign vectorization.
  #
  # It became possible only now: while the connection had one slot of
  # a waiting one, two requests in a row would have overwritten each other. With the numbers of
  # requests (see Sweet.Hand.Listener) the answers are distinguishable, and anyone can wait for them.
  #
  # A reservation for honesty's sake: the embedder itself reads frames in a loop one at a time, so
  # it will count one at a time anyway. What is free now is the PROCESS —
  # the queue has stopped standing in the BEAM.
  @impl true
  # The embedder is still coming up: the weights load for half a minute, while they may ask
  # earlier — the skills are indexed right at start. We postpone the answer, the request
  # waits in the queue and will go off as soon as the container knocks. Formerly such a
  # case did not exist: the bringing up stood inside the handler and it simply did not
  # come to questions.
  def handle_call({:encode, texts, kind, cut}, from, %{conn: nil} = state) do
    {:noreply, %{state | waiting: [{from, texts, kind, cut} | state.waiting]}}
  end

  def handle_call({:encode, texts, kind, cut}, from, state) do
    dispatch(state.conn, from, texts, kind, cut)
    {:noreply, state}
  end

  defp dispatch(conn, from, texts, kind, cut) do
    payload = %{op: "embed", texts: texts, kind: kind, cut: cut}
    timeout = Application.fetch_env!(:sweet, :embed_timeout_ms)
    embed = self()

    Task.Supervisor.start_child(Sweet.Tasks, fn ->
      case Sweet.Hand.Listener.request(conn, payload, timeout) do
        {:ok, %{"vectors" => vectors}} ->
          GenServer.reply(from, {:ok, vectors})

        {:ok, %{"error" => error}} ->
          GenServer.reply(from, {:error, error})

        # The calculator is lost: we answer the waiting one and tell the embedder about it.
        # To die is the business of the process itself, and not of the task that learnt
        # about the death; the supervisor will bring up a fresh one together with the container.
        {:error, reason} ->
          GenServer.reply(from, {:error, reason})
          send(embed, {:embedder_lost, reason})
      end
    end)
  end

  @impl true
  def handle_info({:booted, container}, state), do: {:noreply, %{state | container: container}}

  # There is no container — there is nothing to answer the waiting ones with. We die: the supervisor will bring
  # up a fresh one, and the calls will come out with this same reason.
  def handle_info({:boot_failed, reason}, state) do
    {:stop, {:embedder_start_failed, reason}, state}
  end

  def handle_info({:hand_connected, conn}, state) do
    Logger.info("embedder connected (container)")

    for {from, texts, kind, cut} <- Enum.reverse(state.waiting) do
      dispatch(conn, from, texts, kind, cut)
    end

    {:noreply, %{state | conn: conn, ready: true, waiting: []}}
  end

  def handle_info(:boot_timeout, %{conn: nil} = state), do: {:stop, :embedder_never_connected, state}
  def handle_info(:boot_timeout, state), do: {:noreply, state}

  def handle_info({:embedder_lost, reason}, state), do: {:stop, {:embedder_lost, reason}, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{container: container}) when not is_nil(container) do
    # We tidy up the container ourselves: terminate/2 will not be called on :kill, but on a
    # normal stop — yes, while an abandoned embedder holds a gigabyte of memory.
    Sweet.Hand.Docker.remove(container)
  end

  def terminate(_reason, _state), do: :ok

end
