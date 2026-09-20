defmodule Sweet.Telegram.Typing do
  @moduledoc """
  "Typing…" for the duration of a turn — by a process, and not by a timer.

  Telegram puts the status out about five seconds later, therefore it must be renewed while
  the turn goes. Formerly `:timer.send_interval/2` was occupied with this, and the reference to the
  timer lay in the map of waiting turns. The scheme fell apart twice:

    * the record in the map was overwritten (a second question on a busy session) —
      the reference was lost, and there was NOTHING to put the indicator out with. "Typing…"
      hung until a restart of brain;
    * the wrong timer was put out: the message about the end of a turn did not know which
      session it was from, and the first record of the map was taken.

  A process is free of this by design. There is one per turn, it is its own
  owner, and its death is the end of the indicator: it can be killed
  always, even having lost all the references.

  It lives under `Sweet.Tasks`, and not on the side of the tree. Formerly it was a bare
  `spawn_link` from the bridge: the supervisor did not know about it, there was nowhere to count the
  indicators and no one to put them out on a stop. The link with the bridge at the same time is
  preserved (`async_nolink` is not suitable here: the indicator must go away together with
  the one who lit it), and the bridge catches exits, therefore the death of the indicator does not
  touch it.
  """

  @interval 4_000

  @doc "Light the indicator in the chat. Returns a pid — it is also put out by it."
  def start(chat_id) do
    {:ok, pid} = Task.Supervisor.start_child(Sweet.Tasks, fn -> loop(chat_id) end, restart: :temporary)
    Process.link(pid)
    pid
  end

  @doc "Put it out. It silently tolerates the pid of an already dead process and nil."
  def stop(pid) when is_pid(pid), do: Process.exit(pid, :kill)
  def stop(_), do: :ok

  # We renew by a message to ourselves, and not by a sleep: a sleeping process is deaf to everything,
  # including a request to stop.
  defp loop(chat_id) do
    Sweet.Telegram.typing(chat_id)

    receive do
      :stop -> :ok
    after
      @interval -> loop(chat_id)
    end
  end
end
