defmodule Sweet.Memory do
  @moduledoc """
  Everything that the node remembers — in one group and with an expressed dependency.

      Sweet.Memory (rest_for_one)
      ├── Sweet.Tables          the owner of the ETS tables
      ├── Sweet.Recall.Store    CubDB: paragraphs of conversations
      ├── Sweet.Sessions.Store  CubDB: the inventory of sessions
      ├── Sweet.Recall          the memory of a conversation
      ├── Sweet.Sessions        the inventory of conversations
      └── Sweet.Skills          the skills

  The strategy `:rest_for_one`, and not `:one_for_one`, because the dependency here is
  real and directed: `Sweet.Recall` without its table and without its
  store is not a memory, but an empty process with the same name. Formerly all this was
  a flat list in `Sweet.Application`, and a restart of any piece left the
  neighbours with references to a dead thing: the table was recreated empty, and nobody
  filled it anew.

  The CubDB stores stand HERE, and are not brought up from the `init/1` of their
  users. Formerly `CubDB.start_link` was called inside `Sweet.Recall.init/1`
  — the process appeared on the disk, but it was not in the inventory of the system, and it was restarted
  not by the supervisor, but by the link. The supervision tree must be the truth about the system.

  `Sweet.Embed` does NOT enter this group deliberately: the vectors are needed by the memory and the skills,
  but they already survive its absence themselves (`catch :exit` in both), the paragraphs
  lie down without vectors and are picked up by re-indexing. The death of the embedder is not
  a reason to bring the memory down together with all the conversations.
  """

  use Supervisor

  def start_link(_opts \\ []), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    recall_dir = Application.fetch_env!(:sweet, :recall_dir)
    sessions_dir = Application.fetch_env!(:sweet, :sessions_dir)

    # The folders — before the children: CubDB opens them at once, and there is no one to create
    # them from its own init.
    File.mkdir_p!(recall_dir)
    File.mkdir_p!(sessions_dir)

    children = [
      Sweet.Tables,
      store(Sweet.Recall.Store, recall_dir),
      store(Sweet.Sessions.Store, sessions_dir),
      Sweet.Recall,
      Sweet.Sessions,
      Sweet.Skills
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # The store under its own name: the user addresses it by name, and not by pid,
  # and survives its restart without holding a stale reference.
  defp store(name, dir) do
    %{
      id: name,
      start: {CubDB, :start_link, [[data_dir: dir, name: name]]},
      type: :worker
    }
  end
end
