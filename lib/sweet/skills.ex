defmodule Sweet.Skills do
  @moduledoc """
  Skills: instructions that are laid underneath into the prompt.

  A skill is a folder with `SKILL.md`, in the front matter a name and one sentence about what
  it is useful for. The format coincides with prime-agent deliberately: skills must
  be transferred between agents without rework.

  Skills are of two kinds, and they differ not in content, but in the way they
  get into the prompt:

    * OBLIGATORY — the folder `skills_always_dir` (`/skills/always`), they lie
      in the system prompt ALWAYS, outside the ranking: this is a rule, and not a find
      by the meaning of the question, there is nothing to search them for.
    * THE REST — the folder `skills_optional_dir` (`/skills/optional`): they are ranked by
      closeness to the question together with paragraphs of memory and get into the prompt only
      if they came out first.

  Usually ONLY the description and the path travel into the prompt. The model reads
  the body of the instruction itself, with an ordinary open() in the hand, and only when the skill is really
  needed by it. The option `skills_body` / `skills_always_body` switches on the “with the body” mode:
  then the text of SKILL.md travels into the prompt whole.

  ## Why a search, and not a list

  In Claude Code and prime the descriptions of all skills hang in the system prompt
  permanently. Twenty skills are several thousand tokens on EVERY turn,
  whether they are needed or not; as the library grows, the constant tax grows.

  Sweet has an embedder, therefore a skill here is the same paragraph with a vector as
  in `Sweet.Recall`, and it is searched in the same way: by the question with the window of the conversation. The selection is also
  the only protection from a bad skill that is named in the literature: the less
  extra is laid underneath, the fewer occasions to apply something out of place.

  ## When the disk is read

  Once at the start (`handle_continue(:scan)`) and on `reload/0`. During a turn nobody
  goes to disk: both the obligatory and the found ones lie in memory, the bodies — there
  too. An edit of a body is visible after `reload`, and not from the first second, — and we
  pay for that with the fact that a turn does not touch the files.

  ## Rights

  The skills folder is mounted into the hand READ-ONLY. They are not edited by the one who
  uses them: an agent editing an instruction on the results of its own failure
  fits the instruction to the failure, and not the other way round.
  """

  use GenServer
  require Logger

  @table :sweet_skills

  # --- API ---

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  The skills closest to the query — not more than `skills_take`.

  After that they are added to paragraphs of memory in a common list, and the first by
  closeness are taken by `Sweet.Harness.Prompt`: one queue for everything, one way of
  selection. But skills must not enter this queue as a whole library.

  The obligatory skills do not take part in this queue at all: they have neither
  a vector nor a place by closeness (see `always/0`).
  """
  def relevant(query) do
    # We search in the asker's process: the table of skills is :ets and is read by everyone
    # at once, while the vectorization of the query went on inside Sweet.Skills and held it all
    # that time. To keep a common process for the sake of reading a common table there is no reason.
    #
    # Indexing is the business of the table's owner: if there are no vectors yet (the embedder
    # was loading weights at the start), we ask it to recompute and wait — this is a rare
    # case, once per raising.
    case ranked() do
      # There are no ranked skills — there is nothing to search and no reason to ask for a recomputation.
      # Formerly this case went into the branch “there are no vectors yet” and called `:index` on
      # EVERY turn, although there was nothing to recompute.
      [] ->
        []

      indexed ->
        if Enum.any?(indexed, & &1.vector) do
          search(indexed, query)
        else
          index()
          search(Enum.filter(ranked(), & &1.vector), query)
        end
    end
  end

  # One must wait for the indexing for AS LONG as the embedder itself can take:
  # inside `scan/0` there stands `Sweet.Embed.encode` with its own deadline, and the minute
  # invented here was less than it. A cold start is exactly the case for the sake of
  # which this path is written: the embedder loads weights for longer than a minute, the call
  # exited by timeout and dragged the task of the turn along with it, while the person received
  # `{:turn_crashed, {:timeout, ...}}` for no reason at all.
  #
  # We catch the exit here too: skills are not a critical path, a turn is counted without them.
  defp index do
    GenServer.call(__MODULE__, :index, index_timeout())
  catch
    :exit, reason ->
      Logger.warning("the skills are not indexed: #{inspect(reason)}")
      :ok
  end

  # A margin on top of the embedder's deadline: the handler itself, besides the vectorization, reads
  # the folder as well.
  defp index_timeout, do: Application.fetch_env!(:sweet, :embed_timeout_ms) + 15_000

  @doc """
  The obligatory skills: from the folder `skills_always_dir`, always in the prompt.

  The order is by name, and not by closeness: there is nothing and no reason to rank them.
  """
  def always do
    @table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(& &1.always)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Re-read both folders. Called after the curator's edits."
  # The deadline is the same as for the indexing: `reload` also scans the folder and calls
  # the embedder, and to wait for it less than it can compute means to exit
  # by timeout on a working reload.
  def reload, do: GenServer.call(__MODULE__, :reload, index_timeout())

  @doc "All the skills as they are now visible — both the obligatory and the found ones."
  def all do
    @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.name)
  end

  # --- Callbacks ---

  # The table is owned by `Sweet.Tables`: the skills are read by the task of the turn, and a table
  # dying together with us would bring the turn down instead of an answer.
  @impl true
  def init(_) do
    # We do not compute the vectors here: the embedder is raised alongside and at the start is still
    # loading the weights. The first request will wait by itself and compute.
    {:ok, %{indexed: false}, {:continue, :scan}}
  end

  @impl true
  def handle_continue(:scan, state) do
    {:noreply, %{state | indexed: scan()}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | indexed: scan()}}
  end

  # Recompute the vectors if they are not there yet. Called from relevant/1 and only
  # then, when there is no index at all: scanning the folder and writing into the table are
  # the business of one process, so that two do not write the same thing.
  def handle_call(:index, _from, state) do
    if state.indexed do
      {:reply, :ok, state}
    else
      {:reply, :ok, %{state | indexed: scan()}}
    end
  end

  # --- Internal ---

  # Returns true if the vectors computed. If they did not — the skills are all
  # the same in the table, simply without vectors, and the next request will try again:
  # the embedder could still be loading the weights.
  #
  # The obligatory ones are read here too and receive no vectors: they are not ranked,
  # and therefore must not cost a turn of the embedder either.
  defp scan do
    root = Application.fetch_env!(:sweet, :skills_root)
    always_dir = Path.join(root, Application.fetch_env!(:sweet, :skills_always_dir))
    optional_dir = Path.join(root, Application.fetch_env!(:sweet, :skills_optional_dir))

    Enum.each(read_dir(always_dir, true), &put/1)

    skills = read_dir(optional_dir, false)

    case Sweet.Embed.encode(Enum.map(skills, & &1.description), "passage") do
      # There are no rankable skills at all — the folder is absent or empty. The index at the same time is
      # BUILT: there is nothing to build. Formerly this case fell into the common branch
      # of failure (`encode([])` answers `{:ok, []}`), `indexed` remained false
      # forever, and every turn called `:index` — that is, blocked the common process of
      # skills and re-read both folders for the sake of an empty answer.
      {:ok, []} when skills == [] ->
        true

      {:ok, vectors} when vectors != [] ->
        skills
        |> Enum.zip(vectors)
        # We compute the length here too, once per skill: it does not change, while on
        # every turn it is needed for the cosine.
        |> Enum.each(fn {skill, vector} ->
          put(%{skill | vector: vector, norm: Sweet.Vec.norm(vector)})
        end)

        Logger.info("skills loaded: #{length(all())}")
        true

      _ ->
        Enum.each(skills, &put/1)
        if skills != [], do: Logger.warning("skills without vectors: the embedder did not answer")
        false
    end
  catch
    :exit, reason ->
      Logger.warning("the skills are not indexed: #{inspect(reason)}")
      false
  end

  # The found ones — those that go into the common selection. The obligatory ones do not go into it.
  defp ranked do
    @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.reject(& &1.always)
  end

  defp read_dir(dir, always?) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries |> Enum.sort() |> Enum.map(&read(dir, &1, always?)) |> Enum.reject(&is_nil/1)

      # No folder — no skills either. There may be no obligatory ones at all: then
      # the system prompt remains one `base()`.
      {:error, _} ->
        []
    end
  end

  defp read(dir, entry, always?) do
    path = Path.join([dir, entry, "SKILL.md"])

    with true <- File.regular?(path),
         {:ok, text} <- File.read(path),
         %{"name" => name, "description" => description} <- frontmatter(text) do
      %{
        name: name,
        description: description,
        path: path,
        # We read the body here too, if the “with the body” mode is on: then the turn does not touch
        # the files at all. Off — nil, and the model will read the file itself.
        body: if(body_mode?(always?), do: body_of(text), else: nil),
        always: always?,
        vector: nil,
        norm: nil
      }
    else
      _ -> nil
    end
  end

  defp body_mode?(true), do: Application.fetch_env!(:sweet, :skills_always_body)
  defp body_mode?(false), do: Application.fetch_env!(:sweet, :skills_body)

  # We parse the front matter ourselves, without a library: exactly two fields are needed, while
  # to drag in a dependency for the sake of two lines is a bad trade.
  defp frontmatter("---\n" <> rest) do
    case String.split(rest, ~r/^---\s*$/m, parts: 2) do
      [head | _] ->
        head
        |> String.split("\n")
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, ":", parts: 2) do
            [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
            _ -> acc
          end
        end)

      _ ->
        nil
    end
  end

  defp frontmatter(_), do: nil

  # The body is everything after the front matter. We do not drag the header into the prompt: it has already
  # been parsed into the name and the description.
  defp body_of("---\n" <> rest) do
    case String.split(rest, ~r/^---\s*$/m, parts: 2) do
      [_head, body] -> String.trim(body)
      _ -> ""
    end
  end

  defp body_of(text), do: String.trim(text)

  defp put(skill), do: :ets.insert(@table, {skill.name, skill})

  # The raw cosine, without centering. The centering ruled the compressed scale —
  # but the scale was needed by the threshold, and there is no threshold: we compare skills and paragraphs
  # with one another and take the first ones. The subtraction of the common mean does not change the order.
  defp search(skills, query) when skills != [] do
    with {:ok, [query_vector]} <- Sweet.Embed.encode([query], "query") do
      # The length of the question is one for all skills, we compute it once.
      query_norm = Sweet.Vec.norm(query_vector)

      skills
      |> Enum.map(&{Sweet.Vec.cosine(&1.vector, &1.norm, query_vector, query_norm), &1})
      |> Enum.sort_by(&(-elem(&1, 0)))
      |> Enum.take(Application.fetch_env!(:sweet, :skills_take))
    else
      _ -> []
    end
  catch
    :exit, _ -> []
  end

  defp search([], _query), do: []
end
