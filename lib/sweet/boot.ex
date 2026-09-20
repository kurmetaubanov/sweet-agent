defmodule Sweet.Boot do
  @moduledoc """
  The first child of the tree: what must be ready before all the others.

  Two things, and both are the preparation of the place, and not work:

    * the exchange folders (`Sweet.Files.ensure/0`): the agent may put a file into outbox
      on the very first turn, and the folder must be waiting for it, and not be created afterwards;
    * the file handler of the log: it is installed before the others speak,
      otherwise their first lines will not get into the file.

  Formerly both were done right in `Sweet.Application.start/2`, before
  `Supervisor.start_link`. It worked — but it was work outside the tree: nobody
  restarted it, the supervisor knew nothing about it, and there was nowhere to see it in the
  inventory of the system. The supervision tree must be the truth about the system,
  including the preparation.

  The order is guaranteed by the fact that all the work goes in `init/1`: the supervisor
  starts children one at a time and will not begin the next until this one has returned.
  """

  use GenServer
  require Logger

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    Sweet.Files.ensure()
    log_to_file()
    {:ok, %{}}
  end

  # The log — also to a file, next to the memory of conversations.
  #
  # `docker logs` shows only a LIVE container: the recreation of brain carries away
  # its history as a whole. In one day of debugging brain was rebuilt seven times, and
  # once the removed log held the only instance of an answer that did not
  # reach the chat — only the fact that they managed to read it saved it.
  #
  # The priv folder is mounted
  # the complete removal of the container. The standard output remains as it was: this is
  # an ADDITION of a handler, and not a replacement, and `docker logs` and `iex` work
  # as before.
  #
  # The rotation is built in: `max_no_files` pieces of `max_no_bytes`, beyond that the old ones
  # are overwritten by themselves — the disk will not fill up, even if the log is forgotten for months.
  defp log_to_file do
    path = Application.fetch_env!(:sweet, :log_path)
    File.mkdir_p!(Path.dirname(path))

    config = %{
      config: %{
        type: {:file, to_charlist(path)},
        max_no_bytes: Application.fetch_env!(:sweet, :log_max_bytes),
        max_no_files: Application.fetch_env!(:sweet, :log_max_files)
      },
      # Without colour: the colouring is intended for a terminal, while in a file it settles
      # as control sequences over every line.
      formatter:
        Logger.Formatter.new(
          format: "$date $time $metadata[$level] $message\n",
          colors: [enabled: false]
        )
    }

    case :logger.add_handler(:sweet_file, :logger_std_h, config) do
      :ok -> :ok
      # Already added — this is a restart of the application without a restart of the VM, or our
      # own restart by the supervisor. There is one handler per VM.
      {:error, {:already_exist, _}} -> :ok
    end
  end
end
