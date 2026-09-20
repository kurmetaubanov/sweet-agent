defmodule Sweet.Recall do
  @moduledoc """
  The memory of the conversation: paragraphs, their vectors and the search over them.

  The arrangement was tested by experience on a transcript (the memory-experiments repository),
  and all the decisions below come from there:

    * **a paragraph, not an utterance.** An utterance of two pages contains five topics, its
      vector is an averaged mush in which not one of them is expressed;
    * **the window.** A paragraph is embedded together with the W previous ones: “What is left is to pass the
      brain's address to the hand” by itself means nothing, the window restores the meaning.
      We search by the vector with the window, but give back the paragraph itself;
    * **the selection — by sorting in descending order, without a threshold.** Paragraphs and skills
      are put into a common list and compared with one another, and not with an
      invented number;
    * **there is no centering.** It ruled a compressed scale of raw cosines (two
      random texts give 0.85), but the scale was needed only by the threshold.
      Without a threshold the subtraction of the common mean changes nothing — the order from it is
      the same, — but on a small set it degenerates: with a single
      skill the mean equals it itself, and the closeness always came out zero.

  The history at the same time is stored WHOLE — all paragraphs are written here, nothing is
  thrown away. Only a selection travels to the model.

  **The memory is common to all sessions.** We search the whole archive of conversations, and not the
  current one: what was learned yesterday in another chat does not disappear from view only because
  a new conversation has been started today. The verbatim tail (`tail/2`) at the same time is
  strictly one's own — the conversation is conducted one at a time, and one must not confuse the utterances of different ones.

  What is found carries on itself where it is from: the time of the paragraph and the session in which it was
  said. Without this the model takes a past conversation for the current one.
  """

  use GenServer
  require Logger

  @table :sweet_recall

  # A record at the place of a tool call — ONE SHORT LINE: what was called and
  # what job it became. There is no output in it, it remains in the hand's log and
  # is retrieved by the hash (see `Sweet.Session.tool_note/2`).
  #
  # The trace that work went on between two utterances is needed for two reasons.
  # Without it the conversation in the window looks like “asked — answered”, and the model does not
  # see that the answer was obtained, and not invented. And in it lies the hash — the only
  # address to the output, when the output itself did not travel into the memory.
  # The text of the record is chosen by the caller (see note_tool/2).
  @tool_role "tool"

  # One store for all sessions — CubDB, the key is `{session, paragraph number}`.
  #
  # Formerly there was a DETS file per session here, and that made sense: a hard
  # death of the BEAM (`docker rm -f` — exactly that) repairs only the file of the active
  # session, and not the archive for the whole time. For a common memory such protection is unsuitable by
  # construction: the archive is one, it would have to be repaired as a whole, while the file limit of
  # DETS is 2 GB. CubDB writes as an immutable B-tree: an unfinished record does not
  # spoil what has already been written, and there is nothing to repair.
  #
  # ETS remains the working index: the cosine is computed by iterating over all
  # vectors, and they must lie in memory anyway. The disk is needed only in order
  # to survive a restart.

  # --- API ---

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Write an utterance: we cut it into paragraphs, put them in at once, and compute the vectors right after.

  This is called after every turn — both for an utterance of the person and for the answer of the agent.
  We do not wait for an answer: the writer does not need it, while waiting would mean the vectorization,
  that is, the turn would stand because of the memory. The paragraphs lie down at the same instant, and the search will
  pick them up as soon as the vectors arrive.
  """
  def append(session_id, role, text) do
    GenServer.cast(__MODULE__, {:append, session_id, role, text})
  end

  @doc """
  Mark that there was a tool call here. `text` — what remains in the memory.

  ONE record is set per series: ten identical calls in a row — one
  trace, otherwise the window would be clogged with them. The record has no vector and never will: it does not
  take part in the search — only in the verbatim tail of the conversation.
  """
  def note_tool(session_id, text) do
    GenServer.call(__MODULE__, {:note_tool, session_id, text}, 60_000)
  end

  @doc """
  Find the paragraphs relating to the query. The query is the window of the history plus the question.

  We search ALL sessions: the memory is common. The session of a paragraph and its time lie in the record
  itself — by them what is found is signed in the prompt.
  """
  def search(query, take \\ nil) do
    take = take || Application.fetch_env!(:sweet, :recall_take)

    # We search HERE, in the process of the asker, and not in the process of the memory. Formerly
    # the search was a call to Sweet.Recall, and that one during the vectorization of the query
    # answered nobody: every conversation waited for someone else's search, although the only thing common
    # here is the table, and it is :ets and is read by everyone at once.
    #
    # The memory process is needed where there is something to change one by one: counters,
    # the record, the opening of a session. The search changes nothing.
    # From the table we pull ONLY what the cosine is computed from: the key, the vector and its
    # length. Formerly there stood here `match_object`, that is, the whole archive of all
    # conversations was copied into the asker's heap as a whole — together with the texts
    # of the paragraphs, which are not needed for the comparison at all. Out of a hundred candidates
    # `take` goes into the answer, and we collect the texts by them at the end.
    indexed = vectors()

    with true <- indexed != [],
         {:ok, [query_vector]} <- encode([query], "query", "left") do
      # The raw cosine, without centering. The centering corrected the compressed
      # scale — but the scale is important only to the threshold, and there is no threshold any more: paragraphs and
      # skills are put into a common list and the first ones by closeness are taken.
      # The ranking does not change from subtracting one and the same mean.
      query_vector = Sweet.Vec.pack(query_vector)
      query_norm = Sweet.Vec.norm(query_vector)

      scored =
        indexed
        |> Enum.map(fn {key, vector, norm} ->
          {Sweet.Vec.cosine(vector, norm || Sweet.Vec.norm(vector), query_vector, query_norm), key}
        end)
        |> Enum.sort_by(&(-elem(&1, 0)))
        |> Enum.take(take)
        # The paragraphs themselves — only for the winners. A paragraph could disappear between
        # the selection and the collection (the session was closed): we skip it, and do not fall.
        |> Enum.flat_map(fn {score, key} ->
          case :ets.lookup(@table, key) do
            [{^key, entry}] -> [{score, entry}]
            [] -> []
          end
        end)

      {:ok, scored}
    else
      false -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Add to the found paragraphs the traces of their utterances — records of the role `tool` with the same
  `:msg`.

  Why: the traces have no vector, they themselves are never found. And in them lie
  the hashes of jobs — the only addresses to the logs. Without this collection it came out like this:
  the hand has the log, the conversation about it is found, but what to open it with — nobody
  knows, because the line with the hash left the verbatim tail long ago.

  The whole group is taken as a whole, without a limit on the number: the lines are short
  (the first line of the call and the hash), while cutting them would have to be done by some
  arbitrariness — “the first K” would have thrown away exactly the call that is needed. If a turn
  with two dozen jobs starts to inflate the prompt, the limit will stand here.

  The weight of a trace is the weight of its paragraph: it arrived attached and has no estimate of closeness
  of its own.

  It is called AFTER the winners have been selected, and not inside the search. Inside
  the search the collection would be cancelled by the very next step: what is selected is cut by number
  (`:context_take`), and the cut would pass in the middle of a group — the paragraph would remain, while its
  traces fell out, or the other way round.
  """
  def with_traces(found) do
    found
    |> Enum.flat_map(fn {score, entry} ->
      case Map.get(entry, :msg) do
        nil ->
          [{score, entry}]

        msg ->
          traces =
            entry.session
            |> history()
            |> Enum.filter(&(&1.role == @tool_role and Map.get(&1, :msg) == msg))
            |> Enum.map(&{score, &1})

          [{score, entry} | traces]
      end
    end)
    # Two utterances of one group would attract the same traces twice.
    |> Enum.uniq_by(fn {_score, entry} -> {entry.session, entry.index} end)
  end

  @doc """
  Open a session: raise its paragraphs from disk into the working index.

  It is called at the first access to a session — and after a restart of the brain too,
  therefore the conversation survives a fall.
  """
  def open(session_id), do: GenServer.call(__MODULE__, {:open, session_id}, 60_000)

  @doc "Close a session: flush the file and remove it from the memory."
  def close(session_id), do: GenServer.call(__MODULE__, {:close, session_id}, 60_000)

  @doc """
  All the paragraphs of a session in order — the full history, nothing is lost.

  The order is given by the table itself: the key is `{session, number}`, the type is `:ordered_set`, and
  the records of one session lie in it in a row and in increasing order of number. There is nothing to sort
  after the selection, and only one's own session is selected: by the bound beginning of the
  key `:ordered_set` goes by range, and not by iterating over the whole archive.
  """
  def history(session_id) do
    :ets.select(@table, [{{{session_id, :"$1"}, :"$2"}, [], [:"$2"]}])
  end

  # The keys, the vectors and their lengths — everything the closeness is computed from. The texts remain
  # in the table: they have nothing to do in the asker's heap until the best are chosen.
  #
  # Two selection clauses instead of one — because of the old records made before
  # the appearance of the `norm` field: they do not have it at all, while `map_get` by a missing
  # key in a selection does not keep silent, but breaks the selection. The second clause gives nil for them,
  # and the length is computed in place — that way the old memory goes on being searched.
  defp vectors do
    has_vector = {:"/=", {:map_get, :vector, :"$2"}, nil}
    vector = {:map_get, :vector, :"$2"}

    :ets.select(@table, [
      {{:"$1", :"$2"}, [has_vector, {:is_map_key, :norm, :"$2"}],
       [{{:"$1", vector, {:map_get, :norm, :"$2"}}}]},
      {{:"$1", :"$2"}, [has_vector, {:not, {:is_map_key, :norm, :"$2"}}],
       [{{:"$1", vector, nil}}]}
    ])
  end

  @doc """
  The last N UTTERANCES verbatim — the working memory, it travels to the model as it is.

  The count is in utterances, and not in paragraphs: a paragraph is the unit of storage and search, but
  “the last three paragraphs” may turn out to be the tail of one long answer, and the
  question it was answering will not get into the window.

  A record of a tool call weighs ZERO: it is a trace of work, and not an utterance of the
  conversation (see `weight/1`).

  Records made before the appearance of the numbering of utterances lie without the `:msg` field;
  they are counted as one common “zero” utterance — that way the old memory remains
  readable, and does not fall out of the window.
  """
  def tail(session_id, count) do
    session_id
    |> history()
    |> Enum.chunk_by(&Map.get(&1, :msg, 0))
    |> Enum.reverse()
    |> Enum.reduce_while({[], count}, fn
      _message, {taken, left} when left <= 0 ->
        {:halt, {taken, left}}

      [first | _] = message, {taken, left} ->
        {:cont, {[message | taken], left - weight(first.role)}}
    end)
    |> elem(0)
    |> List.flatten()
  end

  @doc """
  The weight of an utterance in the window.

  A record of a tool weighs ZERO: it is a trace of work, and not an utterance of the conversation, and
  to squeeze out with it what was said in words would be a trade the wrong way round. Formerly here
  there stood a two — the call plus the result, — but back then the call itself lay in the memory.
  The zero remains also now, when a line about the call itself is put into the memory: the window
  counts utterances, and not the volume of the record.
  """
  def weight(@tool_role), do: 0
  def weight(_role), do: 1

  # --- Callbacks ---

  # The table is owned by `Sweet.Tables`, the store by `Sweet.Memory`: both outlive
  # us, and the readers (the search goes on in the asker's process) do not
  # get `badarg` from a table that died together with us. The type of the table and its
  # meaning are described there too.
  @store Sweet.Recall.Store

  @impl true
  def init(_) do
    store = @store

    # The whole archive — into the working index, at once and as a whole: the search goes over all
    # sessions, therefore all the vectors are needed in memory anyway. 384 numbers of
    # four bytes — a quarter of a megabyte per thousand paragraphs.
    loaded =
      CubDB.select(store)
      |> Enum.reduce(0, fn {key, entry}, count ->
        :ets.insert(@table, {key, entry})
        count + 1
      end)

    Logger.info("recall: paragraphs raised: #{loaded}")

    # `tails` — the last paragraphs of open sessions as pairs `{role, text}`,
    # exactly as many as the window needs. They are needed on every record, and formerly they were
    # taken by a full iteration over the history of a session (`history/1`) right in the
    # handler: the memory process is one for all conversations, while the cost of a record
    # grew with the length of the conversation. The role lies next to the text, because by it
    # `note_tool` learns whether such a record already stands last.
    {:ok, %{counters: %{}, messages: %{}, tails: %{}, store: store}}
  end

  @impl true
  def handle_call({:open, session_id}, _from, state) do
    # The paragraphs are already in the index — they came up at the start. To open a session
    # means only to restore both counters: of paragraphs and of utterances. We continue the utterances
    # from the maximum plus the weight — otherwise a new record would sit on the number
    # of an existing one and would merge with it into one utterance.
    {count, next_message} =
      session_id
      |> history()
      |> Enum.reduce({0, 0}, fn entry, {paragraphs, messages} ->
        message = Map.get(entry, :msg, 0)
        {max(paragraphs, entry.index + 1), max(messages, message + weight(entry.role))}
      end)

    {:reply, {:ok, count},
     %{
       state
       | counters: Map.put(state.counters, session_id, count),
         messages: Map.put(state.messages, session_id, next_message),
         tails: Map.put(state.tails, session_id, tail_texts(session_id))
     }}
  end

  # The store is one for everything and lives as long as the brain lives — there is nothing to close.
  # We forget only the counters: the session is gone, while the map would grow forever.
  def handle_call({:close, session_id}, _from, state) do
    {:reply, :ok,
     %{
       state
       | counters: Map.delete(state.counters, session_id),
         messages: Map.delete(state.messages, session_id),
         tails: Map.delete(state.tails, session_id)
     }}
  end

  def handle_call({:note_tool, session_id, text}, _from, state) do
    start = Map.get(state.counters, session_id, 0)

    # Already marked — a second trace is not needed: between two such records there is
    # nothing except other tool calls, and they are exactly what was cut out.
    # We compare both the role and the text: the text is the call itself together with the hash
    # of the job, and two different calls in a row are obliged to leave two traces.
    # A repeat has become a rarity here (the hashes are different), and this is right: to collapse
    # dissimilar calls would mean to lose addresses to their logs.
    #
    # We take the last record from the tail: this is the same hot path as
    # `:append` — tool calls come in tens per turn, — and to iterate
    # over the whole history of a session for the sake of one question there is no reason.
    case state.tails |> Map.get(session_id, tail_texts(session_id)) |> List.last() do
      {@tool_role, ^text} ->
        {:reply, :ok, state}

      _ ->
        put(state.store, session_id, %{
          text: text,
          role: @tool_role,
          index: start,
          session: session_id,
          at: now(),
          msg: Map.get(state.messages, session_id, 0),
          # Neither a vector nor attempts to compute it: the record is not searched. For the same reason
          # `attempts` is immediately beyond the limit — reindexing will not pick it up.
          vector: nil,
          norm: nil,
          attempts: Application.fetch_env!(:sweet, :recall_reindex_attempts),
          mark: true
        })

        # A record is as much a paragraph of the history, and it enters the window of neighbours in the same way.
        # To forget it here means to count the window as not what lies on disk.
        {:reply, :ok,
         %{
           state
           | counters: Map.put(state.counters, session_id, start + 1),
             tails: push_tail(state.tails, session_id, [{@tool_role, text}])
         }}
    end
  end

  # The record goes in two steps, and the first does not wait for the second.
  #
  # Step one, here: the paragraphs lie down in the index AT ONCE, without vectors. The conversation
  # is whole from that second — whatever happens to the embedder afterwards.
  #
  # Step two, in the task: the vectors are computed and come back as a message.
  # Formerly both were done inside this handler, and the memory process
  # stood for the whole vectorization — while all the conversations went through it at once.
  #
  # If it did not compute — the paragraphs remain without a vector and wait for reindexing: the same
  # path as before on a refusal of the embedder, only now it is common.
  @impl true
  def handle_cast({:append, session_id, role, text}, state) do
    paragraphs = split(text)
    start = Map.get(state.counters, session_id, 0)
    # The number of the utterance is common to all paragraphs of this record: by it the window later
    # finds the boundaries of the messages (see tail/2).
    message = Map.get(state.messages, session_id, 0)
    window = Application.fetch_env!(:sweet, :recall_window)

    # We take the window by the paragraphs already written plus the new ones from this same utterance:
    # a break at the boundary of utterances would leave the first paragraph of an answer without context.
    #
    # “Already written” is the tail from the state, and not the whole history of the session:
    # nobody looks further back than the window anyway, while the iteration over the history cost
    # the more the longer the conversation, and ALL the conversations paid for it at once.
    previous = Map.get(state.tails, session_id, tail_texts(session_id))
    all = Enum.map(previous, &elem(&1, 1)) ++ paragraphs
    offset = length(previous)

    windowed =
      Enum.with_index(paragraphs, offset)
      |> Enum.map(fn {_paragraph, position} -> window_at(all, position, window) end)

    Enum.with_index(paragraphs, start)
    |> Enum.each(fn {paragraph, index} ->
      put(state.store, session_id, %{
        text: paragraph,
        role: role,
        index: index,
        session: session_id,
        at: now(),
        msg: message,
        vector: nil,
        norm: nil,
        attempts: 0
      })
    end)

    recall = self()

    # On the left: the paragraph stands last in the window, and on a cut from the right it would fly out
    # first — the vector would be computed from the neighbours without itself.
    Task.Supervisor.start_child(Sweet.Tasks, fn ->
      case encode(windowed, "passage", "left") do
        {:ok, vectors} -> send(recall, {:vectors, session_id, start, vectors})
        {:error, reason} -> send(recall, {:vectors_failed, reason})
      end
    end)

    state = %{
      state
      | tails: push_tail(state.tails, session_id, Enum.map(paragraphs, &{role, &1}))
    }
    {:noreply, advance(state, session_id, start, paragraphs, role)}
  end

  # The vectors have arrived — we append them to the paragraphs already lying there. A paragraph could in that
  # time disappear (the session was closed, the file was flushed): then we simply skip it.
  @impl true
  def handle_info({:vectors, session_id, start, vectors}, state) do
    Enum.with_index(vectors, start)
    |> Enum.each(fn {vector, index} ->
      case :ets.lookup(@table, {session_id, index}) do
        [{_key, entry}] ->
          vector = Sweet.Vec.pack(vector)
          put(state.store, session_id, %{entry | vector: vector, norm: Sweet.Vec.norm(vector)})

        [] ->
          :ok
      end
    end)

    {:noreply, state}
  end

  def handle_info({:vectors_failed, reason}, state) do
    # The memory is not a critical path: we do not stop the conversation because of it. But neither
    # must one silently lose paragraphs: they already lie without a vector, all that is left is
    # to call the reindexing, otherwise a piece of the conversation would drop out of the search
    # forever and nobody would learn about it.
    Logger.warning("recall: the vectors did not compute: #{inspect(reason)}")
    schedule_reindex()
    {:noreply, state}
  end

  @impl true
  def handle_info(:reindex, state) do
    limit = Application.fetch_env!(:sweet, :recall_reindex_attempts)

    # We select in the table itself: there are units of uncomputed paragraphs, while hundreds of
    # thousands may lie in the archive — to drag them all here in order to throw away almost
    # all of them there is no reason.
    pending =
      :ets.select(@table, [
        {{:"$1", :"$2"},
         [
           {:==, {:map_get, :vector, :"$2"}, nil},
           {:<, {:map_get, :attempts, :"$2"}, limit}
         ], [{{:"$1", :"$2"}}]}
      ])

    case pending do
      [] ->
        report_abandoned(limit)
        {:noreply, state}

      _ ->
        # In a task, and not here: reindexing is the same vectorization, and
        # there is no reason to keep the memory process on it.
        #
        # But the OWNER writes. Formerly the task itself put the record into ETS and CubDB —
        # while at the same time `:append` came here for the same session and wrote
        # its own. Two wrote with one key by copies taken at different times, and
        # the one who was last won: a fresh vector could be overwritten by
        # an old copy of the paragraph. Now the task only computes and sends
        # the result.
        recall = self()

        Task.Supervisor.start_child(Sweet.Tasks, fn ->
          send(recall, {:reindexed, Enum.map(pending, fn {key, entry} -> retry(key, entry) end)})
        end)

        # There remain unindexed ones that have not exhausted the attempts — we will come in again.
        schedule_reindex()
        {:noreply, state}
    end
  end

  # What was computed by the reindexing. We write HERE, over the current record in the
  # table, and not over the copy with which the task went off to compute: in that
  # time the text of the neighbours could have changed for the paragraph, or it could have disappeared entirely.
  def handle_info({:reindexed, results}, state) do
    Enum.each(results, fn {{session_id, index} = key, vector} ->
      case :ets.lookup(@table, key) do
        [{_key, entry}] ->
          entry = %{entry | attempts: entry.attempts + 1}

          entry =
            if vector,
              do: %{entry | vector: vector, norm: Sweet.Vec.norm(vector)},
              else: entry

          put(state.store, session_id, entry)

        [] ->
          Logger.debug("reindexing of a paragraph that is already gone: #{session_id}/#{index}")
      end
    end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A paragraph together with the W PREVIOUS ones — and not a single following one.
  #
  # Formerly there stood here `Enum.slice(max(0, i - window), window + 1)`, and the length
  # of the piece was constant: for the first paragraphs of a session, where there are no previous ones yet,
  # the window collected the missing ones FORWARD. That is, the vector of the beginning of a conversation was computed
  # by what was said AFTER it — while it was afterwards supposed to be searched by it
  # as by “a paragraph with its past”. Imperceptibly: the text is meaningful, there is no error,
  # it is simply that the beginning of every session is searched by not what it should be.
  #
  # One must cut by position, and not by length: from `position - window` to the paragraph
  # itself inclusive, however many of them have accumulated there.
  defp window_at(texts, position, window) do
    from = max(0, position - window)
    texts |> Enum.slice(from, position - from + 1) |> Enum.join("\n\n")
  end

  # The last paragraphs of a session — exactly as many as the window sees. It is read from
  # disk once, at the opening of a session; after that the tail lives in the state.
  defp tail_texts(session_id) do
    window = Application.fetch_env!(:sweet, :recall_window)
    session_id |> history() |> Enum.map(&{&1.role, &1.text}) |> Enum.take(-window)
  end

  defp push_tail(tails, session_id, texts) do
    window = Application.fetch_env!(:sweet, :recall_window)
    tail = Map.get(tails, session_id, []) ++ texts
    Map.put(tails, session_id, Enum.take(tail, -window))
  end

  # Shift both counters: of paragraphs — by the number of written ones, of utterances — by the weight
  # of the written utterance (a record of a tool weighs zero).
  defp advance(state, session_id, start, paragraphs, role) do
    message = Map.get(state.messages, session_id, 0)

    %{
      state
      | counters: Map.put(state.counters, session_id, start + length(paragraphs)),
        messages: Map.put(state.messages, session_id, message + weight(role))
    }
  end

  # It computes the vector and nothing else. The record is the business of the owner of the table — see
  # `handle_info({:reindexed, _}, _)`.
  defp retry({session_id, index} = key, _entry) do
    window = Application.fetch_env!(:sweet, :recall_window)

    windowed =
      session_id
      |> history()
      |> Enum.map(& &1.text)
      |> window_at(index, window)

    case encode([windowed], "passage", "left") do
      {:ok, [vector]} -> {key, Sweet.Vec.pack(vector)}
      _error -> {key, nil}
    end
  end

  # The embedder may die right during the call (its container was killed, the network
  # blinked). Then the GenServer.call to it exits with an error and drags down the
  # caller — that is, US. And together with Sweet.Recall the ETS table would die too:
  # the whole working index of all sessions. The memory is not a critical path, the conversation must not
  # stop because of it, therefore we catch the exit and return an error.
  defp encode(texts, kind, cut) do
    Sweet.Embed.encode(texts, kind, cut)
  catch
    :exit, reason -> {:error, {:embedder_down, reason}}
  end

  # One record — into the working index and onto disk. CubDB by default flushes
  # the record to disk at once (`auto_file_sync`), therefore there is no separate sync here:
  # a hard death of the BEAM does not lose the tail even without it.
  defp put(store, session_id, entry) do
    :ets.insert(@table, {{session_id, entry.index}, entry})
    :ok = CubDB.put(store, {session_id, entry.index}, entry)
  end

  # The time of the record of a paragraph — in Unix seconds. Not as a string: a string would have to be
  # parsed back in order to compare or show it in another form.
  defp now, do: System.os_time(:second)

  # The attempts are not infinite: if the embedder is down, there is no use in repeats, while
  # the cycle would spin forever. Having exhausted the limit, the paragraph remains in the history
  # without a vector — it is not lost, it is simply not searched.
  defp report_abandoned(limit) do
    # Records of tools are not counted: they have no vector by design, and not because
    # the embedder did not answer. We count in the table — what travels out is a number,
    # and not the archive.
    abandoned =
      :ets.select_count(@table, [
        {{:_, :"$2"},
         [
           {:==, {:map_get, :vector, :"$2"}, nil},
           {:>=, {:map_get, :attempts, :"$2"}, limit},
           {:not, {:is_map_key, :mark, :"$2"}}
         ], [true]}
      ])

    if abandoned > 0 do
      Logger.warning("recall: #{abandoned} paragraphs remained without vectors, the attempts are exhausted")
    end
  end

  defp schedule_reindex do
    Process.send_after(self(), :reindex, Application.fetch_env!(:sweet, :recall_reindex_delay_ms))
  end

  # --- Vector arithmetic ---
  #
  # Our own, without Nx: the dimension is 384, the vectors lie as f32 binaries and are iterated
  # without a single allocation of memory. A dependency of half a gigabyte for the sake of this we
  # have no need of.


  # --- Splitting into paragraphs ---

  # A paragraph is a block between empty lines, and nothing else. A single line break
  # is not a boundary: in markdown inside a table, a formula and a list it means
  # “the next line of the same object”, and to cut by it would mean to crumble
  # a table into lines, and a formula into scraps.
  #
  # There is deliberately no gluing of short pieces here. It ruled out “Done.” and
  # headings, but the price was a second rule on top of the first: in order to understand
  # what a paragraph would turn out to be, one had to keep both in mind. The rule is one.
  defp split(text) do
    text
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
