defmodule Sweet.Application do
  @moduledoc """
  The supervision tree of the brain node.

      Sweet.Supervisor
      ├── Sweet.Finch                 the connection pool to the model
      ├── Sweet.Tasks                 Task.Supervisor: everything done "in a task"
      ├── Sweet.Hand.Registry         the name of a hand → the process waiting for it
      ├── ThousandIsland            the listener to which the hands connect
      ├── Sweet.Embed                 the bridge to the embedding calculator
      ├── Sweet.Memory                tables, stores, memory, inventory, skills
      ├── Sweet.Hand.Registry         the name of a hand → the process waiting for it
      ├── Sweet.Job.Supervisor        the DynamicSupervisor of background jobs
      ├── Sweet.SessionSupervisor     the DynamicSupervisor of sessions
      └── Sweet.Telegram.Chats        the DynamicSupervisor of chats (if there is a token)

  The fall of a hand does not touch the session, the fall of a session does not touch the memory.

  The stock of restarts is set explicitly. The OTP default is three in five seconds, and it
  sufficed exactly until the first child falling from an external cause: the polling of
  Telegram on an abnormal answer restarted three times in a row and carried away the WHOLE node
  together with the conversations. The cause at the same time is external and will pass by itself, while we need
  to survive it, and not die by the counter.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Preparing the place — the exchange folders and the file log. As the first child, and
        # not as work before `start_link`: see Sweet.Boot.
        Sweet.Boot,
        {Finch, name: Sweet.Finch},
        # All the tasks that someone launches along the way: waiting for the answer of the
        # hand and the embedder, vectorization, the talk with docker. Formerly they
        # hung on the side through Task.start — they were not visible in the tree, it was impossible
        # to count them and there was no one to put them out on a stop. The supervision tree
        # must be the truth about the system.
        {Task.Supervisor, name: Sweet.Tasks},
        # The registry and the listener — before the embedder: it registers in them and
        # through them accepts the connection of its container.
        #
        # There are two registries, and this is not a splitting for the sake of order: a hand is listed under the
        # NAME of a session, while a job — under the pair "session + hash of the job", and
        # only its own registry can select the jobs of a session with one query by such a pair. The account of a job
        # is set right here too (see Sweet.Job).
        {Registry, keys: :unique, name: Sweet.Hand.Registry},
        {Registry, keys: :unique, name: Sweet.Job.Registry}
      ] ++
        [
          {ThousandIsland,
           port: Application.fetch_env!(:sweet, :listen_port),
           handler_module: Sweet.Hand.Listener,
           handler_options: %{},
           transport_options: [packet: 4],
           # An idle state is a normal one: while the model is thinking, over the socket
           # nothing goes for minutes. With the default of 60 seconds Thousand Island
           # tore such connections, the containers exited, and the next request
           # fell with :hand_gone. Liveness is tracked by the monitor anyway.
           read_timeout: :infinity},
          Sweet.Embed,
          # The memory, the inventory and the skills — in one group: they have a common dependency on
          # the tables and the stores, and it is expressed inside (see Sweet.Memory). It stands
          # after the embedder — the skills are indexed by its vectors — and before
          # Telegram: the bridge asks the inventory on the very first message, in order to
          # understand which session to continue.
          Sweet.Memory,
          {DynamicSupervisor, name: Sweet.Hand.Supervisor, strategy: :one_for_one},
          # The jobs under their own supervisor, and not under the supervisor of hands: a job
          # outlives both the turn and the hand itself. Its account says the same — it
          # lives in the process of the job, and not in the state of the session.
          {DynamicSupervisor, name: Sweet.Job.Supervisor, strategy: :one_for_one},
          {DynamicSupervisor, name: Sweet.SessionSupervisor, strategy: :one_for_one}
        ] ++ telegram()

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Sweet.Supervisor,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  # The bridge into Telegram comes up only if a token is set: without it IEx
  # remains the only entrance, and this is a normal mode of operation.
  defp telegram do
    if Sweet.Telegram.token() do
      # A process per chat: a registry by chat id and a supervisor for them. The bridge no longer
      # goes onto the network — they are occupied with that (see Sweet.Telegram.Chat).
      [
        {Registry, keys: :unique, name: Sweet.Telegram.Registry},
        {DynamicSupervisor, name: Sweet.Telegram.Chats, strategy: :one_for_one},
        Sweet.Telegram,
        Sweet.Telegram.Poller
      ]
    else
      []
    end
  end

end
