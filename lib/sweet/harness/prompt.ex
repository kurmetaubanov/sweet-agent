defmodule Sweet.Harness.Prompt do
  require Logger

  @moduledoc """
  The assembly of the prompt. CODE, and not config — the prompt here is a function of the state of
  the session, and not a string chosen from three blanks.

  This is one of the modules that the agent will over time edit itself: to add
  a clause “if the task is about SQL — lay the schema underneath” is cheaper than to fence off
  a configuration for all cases.

  Memory texts arrive here as DATA from `Sweet.Recall` and never
  turn into code: arbitrary text that has got into the Elixir compiler
  is executed (interpolation, attributes, macros).
  """

  # The paragraph about leave for creations, deletions and edits. It is one copy for three places:
  # the system part of the prompt (see `system/1`), the reply of the person (see `compose/4`) and
  # the result of a tool (see `Sweet.Session`, `with_reminder/2`). Copies of one rule diverge at
  # the very first edit of one of them.
  #
  # In the system part it stands LAST, as a piece of its own after the memory section: the rule
  # travels to the model as one text, and the person's reply repeats it at its own end, where the
  # task is read.
  @edits_rule "Any creations, deletions and edits — only after unambiguous, strict leave (acknowledgement) from the master user. Leave is valid only in the session in which it was given; it does not carry over into another session. If, while making edits, it becomes necessary to make new edits for which unambiguous, strict leave (acknowledgement) has not been given, they must not be made without obtaining unambiguous, strict leave (acknowledgement) from the master user. Do not do a git commit without unambiguous, strict leave (acknowledgement) from the master user. Do not do a git push without unambiguous, strict leave (acknowledgement) from the master user. Do not build containers without unambiguous, strict leave (acknowledgement) from the master user. Do not run containers without unambiguous, strict leave (acknowledgement) from the master user."

  @doc "The paragraph about leave for creations, deletions and edits — one for the prompt, for the reply and for the results of tools."
  def edits_rule, do: @edits_rule

  @doc """
  Assemble the messages for the model.

  The whole history does NOT travel in the request. Three things travel:

    1. the last N utterances verbatim — the working memory of the current conversation.
       We count in utterances, and not in paragraphs: the tail of a long answer without the question
       it was answering gives no context. A tool call is not counted as an utterance
       — it weighs zero;
    2. the paragraphs found in the memory by the query “window + question”;
    3. the question itself.

  The order inside the message is the order of the cache: the window first, then what is new this
  turn — what was found and the time, — then the question. Everything that changes from turn to
  turn stands at the end, next to the question: the head of the message stays the same and is read
  from the cache, while what cannot be cached does not cut that head off. The time and what was
  found are useless after the question anyway — the model ends its reading on the question.

  The query to the memory is built from the window and the question together: a bare question catches
  at the places where it itself is asked, while the window sets the topic and that removes this.

  The full history at the same time goes nowhere — it lies in `Sweet.Recall`.

  The obligatory skills do not enter this list: they travel as a system block
  on every turn, outside the search (see `system/1`).
  """
  def build(state, question) do
    tail = Sweet.Recall.tail(state.id, Application.fetch_env!(:sweet, :recall_tail_messages))

    tail_text = Enum.map_join(tail, "\n\n", & &1.text)

    query = memory_query(tail_text, question)

    recalled =
      case Sweet.Recall.search(query) do
        {:ok, found} -> Enum.reject(found, fn {_score, entry} -> entry in tail end)
        {:error, _reason} -> []
      end

    # Skills and paragraphs of memory — IN ONE HEAP. All of them have a vector from one and
    # the same embedder and a cosine to one and the same query, therefore they must be measured
    # with one measure, and not by two selections with different rules. There is no threshold
    # for any of them: we sort everything together and take the first ones.
    found =
      (Enum.map(Sweet.Skills.relevant(query), fn {score, skill} -> {score, :skill, skill} end) ++
         Enum.map(recalled, fn {score, entry} -> {score, :memory, entry} end))
      |> Enum.sort_by(&(-elem(&1, 0)))
      |> Enum.take(Application.fetch_env!(:sweet, :context_take))
      |> with_traces()
      # The attachment could have dragged in what already stands in the verbatim tail: above
      # the same filtering is done for the finds, but the traces arrive after it.
      |> Enum.reject(fn
        {_score, :memory, entry} -> entry in tail
        _other -> false
      end)

    log(found)

    [%{"role" => "user", "content" => compose(state, found, tail, question)}]
  end

  # The query to the memory: the window of the conversation together with the question. A bare
  # question catches at the places where it is itself asked; the window sets the topic, and that
  # removes it.
  #
  # The question is already the last record of the window: it goes into the memory at the same
  # instant as into the inbox (see `put_inbox/4`), while the window is taken after that. To glue
  # it on a second time means to weigh the query with a copy of itself — and a query works the
  # worse the longer it gets. When the cast has not been processed yet, the window has no
  # duplicate either, and then the question stands alone.
  #
  # We cut the duplicate off the JOINED text, and not from the tail record by record: the
  # question is cut into paragraphs by empty lines (see `Sweet.Recall.split/1`), and a question
  # of three paragraphs would lie in the window as three records.
  #
  # Open (`@doc false`) for the sake of checks: a pure function, and to check it through
  # a living turn would mean to raise the memory, the embedder and the model for the sake of
  # a line of text.
  @doc false
  def memory_query(tail_text, question) do
    window =
      if tail_text != "" and String.ends_with?(tail_text, question),
        do: tail_text |> String.replace_suffix(question, "") |> String.trim_trailing(),
        else: tail_text

    if window == "", do: question, else: window <> "\n\n" <> question
  end

  # The traces of calls — AFTER the selection and the cut, and not before. They have no vector, they themselves
  # are never found; they travel attached to their utterance, and in them lie
  # the hashes of jobs — addresses to the logs, by which the model will finish reading the output through
  # read_log. The cut stands above deliberately: it counts what is FOUND, while an attachment
  # is not a find, and to subtract it from the same quota would mean to throw away utterances
  # for the sake of their own traces.
  defp with_traces(found) do
    {memory, skills} = Enum.split_with(found, &(elem(&1, 1) == :memory))

    traced =
      memory
      |> Enum.map(fn {score, :memory, entry} -> {score, entry} end)
      |> Sweet.Recall.with_traces()
      |> Enum.map(fn {score, entry} -> {score, :memory, entry} end)

    Enum.sort_by(skills ++ traced, &(-elem(&1, 0)))
  end

  # What exactly travelled to the model. Without this one can only guess about the selection:
  # the prompt is not stored anywhere, and by the model's answer one cannot understand whether it saw
  # what was found or thought it up itself.
  defp log(found) do
    Logger.info(
      "into the prompt, the first #{length(found)} by closeness:\n" <>
        Enum.map_join(found, "\n", fn
          {score, :skill, skill} -> "  #{f(score)} skill  #{skill.name}"
          {score, :memory, entry} -> "  #{f(score)} #{entry.role} #{String.slice(entry.text, 0, 70)}"
        end)
    )
  end

  defp f(score), do: :erlang.float_to_binary(score * 1.0, decimals: 3)

  defp compose(state, found, tail, question) do
    [
      block("Latest in the conversation:", tail_text(tail)),
      block("Found by meaning (ordered by closeness):", found_text(found)),
      here_and_now(state),
      question,
      @edits_rule
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # The tail of the conversation: utterances are signed with the role, tool calls are not. The role
  # `tool` is visible by the record itself anyway, while a label before it would look like
  # one more utterance of the conversation.
  defp tail_text(tail) do
    Enum.map_join(tail, "\n\n", fn
      %{role: "tool"} = entry -> entry.text
      entry -> "[#{entry.role}] #{entry.text}"
    end)
  end

  # Where and when we are. In the user message, and not in the system one:
  # the system prompt is the same from turn to turn and is therefore cached, while the time
  # changes every turn and would break the cache entirely.
  #
  # In the user message it stands after the window and after what was found, next to the question:
  # everything that changes every turn is gathered in one place at the end, and the head of the
  # message stays the same from turn to turn — that is what the cache reads.
  #
  # The memory is common to all sessions, and without these two lines what is found cannot be
  # placed in time: yesterday's conversation from another chat looks exactly
  # as today's, and the model takes the past for the present.
  defp here_and_now(state) do
    "Now: #{stamp(System.os_time(:second))}. This session: #{state.id}."
  end

  # The time of all marks is one — UTC. The container's time zone may change
  # after a rebuild, and then the old records would turn out to be in a different time than
  # the new ones — silently and without a single sign.
  defp stamp(nil), do: "time unknown"

  defp stamp(unix) do
    unix
    |> DateTime.from_unix!()
    |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
  end

  defp block(_title, ""), do: ""
  defp block(title, body), do: "#{title}\n\n#{body}"

  # The rendering is shared with the `recall` tool on purpose: what memory found by itself and
  # what it found to a question must be read by the model in ONE AND THE SAME form, otherwise
  # the second looks like another kind of knowledge — although it is the same memory.
  @doc false
  def found_text(found) do
    Enum.map_join(found, "\n\n", fn
      {_score, :skill, skill} ->
        skill_text(skill, "skill")

      # A paragraph is signed with the time and the session: the memory is common, and what is found may
      # be from the day-before-yesterday's conversation in another chat. Without a signature this is
      # indistinguishable from what was just said.
      {_score, :memory, entry} ->
        "[#{entry.role} · #{stamp(Map.get(entry, :at))} · session #{Map.get(entry, :session, "?")}] " <>
          entry.text
    end)
  end

  # What goes into the prompt from a skill — for both its kinds, a found one and an obligatory one.
  #
  # Usually this is a path, and not text: the instruction as a whole may be a page long, while
  # it is needed in one turn out of twenty. The model will read the file itself if
  # it takes it up. The “with the body” mode (skills_body / skills_always_body) substitutes the path
  # with text — it was read already at the scan, and the turn does not touch the files.
  #
  # The body goes WITHOUT the header. It is needed only where there is nothing else to name the skill
  # with — when a path stands instead of the text: without the name and the description the line “/skills/…”
  # says nothing. The body names itself: a heading inside the file, for the sake of
  # which the header is not needed.
  defp skill_text(skill, label) do
    case Map.get(skill, :body) do
      nil -> "[#{label}] #{skill.name}: #{skill.description} — #{skill.path}"
      body -> body
    end
  end

  # The obligatory skills. They are in the prompt ALWAYS, therefore this is not a find by the meaning
  # of the question, but a rule — and their place is in the system part, before the question. They are searched
  # once at the start (see Sweet.Skills), therefore their order is by name:
  # there is nothing and no reason to rank. The folder may be absent entirely — then the block is empty,
  # and the system prompt remains one `base()`.
  defp always_skills do
    case Sweet.Skills.always() do
      [] -> ""
      skills -> Enum.map_join(skills, "\n\n", &skill_text(&1, "mandatory skill"))
    end
  end

  # Asking the memory oneself — a section of its own, and not part of `base()`: it stands
  # after the obligatory skills and is about the same thing they are.
  #
  # The rule about the SHAPE of the query comes from a measurement on this very model
  # (`multilingual-e5-small`, the prefixes `query:`/`passage:`): thirteen phrasings of six facts
  # from a live conversation were run — a bare question, a question with the window, a statement of the
  # fact, keywords, first person. All thirteen came out first on their own fact, while the
  # difference between a question and a statement was 0.003 of cosine, that is, noise. What
  # really decides is the LENGTH: a query glued from the whole conversation resembles several
  # memories at once and stops telling them apart, and past 512 tokens the model cuts off the
  # tail — together with the question itself.
  #
  # The rule about quotations is not politeness either. The answers here carry the hashes of jobs, and
  # “these signals were confirmed” said over a recalled line is indistinguishable in the text
  # from a real check — while behind it stands only the fact that it was said so once.
  @asking_memory """
  ## Asking your own memory

  The block "Found by meaning" below is what memory offered on its own: its query was built from the tail of the conversation and the last question. That is often not the same as what you actually need — and `recall` lets you ask memory yourself.

  Call it when:
  - the automatic block came back empty or off-topic;
  - you need a fact from a conversation that is not in this window;
  - you are about to state that something was already decided or already checked, and you are not sure it was in THIS session.

  How to phrase the query — write the utterance that WOULD HAVE CONTAINED the answer, not the question you are asking yourself:
  - a statement of the fact, the question in your head, a couple of keywords — any of these finds the right memory. The shape barely matters;
  - name things by the names they had in the work: the command, the service, the term as it was said. Names find better than a description;
  - one query, one topic. Two topics — two calls. A long query built from the whole conversation resembles several memories at once and stops telling them apart.

  What comes back is memory, not your own answer:
  - it is a quotation of an earlier conversation, up to the day it was said;
  - do not cite it as if you had just checked it — a fact recalled is not a fact verified;
  - a hash or a number that came back may be reused, but the log behind it is opened with `read_log`, not retold from memory.

  If the first query brings nothing useful, change the WORDS, not the punctuation: another name of the same thing, another participant. Two or three shapes, not ten — and if memory stays silent, say so and ask the human.\
  """

  # The system part of the prompt: `base()` — the constant core, the obligatory skills —
  # also constant, but as a separate piece. In the code they are separate deliberately:
  # to extend this construction later is more convenient than to grow one text.
  def system(_state) do
    # The obligatory skills and the memory section stand side by side: both are a rule that is
    # with the model on every turn, and not a find by the meaning of the question. `base()` was not
    # extended by the second one — it is about work with the tools as a whole, while this is about the memory.
    [base(), always_skills(), @asking_memory, @edits_rule]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc "The tools available to the model. The answer is one for all: the job's hash."
  def tools do
    [
      %{
        "name" => "python",
        "description" => """
        A cell of a persistent IPython notebook. This is not a separate
        script: the kernel is the same one as in the previous call, and
        everything you have already done is still there — variables, imports,
        functions, classes, open connections. Carry on from where you stopped.

        Therefore: do not repeat imports you have already made, and do not
        load again what already sits in a variable. Put a downloaded page, a
        read file, a search result into a variable once and work with it from
        there.

        The cell does NOT hold the turn. You get a job hash back at once, and
        the result arrives by itself as a message with the exit code and the
        tail of the output. Do not wait for it by polling: end the turn, take
        up something else or answer the human. If you need the work right now
        for the next step — see `read_log`, but do not spin `sleep`.

        What is in the kernel right now is appended to the message about the
        end of a cell as the line "in the kernel: ..." — look there instead of
        guessing.

        The working directory is /workspace.
        """,
        "input_schema" => %{
          "type" => "object",
          "properties" => %{"code" => %{"type" => "string"}},
          "required" => ["code"]
        }
      },
      %{
        "name" => "bash",
        "description" => """
        A shell command that does NOT hold the turn. It returns at once with a
        handle: you get the job hash, and the command itself goes on in its own
        process in its own process group.

        Why this, if there is the cell: the cell runs in the kernel, this one
        in a shell. `pip install`, `docker build`, `npm test`, walking a
        hundred pages — that is minutes, and neither of them costs you the
        turn. `sleep 30` in a cell holds nothing either: it is a job too.

        When the command has finished, a MESSAGE arrives with the exit code
        and the tail of the output. There is no need to wait for it by
        polling: end the turn, take up something else or answer the human. If
        you need the work right now for the next step — see `read_log`, but
        do not spin `sleep`.

        A non-zero exit code is not an exception: it lies in the message about
        the end, and there is something to branch on.
        """,
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "code" => %{"type" => "string", "description" => "what to run in bash"},
            "cwd" => %{"type" => "string", "description" => "working directory, /workspace by default"}
          },
          "required" => ["code"]
        }
      },
      %{
        "name" => "elixir",
        "description" => """
        An Elixir script, run by `elixir` in its own fresh VM. Same as `bash`
        in how it answers: a job hash at once, the result by itself as a
        message with the exit code and the tail of the output.

        State does NOT persist between calls — unlike the kernel of `python`.
        Every call is a new BEAM: no variables, no modules, no processes from
        the previous one. Whatever has to survive, write to a file in
        /workspace or print and read from the output.

        Take this one, and not `bash` with `elixir -e`, whenever the code is
        Elixir: quoting through the shell mangles heredocs, sigils and
        quotation marks, and the human sees the code as Elixir in the chat.
        A mix project is a different matter — build and test it with `bash`
        (`mix deps.get`, `mix test`), from its own root.

        The working directory is /workspace unless cwd says otherwise.
        """,
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "code" => %{"type" => "string", "description" => "Elixir source, as in a .exs script"},
            "cwd" => %{"type" => "string", "description" => "working directory, /workspace by default"}
          },
          "required" => ["code"]
        }
      },
      %{
        "name" => "read_log",
        "description" => """
        Read the log of a FINISHED job: state, exit code, pieces of the
        output. This is the ONLY way to the full output — the message about
        the end of a job shows the head and the tail and says how much was
        cut, everything else stays in the log.

        A job that is still running is NOT read: a piece of a growing log is
        work in progress, not a result. Do not call this tool again hoping the
        job has finished — the message about the end arrives on its own, with
        the head and the tail in it. Read the log after that, and only if what
        came is not enough.

        The log is addressed by the job hash — that is all you need, and all
        there is.

        head and tail — how many LINES to show from the beginning and from the
        end (a 16 KB ceiling applies on top). grep — a regular expression, if
        what you need is not the whole output but the lines that matter: in a
        log of thousands of lines that is the cheapest thing of all.

        The output itself is not kept in memory: later turns see only the line
        with the job hash, and that line is what brings you back here.
        """,
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "job" => %{"type" => "string", "description" => "job hash, as in the message about its start"},
            "head" => %{"type" => "integer", "description" => "lines from the beginning"},
            "tail" => %{"type" => "integer", "description" => "lines from the end"},
            "grep" => %{"type" => "string"}
          },
          "required" => ["job"]
        }
      },
      %{
        "name" => "job_send",
        "description" => """
        Answer a background job that is waiting for input. The text goes to
        the job's stdin — a newline is added if you do not end with one.

        You learn that a job is waiting from a message: "job <hash> is waiting
        for input: <the prompt>". That message means the job's process really
        stands on a read of its stdin (the hand sees this in /proc), not that
        it went quiet. Answer it the way the prompt asks — `y`, a path, an
        empty line to accept a default.

        If there is nothing sensible to answer, do not guess: stop the job
        with job_signal instead. A wrong answer to a prompt is worse than a
        stopped job — the job will act on it.
        """,
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "job" => %{"type" => "string", "description" => "job hash, as in the message about it"},
            "text" => %{"type" => "string", "description" => "what to write to the job stdin"}
          },
          "required" => ["job", "text"]
        }
      },
      %{
        "name" => "job_signal",
        "description" => """
        Stop ONE background job, leaving the kernel and the rest of the work
        intact. signal="interrupt" — Ctrl-C to the process group (gently),
        signal="kill" — SIGTERM. interrupt by default.
        """,
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "job" => %{"type" => "string"},
            "signal" => %{"type" => "string", "enum" => ["interrupt", "kill"]}
          },
          "required" => ["job"]
        }
      },
      %{
        "name" => "recall",
        "description" => """
        Ask your own memory: the earlier conversations, the memory is shared by all
        sessions. The block "Found by meaning" below is what memory offered on its
        own; this is how you ask it yourself, with a query of your own.

        Phrase the query as the utterance that WOULD HAVE CONTAINED the answer, not
        as the question you are asking yourself. A statement of the fact, the
        question in your head, the names it was discussed under — any of these
        works. What costs is LENGTH: one query, one topic. A long query resembles
        several memories at once and stops telling them apart.

        What comes back is a quotation of an earlier conversation with its date and
        its session. It is not a check — do not cite it as something you have just
        verified yourself. A hash inside it may be reused, but the log behind that
        hash is opened with `read_log`, not retold from memory.
        """,
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{
              "type" => "string",
              "description" => "what to look for, in the words the answer would have been said in"
            },
            "take" => %{"type" => "integer", "description" => "how many paragraphs to bring back"}
          },
          "required" => ["query"]
        }
      }
    ]
  end

  # The two blocks below are verbatim from Prime Agent (packages/coding-agent/src/core/
  # prompts/rlm.ts): LONG_RUNNING_WORK_PROMPT and
  # SIMPLIFIED_TECHNICAL_ENGLISH_PROMPT. The first three lines of the prompt were taken
  # from there earlier, and these were not; because of which the acceleration “iterate step by step”
  # travelled without the limiters that accompanied it in Prime. The order of the stitching is the same
  # as in buildRlmPrompt.
  #
  # We do NOT take USER_PROGRESS_PROMPT from there: it demands of the root agent
  # regular intermediate updates with a plan, blockers and next actions, and this is
  # exactly what makes an agent take extra turns and shower reports. Sweet has no
  # subagents, the updates go to the person by themselves, on the result of the turn.
  @long_running_work """
  For slow or independently completing work, use a nonblocking control loop: start the work, record its handle or output location, then end your turn. Read the result on a later turn or when a reply arrives.
  When delegation is available and useful, assign independent substantive tasks to separate workers. Start independent workers without waiting for each one sequentially, and let them run in parallel.
  Do not keep the turn open by polling with `time.sleep()` or shell `sleep`, and do not replace polling with a long blocking `await`. Await only the short operation needed to start work or inspect a result that is already available; otherwise end the turn.\
  """

  # Formerly the first line was “Use simplified technical English by default for
  # user-facing prose”, and the model read it as an instruction of LANGUAGE: to a Russian
  # question an English answer came. The block was always about clarity, and not about
  # language — now it says so: simplicity. About the language of the answer itself there is a separate
  # rule below, @answer_language.
  @simplified_technical_language """
  Use simplified, plain language by default for user-facing prose.
  Prefer short sentences, common words, and concrete verbs. State one main action or fact per sentence when practical. Use lists for steps or conditions.
  Keep necessary technical terms, names, commands, code, paths, and exact quoted text unchanged. State uncertainty directly.
  Treat this as clarity guidance, not a claim of formal ASD-STE100 compliance. Preserve a user-requested format, tone, terminology, and necessary precision.\
  """

  # Taken verbatim from the user's wording: a report of “a representation of the subject”
  # against a report of “relevant facts about the subject”. The list of measurements is the degenerate
  # case of the second: the reader assembles the picture from it himself.
  @picture_of_subject """
  The user should be able to picture the subject after reading the answer. A report of related facts about the subject is worse than a report that gives a representation of the subject.\
  """

  # Taken verbatim from the user's wording. The rule stands next to
  # “proportionality” and deliberately repeats it from the other side: there — about
  # the volume of the work done, here — about an extra round with a tool.
  @answer_without_extra_tests """
  If you can answer the user's question without additional tests, do it.\
  """

  # The speech of the agent — as a whole, word for word from the system prompt of Claude Code
  # (the section “Text output”). In one's own words one cannot write it better here, and to argue with
  # the original there is nothing to: this is exactly that task and exactly that set of rakes.
  #
  # It was “Answer briefly and to the point” — one line that did not say WHAT
  # it referred to. The agent read it as a vow of silence for the whole turn: it worked
  # in silence and issued a condensed result at the end, while the person all that time looked at
  # blocks of code and wondered what they were for. The missing half is named here directly:
  # «Brief is good — silent is not».
  #
  # Along the way the question about the reasoning is closed too: what must be shown is not the train of thought
  # (“Don't narrate your internal deliberation”), but short updates on
  # the matter. This is also the argument for `show_thinking: false` on the side of the prompt.
  @text_output """
  # Text output (does not apply to tool calls)
  Assume users can't see most tool calls or thinking — only your text output. Before your first tool call, state in one sentence what you're about to do. While working, give short updates at key moments: when you find something, when you change direction, or when you hit a blocker. Brief is good — silent is not. One sentence per update is almost always enough.

  Don't narrate your internal deliberation. User-facing text should be relevant communication to the user, not a running commentary on your thought process. State results and decisions directly, and focus user-facing text on relevant updates for the user.

  When you do write updates, write so the reader can pick up cold: complete sentences, no unexplained jargon or shorthand from earlier in the session. But keep it tight — a clear sentence is better than a clear paragraph.

  End-of-turn summary: one or two sentences. What changed and what's next. Nothing else.

  Match responses to the task: a simple question gets a direct answer, not headers and sections.\
  """

  # A separate rule, although next to it there is “in the language of the request”: that
  # line is about clarity, and in it “the language of the request” stands as an adverbial. The model
  # read it as “how simply to write” and slipped into English or
  # Chinese as soon as a foreign text, code or skill flashed in the question.
  @answer_language """
  Answer in the language the conversation is conducted in — the language of the user's messages. This prompt, the code, and retrieved memory are written in other languages; they do not set the answer language. Switch only when the user switches.\
  """

  # About reading logs — as a separate block, because this rule is about the MEMORY, and
  # not about the tool, and it is not derived from the description of `read_log`.
  #
  # The arrangement from which it follows: the output of a job does not remain in the memory.
  # One line with the hash remains — both in this turn and a week later. Therefore the
  # reading of a log has exactly two deadlines, and both must be named aloud: now, while
  # the output is needed for the next step, and later — when the line with the hash has arrived
  # from the memory, and what is in the log has again become important.
  #
  # The third paragraph — about NAMING THE HASH IN THE ANSWER, and it stands here not for
  # the sake of order. The traces of calls have no vector: they themselves are never found and
  # arrive only attached to a found utterance. And the utterance is embedded —
  # therefore a hash SAID IN WORDS in the answer gets into the search by meaning together
  # with the output for the sake of which it was read. This is the way to leave a note
  # to oneself, and no other mechanism is needed for it: “read_log a1b2c3,
  # such-and-such was confirmed” is found a week later by meaning, while the service line
  # `job a1b2c3 finished` is not.
  #
  # The caveat about “when it decided something” is not politeness. Next to it stands
  # `@text_output`, and without it the rule degenerates into a hash at every
  # mention of work: the person does not need them, and the answer is littered with them.
  @reading_logs """
  The output of a job is not kept for you. A message about a job shows its head and its tail; the rest lives in the log and is addressed by the job hash. Memory keeps the line with the hash, never the output.
  A running job is not read at all: `read_log` answers that it has not finished and returns nothing. Do not poll it and do not wait for it — end the turn or do other work. The message about the end of the job comes by itself and brings the head and the tail with it.
  Read the log when that message is not enough — a longer slice, the beginning, or `grep` for the lines that matter. Read it in the same turn as the message: later there will be the hash and nothing else.
  Retrieved memory brings those lines back: when a recalled piece of an earlier conversation carries a line like "job a1b2c3 finished, exit code 0", that hash still works. If what is in that log bears on the question, read it with `read_log` instead of guessing what it said or re-running the work.
  When a log settled something — confirmed a fact, showed the cause, gave the number you went for — say so in your own words and name the hash: "read_log a1b2c3 — the build fails on the numpy layer, not on torch". Write it as part of the sentence, not as a separate note. That line is what memory keeps and what search finds later, and it is the only way the hash survives with the meaning attached to it.
  Do this when the log decided something, not every time you ran work. A hash for its own sake is noise in an answer a human reads.\
  """

  defp base do
    """
    You are a general purpose agent that uses code to solve tasks.
    You solve tasks by breaking down problems into sub-tasks, writing and executing code, observing results, and iterating one step at a time.
    When you are done, stop calling tools and state your final answer.

    Match the amount of work to the question. Answer a simple question directly, without tools; when a single command answers it, run that one command and answer. Once you have enough to answer, answer — do not re-run a command whose result you already have, and do not confirm a result a second way unless it looked wrong. Do exactly what was asked and do not widen the task on your own initiative; if you notice something adjacent worth doing, say so instead of doing it. If a skill covers the task, go through that skill rather than inventing your own route. When an external service refuses you, read the refusal and decide what to do; do not repeat the same request over and over hoping for a different answer.

    #{@answer_without_extra_tests}

    #{@text_output}

    #{@answer_language}
    #{@long_running_work}

    How to run work that takes time — do this, not the loop:
    Work that takes time is a background job. `python` (a cell in the kernel), `bash` (a command in a shell) and `elixir` (a script in a fresh VM) answer at once with a job hash and wait for nothing: installs, builds, test suites, long downloads, crawls — anything you would otherwise poll with `sleep`. Their output comes to you later, as a message. `read_log`, `job_send` and `job_signal` answer with the result itself: they read a file, write a line, send a signal — there is nothing to wait for.
    Do not wait for a job by looping. End the turn, or do other useful work. The completion message arrives by itself with the exit code and the tail of the output.
    Use `read_log` to read the output of a job, `job_send` to answer one that asks something, and `job_signal` to stop one job.

    A job that waits for input is not a job that is working. When a message says a job is waiting for input, answer it with `job_send` and carry on — or stop it with `job_signal` if the answer is not yours to give. Do not leave it standing: it holds a process and will never finish on its own. When a message says a job has been quiet for a long while, that is only a guess from silence — read the log with `read_log` and ask the human whether to kill it or give it more time.

    #{@reading_logs}

    #{@simplified_technical_language}

    #{@picture_of_subject}

    Working directory: /workspace
    Pre-installed Python packages: ipython, dill, numpy, scipy, pandas, matplotlib, scikit-learn, lightgbm, statsmodels, ruptures, psycopg2-binary, duckdb, pypdf, pdfminer.six, python-docx, python-pptx, openpyxl, Pillow, pylatexenc, requests, httpx, beautifulsoup4, lxml, torch (CPU), playwright.
    Command-line tools: bash, git, curl, ripgrep, jq, sqlite3, tmux, poppler-utils, LibreOffice, docker CLI, uv.
    The docker CLI talks to a filtering proxy, not to the host daemon. Most commands work normally, including run, build, logs and ps. Four things are refused, and retrying will not help: `exec` in any container; `cp`, `stop`, `kill`, `restart`, `rm` and network attach/detach on the stack's own service containers; containers that break out of the sandbox (privileged, added capabilities, host namespaces, devices); and bind-mounting host paths outside the allowed list. Named volumes, tmpfs and --gpus are fine.
    Install additional packages with `pip install <pkg>` (installs into /workspace/.python and is importable straight away, in this turn and in later sessions).

    Local skills live under /skills: /skills/optional and /skills/always. The paths printed with a skill are the paths the hand can actually open — read them when helpful.

    Memory relevant to the user's request is retrieved for you and arrives in your prompt. Nothing else carries it. The hand's filesystem holds no conversation log, no chat history and no session store, and neither does the brain over the network — do not go looking for them there. If the question is about something said earlier and what came in the prompt does not contain it, say you do not have it in memory. Do not investigate your own harness — its containers, ports, source files or environment — unless that is what you were asked about.

    IPython is the agent's long-lived notebook: a persistent control environment for reasoning, context management, state, tool orchestration, and recursive subcalls. Use it to keep intermediate variables, inspect and transform outputs, write small helper functions, and preserve useful state across turns or compaction.

    Do not assume IPython is the native runtime of the external thing being investigated. A repository, package, service, dataset, paper, website, benchmark, or API may have its own environment and normal interface. Evaluate external systems through their own interface, then use IPython to coordinate the process and analyze what comes back.

    When running shell commands from IPython, use `%%bash` cells. If you use `%%bash`, it must be the first line of the code cell: no comments, spaces, blank lines, imports, or Python statements before it. Avoid `!cmd` shell escapes for project commands so shell behavior is explicit and multi-line commands share one shell context.

    Important: do not install dependencies into the IPython kernel just to make an external project import or run there. If a project import, test, script, CLI, or dependency check is needed, run it through that project's own environment and normal command interface. For example, in a Python repo use its documented commands, `uv run ...`, `.venv/bin/python ...`, or the active project interpreter from the repo root. Treat failures from that native environment as the relevant result.

    Use Python for reading, searching, and editing files — it gives you reusable variables you can slice, filter, and act on without re-reading. Always assign read/search results to named variables so you can revisit them later.

    Each `%%bash` cell runs in a throw-away subshell, so shell-level state (`cd`, `export`, `source`, shell variables) does NOT carry to later cells. Keep dependent shell steps inside one `%%bash` cell when they need shared shell state, or use kernel-level equivalents that survive across calls: `%cd <dir>` for the working directory and `os.environ['VAR'] = '...'` (or `%env VAR=...`) for environment variables — these apply to all subsequent `%%bash` calls.

    Python state in the kernel, by contrast, persists across cells: named variables, helper functions, classes, imports, notes, parsed outputs, and helper data structures all remain available in every later turn. Tool calls are themselves Python `await` expressions, so their return values can be bound to variables and composed into program logic just like any other call.

    Files are exchanged with the human through folders, there is no separate tool: what he sends you lands in /workspace/exchange/inbox, and whatever you put into /workspace/exchange/outbox is delivered to him after the turn. Images are shown inline, everything else arrives as a file. No other exchange folder exists — do not invent /data/outbox and the like. Do not put working drafts into outbox, only what the human actually needs.

    Delegate parallel context-heavy research or independent implementation; do a single known lookup, edit, or command inline.

    Don't spawn new terminology. Use the terminology that has already taken shape naturally.
    """
  end

end
