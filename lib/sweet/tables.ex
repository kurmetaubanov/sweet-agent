defmodule Sweet.Tables do
  @moduledoc """
  The owner of the working ETS tables. It does nothing — and that is the whole point.

  The tables `:sweet_recall`, `:sweet_sessions` and `:sweet_skills` were established in the `init/1`
  of those processes that use them, while they are read by outsiders: the inventory —
  by the telegram bridge on `/resume`, the memory and the skills — by the task of a turn. A table dies
  together with its owner, and the reader got not an error, but `badarg`, that is, fell
  itself: the bridge on a press of a button, the turn — into `{:turn_crashed, …}`.

  The table must be owned by one that has nothing to fall with. This process receives no
  messages, does not go to disk and does not talk to the network; it must survive
  exactly as long as the node lives.

  The tables are `:public`: they are still written by the owners of the meaning (`Sweet.Recall`,
  `Sweet.Sessions`, `Sweet.Skills`), each into its own, and the order of writing is held by the
  fact that there is one writer per table. Here there is only the place where they live.

  If this process nevertheless dies, the tables will be recreated empty — therefore it
  stands first in `Sweet.Memory` with the strategy `:rest_for_one`: its restart
  raises anew also those who fill the tables from disk.
  """

  use GenServer

  # The type of a table is part of its meaning, therefore it is here, and not at the user:
  #
  #   * `:sweet_recall` — `:ordered_set`, the key `{session, number of the paragraph}`. The order
  #     of the key is the order of the conversation, the history is selected by a range;
  #   * `:sweet_sessions` and `:sweet_skills` — ordinary `:set` by identifier.
  @tables [
    {:sweet_recall, [:named_table, :public, :ordered_set, read_concurrency: true]},
    {:sweet_sessions, [:named_table, :public, :set, read_concurrency: true]},
    {:sweet_skills, [:named_table, :public, :set, read_concurrency: true]}
  ]

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "The names of the tables — for the tests and for the inventory of the system."
  def names, do: Enum.map(@tables, &elem(&1, 0))

  @impl true
  def init(_) do
    Enum.each(@tables, fn {name, options} -> :ets.new(name, options) end)
    {:ok, %{}}
  end
end
