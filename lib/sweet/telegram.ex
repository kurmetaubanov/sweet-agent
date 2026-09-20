defmodule Sweet.Telegram do
  @moduledoc """
  The bridge to Telegram: a chat is a session.

  The arrangement is two-part, and this is deliberate:

    * the **polling** (`Sweet.Telegram.Poller`) hangs on long polling at Telegram and
      only forwards messages here. It is blocked all the time waiting for
      an answer — to keep in that state the process that is responsible for sessions
      is impossible;
    * **this process** runs the sessions and talks. It never blocks
      for long: the turn is started through `ask_async`, and the answer comes as a message
      `{:sweet_done, _}` — in the same way as in the IEx front.

  One session per chat, with the permanent identifier `tg-<chat>`. Therefore the memory
  of the conversation survives a restart: the paragraphs lie in the common store
  (`priv/recall`), and the session continues from the place where it stopped.
  """

  use GenServer
  require Logger

  alias Sweet.Telegram.Chat
  # The limit of an ordinary message at Telegram. For a rich message it is 32768 — that is
  # why long text goes there, and is not cut into pieces.
  @text_limit 4096

  # We cut the code in a block with a margin for the markup: <pre><code class="language-..">
  # and escaping (&lt; instead of <) add to the length, and one must not hit the limit
  # with an HTML message — to cut ready markup means to tear the tags.
  @code_limit 3000

  @api "https://api.telegram.org/bot"

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "A message from Telegram. Called by the polling."
  def incoming(update), do: GenServer.cast(__MODULE__, {:incoming, update})

  @doc """
  Send text into a chat. Returns the message id — by it we edit later.

  Text longer than `@text_limit` Telegram does not accept at all: it answers 400
  “message is too long”, and the message disappears — the person sees neither it nor
  the reason. That is how the answer about an error of the hand with a long analysis was lost.

  Therefore long text goes as a rich message: its limit is 32768, that is,
  eight times more, and there is no need to cut anything. Cutting into pieces would be
  worse — it tears the text at an arbitrary place, and the markup all the more so.

  Marked-up messages (`parse_mode`) do not get here: their length is watched
  where they are assembled — to cut ready HTML means to tear the tags.
  """
  def send_message(chat_id, text, opts \\ %{}) do
    if String.length(text) > @text_limit and not Map.has_key?(opts, :parse_mode) do
      send_rich(chat_id, text)
    else
      case request("sendMessage", Map.merge(%{chat_id: chat_id, text: text}, opts)) do
        {:ok, %{"result" => %{"message_id" => id}}} -> {:ok, id}
        other -> other
      end
    end
  end

  @doc """
  The agent's answer — as a rich message (Bot API 10.2).

  Markdown goes as it is: Telegram itself draws formulas (`$x^2$` inline,
  `$$...$$` as a block), tables, headings and lists. The model writes
  markdown anyway — formerly we simply showed it as raw text.

  The limit of 32768 against 4096 for an ordinary message, therefore the cutting is almost never
  needed. If Telegram for some reason did not accept it — we fall back to an ordinary
  message: to be left without an answer is worse than without formulas.
  """
  def send_rich(chat_id, markdown) do
    prepared = prepare(markdown)

    # The outgoing mathematics — into the log, verbatim. Formulas disappeared in the chat silently:
    # Telegram answered `ok`, while in the place of the formula an empty line break remained, and
    # there was nothing to say who had eaten it — our substitutions or it. We write only
    # messages with dollars: to duplicate the other answers in the log there is no reason.
    if String.contains?(prepared, "$") do
      Logger.info("rich with mathematics, goes off verbatim:\n#{prepared}")
    end

    case request("sendRichMessage", %{chat_id: chat_id, rich_message: %{markdown: prepared}}) do
      {:ok, %{"ok" => true}} = ok ->
        ok

      other ->
        Logger.warning("rich message rejected: #{inspect(other)}")

        # We go back into send_message/3 ONLY having shortened: long text it
        # sends as a rich message, that is, it would return us here, and so on
        # round. Here it is already known that rich was not accepted, and the ordinary
        # message remains — and it is never longer than the limit.
        send_message(chat_id, tail(markdown, @text_limit))
    end
  end

  # Telegram takes a `$` before a digit as the beginning of a formula: “$50 … $0.001”
  # glues into one, and the text between them disappears.
  #
  # But one must not escape blindly, and this has already cost a broken formula:
  # the model wrote `$$1 - \frac{1}{3} + ...`, the second dollar of the opening pair
  # turned out to be before a digit, it was escaped — and the pair fell apart, and into the chat
  # went raw LaTeX with an orphaned `$$` at the end.
  #
  # Therefore first we single out the mathematics ($$...$$ and $...$) and do not touch it
  # at all, and escape only in the ordinary text between the formulas.
  @math ~r/\$\$.*?\$\$|\$[^\$\n]+\$/s

  defp dollars(text) do
    text
    |> split_on(@math)
    |> Enum.map_join(fn
      {:match, part} -> part
      {:rest, part} -> Regex.replace(~r/\$(?=\d)/, part, "\\\\$")
    end)
  end

  # LATEX BRACKETS INTO DOLLARS. Telegram knows only dollars, while the model out of
  # habit writes `\( … \)` and `\[ … \]` — that is the custom almost everywhere except it.
  #
  # This breaks imperceptibly, and that is the whole meanness. Markdown sees `\(` as an
  # escaped bracket, takes off the slash and prints `(`. The output is a formula in
  # ordinary brackets: neither an error nor garbage, it reads almost normally — and the fact
  # that the render did not work is given away only by `\frac` and `^{}` inside.
  #
  # We go round the code blocks: `\(` lives in python regexes and
  # strings, and a blind substitution would turn working code into mush.
  @code ~r/```.*?```|`[^`\n]+`/s
  @display ~r/\\\[(.*?)\\\]/s
  @inline ~r/\\\((.*?)\\\)/s

  # How many lines of code are still considered “short” and go as monospaced <pre>.
  # The analysis of the threshold and why exactly 50 — at `code_block/1` below.
  @code_pre_max_lines 50


  # Whether to show in the chat a notice about the end of a background job.
  #
  # It is now off, and this is a deliberate choice: this line says nothing to the
  # person — it will ask itself if it wants to see the output (or will ask to
  # show the log). The model, however, still receives the full text of the job with
  # `output:` through the session's mailbox, and this does not depend on the constant.
  #
  # If it becomes true — we will return the line to the chat; edits for this are not needed, only the
  # value here.
  @chat_job_notice false

  # Whether to show in the chat the output that the cell prints as it works
  # (the `sweet_output` frames: `print`, progress bars, a stream to the console).
  #
  # It is off for the same reason as the line about the end of a job: a turn is not a
  # broadcast of what is happening, but an answer. The hand will give the output to the model, that one will retell
  # the needed part in the answer; a raw stream on the way only pushes the answer upwards and
  # costs an edit of the message for every piece.
  #
  # If it becomes true — the live output will return to the chat; edits for this are not needed,
  # only the value here.
  @chat_kernel_output false

  @doc """
  Bring the model's markup to the one that a Telegram rich message understands.

  There are four translations, and each appeared from a silent loss in the chat:

  * a ```latex block (and ```tex) — into dollars. A rich message knows `$…$` and
    `$$…$$`, while a code block with an unknown language it shows as empty: Telegram
    answers `ok`, and in the place of the formula a line break;
  * LaTeX environments (`equation`, `align`, `gather`, `displaymath`) — into the same
    dollars, `align` through `aligned`, which KaTeX understands;
  * `tabular` (with or without the `table` wrapper) — into a markdown table with pipes:
    LaTeX tables the rich markup does not know at all, while pipes it does;
  * `\(…\)` and `\[…\]` — into dollars, and a `$` before a digit is escaped
    so that “$50” does not open a formula (see `latex/1` and `dollars/1`).

  The order is not arbitrary: first we take off the blocks and environments, then we fix
  the brackets and the dollars — otherwise the mathematics taken out of a block will not pass the edit of
  the brackets, and the escaping of a dollar will break an already assembled formula.

  This function is made public for the sake of tests: the translation of markup is what
  breaks silently, and it must be checked not with the eyes in the chat.
  """
  def prepare(markdown) do
    markdown
    |> fenced_math()
    |> environments()
    |> latex()
    |> dollars()
  end

  # ```latex / ```tex — we take out the contents and translate them as ordinary LaTeX.
  # We do not touch blocks with other languages: that is code, and it must remain code.
  @latex_fence ~r/```(?:latex|tex)[ \t]*\r?\n(.*?)```/s

  defp fenced_math(text) do
    Regex.replace(@latex_fence, text, fn _whole, body ->
      # The environment translates itself (a table into pipes, mathematics into dollars), while
      # a bare formula will get dollars from nowhere: in a block they are not written. It
      # needs them — otherwise after the removal of the block raw LaTeX will go into the chat.
      if Regex.match?(~r/\\begin\{/, body) do
        environments(body) <> "\n"
      else
        "$$" <> trim(body) <> "$$\n"
      end
    end)
  end

  # LaTeX environments. Tables — into pipes, mathematics — into dollars.
  @table_env ~r/\\begin\{table\*?\}(?:\[[^\]]*\])?(.*?)\\end\{table\*?\}/s
  @tabular_env ~r/\\begin\{tabular\}\{[^}]*\}(.*?)\\end\{tabular\}/s
  @caption ~r/\\caption\{(.*?)\}/s
  @math_env ~r/\\begin\{(equation\*?|displaymath)\}(.*?)\\end\{\1\}/s
  @aligned_env ~r/\\begin\{(align\*?|gather\*?|alignat\*?)\}(.*?)\\end\{\1\}/s

  defp environments(text) do
    text
    |> then(&Regex.replace(@table_env, &1, fn _whole, body -> table(body) end))
    |> then(&Regex.replace(@tabular_env, &1, fn whole, _body -> table(whole) end))
    |> then(&Regex.replace(@math_env, &1, fn _whole, _env, body -> "$$" <> trim(body) <> "$$" end))
    |> then(
      &Regex.replace(@aligned_env, &1, fn _whole, _env, body ->
        "$$\\begin{aligned}" <> trim(body) <> "\\end{aligned}$$"
      end)
    )
  end

  # A LaTeX table into a markdown table. The caption (`\caption`) goes as a line above
  # the table: it must not be thrown away — it usually says what the table is about.
  defp table(body) do
    caption =
      case Regex.run(@caption, body) do
        [_, text] -> "*" <> trim(text) <> "*\n\n"
        nil -> ""
      end

    rows =
      case Regex.run(@tabular_env, body) do
        [_, inner] -> inner
        nil -> body
      end
      |> String.replace(~r/\\(?:hline|toprule|midrule|bottomrule)\s*/, "")
      |> String.split(~r/\\\\/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn row ->
        row |> String.split("&") |> Enum.map_join(" | ", &trim/1)
      end)

    case rows do
      [] ->
        caption

      [head | rest] ->
        width = head |> String.split(" | ") |> length()
        divider = Enum.map_join(1..width, " | ", fn _ -> "---" end)

        caption <>
          Enum.map_join([head, divider | rest], "\n", &("| " <> &1 <> " |")) <> "\n"
    end
  end

  defp trim(text), do: text |> String.trim() |> String.trim("\n") |> String.trim()

  defp latex(text) do
    text
    |> split_on(@code)
    |> Enum.map_join(fn
      {:match, part} ->
        part

      {:rest, part} ->
        part
        |> then(&Regex.replace(@display, &1, "$$\\1$$"))
        |> then(&Regex.replace(@inline, &1, "$\\1$"))
    end)
  end

  # Cut the text by a regex into pieces: what fell under it and what is between.
  # Needed twice — so as not to touch ready mathematics when escaping and
  # so as not to touch code when replacing the delimiters.
  defp split_on(text, regex) do
    regex
    |> Regex.split(text, include_captures: true, trim: false)
    |> Enum.with_index()
    |> Enum.map(fn
      {part, i} when rem(i, 2) == 0 -> {:rest, part}
      {part, _i} -> {:match, part}
    end)
  end

  @doc "Rewrite an already sent message."
  def edit_message(chat_id, message_id, text, opts \\ %{}) do
    request(
      "editMessageText",
      Map.merge(%{chat_id: chat_id, message_id: message_id, text: text}, opts)
    )
  end

  @doc """
  Show “typing…” in the chat.

  Not a message, but a status: it does not eat the limits on messages and does not litter the chat.
  Telegram puts it out after ~5 seconds, therefore we repeat while the turn is going —
  otherwise on a minute-long task the person sees silence and does not understand whether the
  agent is working or has died.
  """
  def typing(chat_id), do: request("sendChatAction", %{chat_id: chat_id, action: "typing"})

  @doc "Confirm a button press. Called from the chat process."
  def answer_callback(query_id), do: request("answerCallbackQuery", %{callback_query_id: query_id})

  @doc "Fetch the updates. Long polling: hangs up to timeout seconds."
  def get_updates(offset, timeout) do
    case request("getUpdates", %{offset: offset, timeout: timeout}) do
      {:ok, %{"result" => updates}} -> {:ok, updates}
      other -> other
    end
  end

  # --- Callbacks ---

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    # `chats` — the reverse map to `sessions`: the pid of a session -> chat. It is started
    # together with the direct one and removed together with it. Without it the chat was looked up by
    # the session by iterating over the whole map on EVERY event of a turn — and there are tens of events per turn.
    # `chat_ids` — which session the chat is now continuing. Separately from `ids`
    # (session -> its id) deliberately: one map with keys of two kinds reads
    # as “let us put everything in here” and diverges at the very first edit.
    # `refs` — the observation of a session: session -> the monitor's reference. Formerly
    # the monitor was set in `adopt/4` and taken off nowhere: a closed session
    # (`/kill`, `/new`, `/resume`) left it behind itself, while the adoption of the living on
    # a restart hung a second monitor on the same session. To set up an observation and
    # have nothing to take it off with means to accumulate it forever.
    {:ok,
     %{sessions: %{}, chats: %{}, waiting: %{}, ids: %{}, chat_ids: %{}, titles: %{}, refs: %{}},
     {:continue, :restore}}
  end

  # Adopt the living sessions anew.
  #
  # All the maps of the bridge lie in its memory and died together with it, while the sessions did not:
  # they are under their own supervisor and outlive the bridge easily. A restarted bridge
  # knew nothing about them, and a live conversation was left without an addressee: the answer
  # of an ongoing turn went into the warning “answer without a waiting turn”, while
  # “typing…” hung until the next word of the person.
  #
  # Restoration is exactly what a supervisor restarts for: if
  # after a restart the work is lost all the same, the restart is meaningless.
  #
  # What lies where: the living sessions — in the registry (their names are `session:<id>`), the chat
  # of a session — in the inventory (`Sweet.Sessions`), while whether a turn is going is known only to the session
  # itself, and that is what we ask it about (`Sweet.Session.adopt/2`).
  @impl true
  def handle_continue(:restore, state) do
    state = Enum.reduce(live_sessions(), state, &restore_session/2)

    restored = map_size(state.sessions)
    if restored > 0, do: Logger.info("the bridge adopted sessions: #{restored}")

    {:noreply, state}
  end

  defp live_sessions do
    Sweet.Hand.Registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn
      {"session:" <> id, session} -> [{id, session}]
      # Hands and the embedder are counted in the same registry — they are not ours.
      _other -> []
    end)
  end

  defp restore_session({id, session}, state) do
    case Sweet.Sessions.get(id) do
      %{chat_id: chat_id} ->
        state = adopt(chat_id, id, session, state)

        case Sweet.Session.adopt(session, self()) do
          # A turn is going — we start a record about it and light the indicator anew:
          # the former one died together with the bridge, it was linked to it.
          #
          # An adopted turn has no topic: it was held by the bridge, and it went away
          # together with it. The inventory knows it anyway — `touch/3` sets the topic
          # once, from the first turn.
          :running ->
            turn = %{
              chat_id: chat_id,
              typing: Sweet.Telegram.Typing.start(chat_id),
              usage: nil,
              question: nil
            }

            %{state | waiting: Map.put(state.waiting, session, turn)}

          # It did not answer — and God be with it: the maps are already restored, the word of the person
          # will wake this session, and the adoption of the rest will not stop because of it.
          _idle_or_error ->
            state
        end

      # The session is alive, but it is not in the inventory — that means it is not from Telegram (IEx,
      # a check). It does not belong to the bridge.
      _ ->
        state
    end
  end

  @impl true
  def handle_cast({:incoming, %{"message" => %{"from" => %{"id" => user_id}} = message}}, state)
      when is_integer(user_id) do
    if allowed?(user_id) do
      handle_message(message, state)
    else
      # Silently. Anyone can find the bot, and it executes code in a container;
      # to answer a stranger means to confirm that the bot is alive and answering.
      Logger.warning("a message from a stranger: #{user_id}")
      {:noreply, state}
    end
  end

  # A button press under the /resume list. It comes not as a message, but as a separate
  # kind of update, therefore it is parsed separately too.
  def handle_cast(
        {:incoming, %{"callback_query" => %{"from" => %{"id" => user_id}} = query}},
        state
      )
      when is_integer(user_id) do
    if allowed?(user_id) do
      handle_callback(query, state)
    else
      Logger.warning("a press from a stranger: #{user_id}")
      {:noreply, state}
    end
  end

  def handle_cast({:incoming, _update}, state), do: {:noreply, state}

  defp handle_message(%{"chat" => %{"id" => chat_id}, "text" => text} = message, state) do
    {session, state} = ensure_session(chat_id, state)

    cond do
      text == "/start" ->
        Chat.say(chat_id, help())
        {:noreply, state}

      text == "/help" ->
        Chat.say(chat_id, help())
        {:noreply, state}

      text == "/stop" ->
        # NOT HERE: `cancel/1` waits for the session for up to a minute (it is sometimes busy
        # raising its own memory), while the bridge is one for all chats — all that time it
        # parses nobody's messages. The answer to the person will come by itself anyway,
        # as the message `{:sweet_done, _, {:error, :cancelled}}`; to wait for it in the
        # handler there is no reason.
        detach(fn -> Sweet.Session.cancel(session) end)
        {:noreply, state}

      text == "/kill" ->
        {:noreply, kill_session(chat_id, session, state)}

      text == "/new" ->
        {:noreply, new_session(chat_id, session, state)}

      text == "/resume" ->
        show_sessions(chat_id)
        {:noreply, state}

      Map.has_key?(state.waiting, session) ->
        # A turn is already going on this session, and a second one must not be started: the record in
        # the map of waiting turns would be overwritten together with the reference to the indicator of
        # the first, and “typing…” would hang until a restart of the brain.
        #
        # But there is no reason to lose what was said either: the session will mix the text into the ongoing turn
        # at the nearest boundary, having interrupted the current cell for this.
        Sweet.Session.ask_async(session, text, self())
        {:noreply, state}

      true ->
        Sweet.Session.ask_async(session, text, self())

        # We start the record about the turn NOT here: the session itself will announce the beginning of the turn
        # ({:sweet_turn, ...}), and it owns it. Here we hold back only our own
        # — the topic for the inventory: a formatted message has JSON in text, while
        # the inventory needs a readable headline, and only the bridge knows it
        # (see rich_title/1).
        {:noreply, %{state | titles: Map.put(state.titles, session, message["rich_title"] || text)}}
    end
  end

  # A formatted message (Bot API 10.2): there is no text in the update at all, all
  # the content lies as a tree in rich_message. Without parsing, such a message silently
  # fell through into the general handler and was lost entirely — the person wrote, the bot
  # did not answer and did not complain.
  #
  # The tree goes to the model AS IT IS, as JSON. A flat laying out (gluing blocks together,
  # tables into lines with pipes) lost everything for which there was no branch of its own —
  # a formula, a list marker, a details heading, — and would equally lose every
  # new field of the Bot API. The model reads JSON and sees the structure more precisely.
  defp handle_message(%{"chat" => %{"id" => _} = chat, "rich_message" => rich}, state) do
    # The topic of the session is counted separately: in the caption of the /resume button text is needed, and
    # not JSON. See rich_title/1.
    handle_message(
      %{"chat" => chat, "text" => JSON.encode!(rich), "rich_title" => rich_title(rich)},
      state
    )
  end

  # We put the sent file into inbox and say where it landed: for the agent this is the path
  # by which it will open it, for the person — a confirmation that it arrived.
  defp handle_message(%{"chat" => %{"id" => chat_id}, "document" => document}, state) do
    Chat.fetch(chat_id, document["file_id"], Sweet.Files.safe_name(document["file_name"]))
    {:noreply, state}
  end

  defp handle_message(%{"chat" => %{"id" => chat_id}, "photo" => photos}, state)
       when is_list(photos) and photos != [] do
    # Telegram sends a ladder of sizes; the last is the largest.
    photo = List.last(photos)
    Chat.fetch(chat_id, photo["file_id"], "photo_#{photo["file_unique_id"]}.jpg")
    {:noreply, state}
  end

  defp handle_message(_message, state), do: {:noreply, state}

  @doc false
  # The topic of the session for a formatted message. The whole tree goes to the model, while
  # here one short line is needed for the /resume button — therefore we simply
  # collect in a row the text from the fields where Telegram keeps it, and truncate.
  # The structure (tables, markers, delimiters) is not needed in the caption.
  def rich_title(node), do: node |> rich_strings() |> Enum.join(" ") |> String.slice(0, 60)

  defp rich_strings(text) when is_binary(text), do: if(text == "", do: [], else: [text])
  defp rich_strings(list) when is_list(list), do: Enum.flat_map(list, &rich_strings/1)

  # The order of the keys is set explicitly: a traversal of the map would go by the sorting of the keys, and in
  # the caption “inside” would stand before “summary”, while the text of a list item — before its marker.
  @rich_text_keys ["label", "summary", "caption", "text", "expression", "blocks", "items", "cells"]

  defp rich_strings(%{} = node) do
    Enum.flat_map(@rich_text_keys, fn key -> rich_strings(node[key]) end)
  end

  defp rich_strings(_), do: []

  @doc "Fetch the sent file into inbox. Called from the chat process."
  def fetch_to_inbox(chat_id, file_id, name) do
    Sweet.Files.ensure()
    path = Path.join(Sweet.Files.inbox(), name)

    case download(file_id) do
      {:ok, binary} ->
        File.write!(path, binary)
        send_message(chat_id, "Received: #{path}")

      {:error, reason} ->
        Logger.warning("the file #{file_id} did not download: #{inspect(reason)}")
        send_message(chat_id, "The file did not download: #{inspect(reason)}")
    end
  end

  # At Telegram the download is in two steps: getFile gives a path, while the file itself lies at
  # another address (/file/bot<token>/...).
  defp download(file_id) do
    with {:ok, %{"result" => %{"file_path" => remote}}} <-
           request("getFile", %{file_id: file_id}),
         {:ok, %{status: 200, body: body}} <-
           Finch.build(:get, "https://api.telegram.org/file/bot#{token()}/#{remote}")
           |> Finch.request(Sweet.Finch, receive_timeout: 120_000) do
      {:ok, body}
    else
      {:ok, %{status: status}} -> {:error, {:http, status}}
      other -> {:error, other}
    end
  end

  # The sending of everything that appeared in outbox during a turn. We shift the mark ONLY by
  # the fact of a successful sending: otherwise a file that fell during the transfer would disappear from
  # view forever.
  @doc "Give out the files from outbox. Called from the chat process (Sweet.Telegram.Chat)."
  def flush_outbox(chat_id) do
    {files, extra} = Sweet.Files.pending()

    sent = Enum.filter(files, &send_file(chat_id, &1))
    if sent != [], do: Sweet.Files.mark(sent)

    if extra > 0 do
      send_message(chat_id, "#{extra} more files in outbox — they will go with the next turn.")
    end
  end

  defp send_file(chat_id, path) do
    method = if Sweet.Files.image?(path), do: "sendPhoto", else: "sendDocument"
    field = if Sweet.Files.image?(path), do: "photo", else: "document"

    case upload(method, field, chat_id, path) do
      {:ok, %{"ok" => true}} ->
        true

      other ->
        Logger.warning("the file #{path} did not go off: #{inspect(other)}")
        false
    end
  end

  # The allowed user is exactly one and is set in the environment. An empty value
  # does NOT mean “let everyone in”: it means that the bot is not configured, and then it
  # answers nobody — to err towards silence is cheaper.
  #
  # It is taken through `Sweet.Secret`, and not directly from the environment: it is the same kind of
  # secret as the token, and it is obtained from where the rest are — as a file from
  # /run/secrets, while the environment remains a reserve path. Along the way we stop reading
  # the variable on EVERY incoming message: the value is cached, and it
  # changes only with a restart of the container.
  defp allowed?(user_id) do
    case Sweet.Secret.get("tg_allowed_user_id", "TG_ALLOWED_USER_ID") do
      nil -> false
      "" -> false
      allowed -> to_string(user_id) == String.trim(allowed)
    end
  end

  @impl true
  # The refusal “busy” is NOT the end of a turn: it comes to a question asked on top of
  # an ongoing turn, while the turn itself continues. To take off by it the record from the waiting
  # ones means to put out the indicator of a live turn and to throw away its answer when it
  # comes. This is exactly what happened: the model wrote for 129 seconds, the answer of 7626
  # tokens was ready — and it went into the log as “without a waiting turn”.
  def handle_info({:sweet_done, session, {:error, :busy} = result}, state) do
    case Map.get(state.waiting, session) do
      %{chat_id: chat_id} -> Chat.say(chat_id, render(result))
      nil -> Logger.warning("the refusal “busy” without a waiting turn: #{inspect(session)}")
    end

    {:noreply, state}
  end

  def handle_info({:sweet_done, session, result}, state) do
    # The answer knows from which session it is — we take the record by the key. Formerly here
    # the FIRST record of the map was taken: with two waiters the answer went into the wrong
    # chat and put out someone else's indicator, while with an empty map the answer disappeared silently.
    case Map.pop(state.waiting, session) do
      # There is no record about the turn, but the answer is there. Formerly it went off into a warning and
      # disappeared — the person was left without an answer that had already been paid for.
      # The bridge knows the chat of a session without a record about the turn too: it is started at the very first
      # word and outlives the turn.
      {nil, _} ->
        case Map.fetch(state.chats, session) do
          {:ok, chat_id} ->
            Logger.warning("an answer without a record about the turn, we give it into the chat: #{inspect(session)}")
            Chat.rich(chat_id, render(result))
            Chat.flush_outbox(chat_id)

          :error ->
            Logger.warning("an answer without a chat: #{inspect(session)}, #{inspect(result)}")
        end

        {:noreply, state}

      {turn, waiting} ->
        Sweet.Telegram.Typing.stop(turn.typing)
        Chat.rich(turn.chat_id, render(result))
        # The usage as a separate message, and not as a postscript to the answer: otherwise it
        # will get into the rich markup and will argue with it for attention.
        if turn.usage, do: Chat.say(turn.chat_id, turn.usage)
        # We take the files AFTER the turn: everything the agent wrote is already written.
        Chat.flush_outbox(turn.chat_id)
        {:noreply, %{state | waiting: waiting}}
    end
  end

  # A turn has begun — and we learn about it from the one who leads it. Here and only
  # here is the record about the turn started: formerly it was started by the arrival of a message from
  # the person, that is, the bridge decided for the session whether a turn was going or not. While a turn
  # began in a single way, the guess coincided with the truth; a turn awakened
  # by a job (Sweet.Session.wake/2) no longer fell into it — the answer came to a
  # session that the bridge “was not waiting for”, and was lost in the warning.
  #
  # We take the chat from our map of sessions: it is started at the very first message and
  # outlives the turn. The topic for the inventory is its own, deferred in titles; an awakened
  # turn does not have it, then the topic is what the turn was started with.
  def handle_info({:sweet_turn, session, question}, state) do
    case Map.fetch(state.chats, session) do
      {:ok, chat_id} ->
        {title, titles} = Map.pop(state.titles, session)

        turn = %{
          chat_id: chat_id,
          typing: Sweet.Telegram.Typing.start(chat_id),
          usage: nil,
          question: title || question
        }

        {:noreply, %{state | waiting: Map.put(state.waiting, session, turn), titles: titles}}

      :error ->
        Logger.warning("a turn began at a session without a chat: #{inspect(session)}")
        {:noreply, state}
    end
  end

  # The usage for a turn comes before the answer — we hold it back until the sending of the answer,
  # so that the figures go after it, and not before.
  def handle_info({:sweet_usage, session, turn_usage, session_usage, elapsed_ms}, state) do
    # Along the way we mark the turn in the inventory: the time, the counter, the cost and — if there is
    # none yet — the topic of the session.
    with %{question: question} <- Map.get(state.waiting, session),
         id when not is_nil(id) <- Map.get(state.ids, session) do
      Sweet.Sessions.touch(id, question, turn_usage)
    end

    {:noreply,
     update_turn(
       state,
       session,
       &%{&1 | usage: Sweet.Cost.report(turn_usage, session_usage, elapsed_ms)}
     )}
  end

  # The agent went to execute code — we show it as a separate message, which we
  # NO longer touch. Formerly the output was also appended here, but an unfolded quote
  # collapses at every edit: the person unfolded the code, and it closed upon it.
  # The utterance reached the ongoing turn. Silently: a confirmation here is extra noise —
  # the person sees anyway that the turn continues, and its words will arrive by themselves.
  def handle_info({:sweet_steer, _session, _text}, state), do: {:noreply, state}

  def handle_info({:sweet_tool, session, code, lang}, state) do
    {:noreply,
     update_turn(state, session, fn turn ->
       # A mark at the moment when the code actually went into the chat. Together with “the code
       # worked for N ms” from the session, by the log the whole order is visible: first
       # they showed it, then they executed it.
       Logger.info("the code went into the chat, #{String.length(code)} characters")
       Chat.code(turn.chat_id, code_block(code, lang), code_opts())
       turn
     end)}
  end

  # The output of the cell as it appears. Nothing goes into the chat from here while
  # @chat_kernel_output is off: the code that the agent spins is its work,
  # and not a conversation with the person. The turn ends with an answer anyway, and in it
  # there is that for the sake of which the work was going.
  #
  # When the constant is switched on, the showing will return from here too: the first piece of output
  # is answered by a new message, after that it is appended, but not more often than once per
  # `edit_interval_ms` — Telegram has a limit on the frequency of edits, and to hit
  # it means to get a 429 instead of a picture of what is happening.
  def handle_info({:sweet_output, session, _name, text}, state) do
    if @chat_kernel_output do
      Chat.output(chat_id_of(state, session), text)
      {:noreply, state}
    else
      Logger.debug("the output of the cell without a message into the chat: #{String.slice(text, 0, 200)}")
      {:noreply, state}
    end
  end

  # The hand refused — we say it at once, without waiting for the end of the turn. The turn at the same time
  # continues: the model can manage without code, as indeed happened with 409.
  def handle_info({:sweet_error, session, text}, state) do
    {:noreply,
     update_turn(state, session, fn turn ->
       Chat.say(turn.chat_id, "⚠️ " <> text)
       turn
     end)}
  end

  # The model fell silent — we report it and continue to wait. We do not touch the turn: the pause
  # often ends with an answer, and if not — the person at least knows what it is waiting for.
  #
  # Without an icon: the text of the pause speaks for itself anyway, while the “⏳” before it was
  # the only decoration in a correspondence where everything else is words.
  def handle_info({:sweet_notice, session, text}, state) do
    {:noreply,
     update_turn(state, session, fn turn ->
       Chat.say(turn.chat_id, text)
       turn
     end)}
  end

  # The word of the agent before the calls — without an icon, like the pause of the stream. The icon
  # was started to distinguish an utterance from a pause, but it was later removed from the pause,
  # and there was nothing left to distinguish it from. Worse: “💭” read as “I am showing thoughts”,
  # although what arrives here is SPEECH addressed to the person. In a correspondence where everything
  # else is words, icons only make noise.
  def handle_info({:sweet_aside, session, text}, state) do
    {:noreply,
     update_turn(state, session, fn turn ->
       Chat.say(turn.chat_id, text)
       turn
     end)}
  end

  # A background job of the hand is over. There may be no turn here at all, therefore we look for the session
  # in the state, and not by a waiting turn.
  #
  # Nothing goes into the chat from here while @chat_job_notice is off: the line
  # “job jN finished” is not for the person to read, and it did not order the work for the sake of
  # a report about it. If it wants to see the output — it will ask, and the model will show it from
  # the log: the detailed text of the job lies in the session's queue and in the job's file.
  #
  # The event itself must not be lost anyway, even when we are silent about it in the chat:
  # by it one sees that the session is alive and that the job is closed. Therefore a switched-off
  # constant is “not to show”, and not “not to receive”.
  def handle_info({:sweet_job, session, text}, state) do
    {:noreply, maybe_send_job_notice(state, session, text)}
  end

  # We do not send pieces of the model's text into the chat: an edit of the message for every piece
  # would hit the limits, while the ready answer comes right after as one message.
  #
  # The clause was two-element, `{:sweet_delta, _text}`, while the session sends
  # a three-element `{:sweet_delta, session, text}` — like all its other
  # messages. There was never a match, the pieces fell into the general handler
  # below. The result is the same — we do not show them anyway, — but the code lied about its intention,
  # and the very first attempt to do something here would have gone into a dead clause.
  def handle_info({:sweet_delta, _session, _text}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    chats = for {chat, ^pid} <- state.sessions, do: chat

    # The session died without answering: to put out the indicator and to tell the person.
    # Otherwise “typing…” hangs forever, while it waits for an answer that will not be.
    state =
      case Map.pop(state.waiting, pid) do
        {nil, _} ->
          state

        {turn, waiting} ->
          Sweet.Telegram.Typing.stop(turn.typing)
          Logger.warning("session died mid-turn: #{inspect(reason)}")
          Chat.say(turn.chat_id, "The turn broke off: #{inspect(reason)}. Ask again.")
          %{state | waiting: waiting}
      end

    {:noreply,
     %{
       state
       | # The monitor worked out by itself — there is nothing to take off, we forget the reference.
         refs: Map.delete(state.refs, pid),
         sessions: Map.drop(state.sessions, chats),
         chats: Map.delete(state.chats, pid),
         ids: Map.delete(state.ids, pid),
         titles: Map.delete(state.titles, pid)
     }}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- Internal ---

  # Show the end of a job to the person — or not, depending on @chat_job_notice.
  # We look for the chat in `state.sessions`: by the moment of the event there may be no turn any more.
  defp maybe_send_job_notice(state, session, text) do
    case Map.fetch(state.chats, session) do
      {:ok, chat_id} ->
        if @chat_job_notice do
          Chat.say(chat_id, String.slice("✔️ " <> text, 0, 3500))
        else
          Logger.debug("the end of a job without a message into the chat: #{text}")
        end

        state

      :error ->
        Logger.warning("the end of a job without a chat: #{inspect(session)}")
        state
    end
  end

  # The session of a chat. We NO longer ask the process about liveness: `Process.alive?`
  # answers about a moment that is already gone, and in a lost race the bridge
  # sent a question to a dead session — the cast went nowhere, and the person received
  # neither an answer nor a refusal.
  #
  # We ask OTP. `Sweet.start/1` is idempotent by name: a living session with this
  # id will be returned as it is (the registry will not let a second one be raised), a dead one — will rise
  # anew. The registry decides, and not our guess.
  defp ensure_session(chat_id, state) do
    id = Map.get(state.chat_ids, chat_id) || session_id(chat_id)
    {:ok, session} = Sweet.start(id: id)

    # The same process as before — we
    if Map.get(state.sessions, chat_id) == session do
      {session, state}
    else
      {session, adopt(chat_id, id, session, state)}
    end
  end

  # Without an explicit choice we continue the last session of the chat: a person who wrote
  # to the bot after a break expects a continuation of the conversation, and not a clean sheet.
  # Only /new starts a new one.
  defp session_id(chat_id) do
    case Sweet.Sessions.latest(chat_id) do
      nil -> new_id(chat_id)
      entry -> entry.id
    end
  end

  defp open_session(chat_id, id, state) do
    {:ok, session} = Sweet.start(id: id)
    {session, adopt(chat_id, id, session, state)}
  end

  # Take a session under supervision: the monitor, both maps and the inventory.
  #
  # We mark the inventory WITHOUT waiting: inside `register` there is a record to disk, and formerly
  # the bridge stood on it in the middle of parsing an incoming message — that is, the whole
  # incoming stream of all chats waited for one disk. The answer from there was needed by nobody
  # and here: we never read the returned record.
  defp adopt(chat_id, id, session, state) do
    Sweet.Sessions.register_async(id, chat_id)

    # We observe exactly once per session: a second monitor would bring a second
    # `:DOWN` and a second “The turn broke off” into the chat.
    refs =
      if Map.has_key?(state.refs, session),
        do: state.refs,
        else: Map.put(state.refs, session, Process.monitor(session))

    %{
      state
      | refs: refs,
        sessions: Map.put(state.sessions, chat_id, session),
        chats: Map.put(state.chats, session, chat_id),
        ids: Map.put(state.ids, session, id),
        chat_ids: Map.put(state.chat_ids, chat_id, id)
    }
  end

  # To do what someone else is waiting for — but not in the bridge.
  #
  # The bridge is one for all chats, and it has the same rule as the chat processes (see
  # `Sweet.Telegram.Chat`): it decides WHAT to do, and waiting is not its business.
  # The stopping of a session and the breaking of a turn wait for half a minute and more, and all that time
  # the bridge would parse the incoming of not a single chat.
  #
  # Under a supervisor and without a link: a fallen cleanup is no reason to bring the bridge down, and
  # nobody reads an answer from it.
  defp detach(fun) do
    Task.Supervisor.start_child(Sweet.Tasks, fun)
    :ok
  end

  # The time in the identifier, so that the sessions of one chat do not collide with the file names
  # of the memory.
  defp new_id(chat_id), do: "tg-#{chat_id}-#{System.os_time(:second)}"

  # /kill — to put out the session entirely: the turn, the hand and the process itself. The memory on disk
  # is intact, the session remains in the inventory and is raised through /resume. This is how
  # it differs from /stop, which breaks off only the current turn.
  defp kill_session(chat_id, session, state) do
    detach(fn -> DynamicSupervisor.terminate_child(Sweet.SessionSupervisor, session) end)
    Chat.say(chat_id, "The session is closed. /new — start a new one, /resume — return to a previous one.")
    forget(state, chat_id, session)
  end

  defp new_session(chat_id, session, state) do
    # We put out the previous one, but do not wait: the session has a conversation with the hand in `terminate/2` and
    # the closing of the memory, while the new one does not depend on its death — their ids are different, and in
    # the registry they will not collide.
    detach(fn -> DynamicSupervisor.terminate_child(Sweet.SessionSupervisor, session) end)
    state = forget(state, chat_id, session)
    {_session, state} = open_session(chat_id, new_id(chat_id), state)
    Chat.say(chat_id, "A new session. The previous one has not gone anywhere — /resume.")
    state
  end

  defp forget(state, chat_id, session) do
    # There is no reason to keep the chat process: the conversation is closed, while an unfinished live
    # output in it belongs to nobody.
    Chat.close(chat_id)

    case Map.pop(state.waiting, session) do
      {nil, _} -> state
      {turn, waiting} ->
        Sweet.Telegram.Typing.stop(turn.typing)
        %{state | waiting: waiting}
    end
    |> then(fn state ->
      # We take off the observation together with the records: the session is closed, and its `:DOWN`
      # will tell us nothing any more. `:flush` also throws away one that has already arrived.
      if ref = Map.get(state.refs, session), do: Process.demonitor(ref, [:flush])

      %{
        state
        | refs: Map.delete(state.refs, session),
          sessions: Map.delete(state.sessions, chat_id),
          chats: Map.delete(state.chats, session),
          # We do not touch `chat_ids`: it records which session the chat is continuing,
          # and this record lives longer than the process. It is changed by the one who transfers the
          # chat to another session (/new, /resume) — through adopt/4.
          ids: Map.delete(state.ids, session),
          titles: Map.delete(state.titles, session)
      }
    end)
  end

  defp show_sessions(chat_id) do
    case Sweet.Sessions.list(chat_id) do
      [] ->
        Chat.say(chat_id, "There are no previous sessions.")

      entries ->
        keyboard = Enum.map(entries, &[%{text: Sweet.Sessions.label(&1), callback_data: "r:#{&1.id}"}])
        Chat.say(chat_id, "What to return to:", %{reply_markup: %{inline_keyboard: keyboard}})
    end
  end

  defp handle_callback(%{"id" => query_id, "data" => "r:" <> id, "message" => message}, state) do
    chat_id = message["chat"]["id"]

    Chat.ack(chat_id, query_id)

    state =
      case Map.fetch(state.sessions, chat_id) do
        {:ok, current} -> forget(state, chat_id, current)
        :error -> state
      end

    {_session, state} = open_session(chat_id, id, state)
    entry = Sweet.Sessions.get(id)
    Chat.say(chat_id, "Returned: #{(entry && entry.title) || id}")
    {:noreply, state}
  end

  # A press that we do not understand must be confirmed anyway — otherwise
  # the button spins for the person until the timeout. We take the chat from the press itself.
  defp handle_callback(%{"id" => query_id} = query, state) do
    case get_in(query, ["message", "chat", "id"]) do
      nil -> Logger.warning("a press without a chat: #{inspect(query_id)}")
      chat_id -> Chat.ack(chat_id, query_id)
    end

    {:noreply, state}
  end

  defp help do
    """
    sweet is in touch. Write — I answer; I execute code in a container.

    /stop — break off the current turn, the conversation remains
    /kill — close the session altogether
    /new — start a new session
    /resume — return to a previous one

    Files: send any — it will land in /workspace/exchange/inbox. Everything that the agent
    puts into /workspace/exchange/outbox will arrive here after the turn.
    """
  end

  # We edit the turn of the session from which the message came. Neither a search for “the first
  # one that comes along”, nor the assumption “there is only one turn per chat”.
  # The chat by the session. The live output comes from the session, and is addressed to the chat — and
  # the bridge has the map of sessions, there is no reason to wait for a turn for this.
  defp chat_id_of(state, session), do: Map.get(state.chats, session)

  defp update_turn(state, session, fun) do
    case Map.get(state.waiting, session) do
      nil ->
        Logger.warning("a message of a turn without a waiter: #{inspect(session)}")
        state

      turn ->
        %{state | waiting: Map.put(state.waiting, session, fun.(turn))}
    end
  end

  # Code: short — as a monospaced block, long — as a collapsed quote.
  #
  # In Telegram one can collapse ONLY a quote, while a <pre> inside a quote it
  # throws away — checked by six trials in a live chat, including MarkdownV2.
  # Therefore “monospaced and collapsed” at the same time is unattainable, and the attempt
  # to sit on two chairs (a header as a block plus a quote with the full text)
  # ended in two blocks in a row for one and the same code.
  #
  # Since both at once is impossible, we choose by length, and both choices are honest:
  #
  #   * short code (up to @code_pre_max_lines lines) goes as <pre> — monospaced,
  #     without collapsing. For the sake of three or four lines there is no reason to hide the text under a tap:
  #     there is no gain, but there is a superfluous action. A collapsed quote
  #     shows about three lines, so the threshold is noticeably above three;
  #   * long code — as a collapsed quote, as before. A sheet covering half the screen
  #     squeezes out the answer, and it is what must be collapsed.
  #
  # We count the lines AFTER the removal of the trailing empty ones: the code almost always ends
  # a line break, and without the removal the final \n would give an extra empty element
  # and would overstate the count by one — at the threshold boundary this would decide the outcome.
  # Empty code also goes as <pre>: it is short by definition.
  #
  # In code and output links turn up every now and then — Telegram draws a preview
  # card for them, and a technical quote becomes overgrown with a picture of someone else's
  # site. We switch it off: link_preview_options came to replace the outdated
  # disable_web_page_preview and works both on sendMessage and on editMessageText.
  @doc false
  def code_opts, do: %{parse_mode: "HTML", link_preview_options: %{is_disabled: true}}

  # We label the language explicitly. Without the class the Telegram client determines it itself and on a
  # short shell one-liner misses — bash is shown as python.
  # This does not touch the copy button: it depends on the length of the block, and not on
  # the language (checked on six variants of markup — with two lines nobody has it,
  # with twenty everyone has it, including <pre> without a class).
  #
  # To a collapsed quote we do NOT pass the language AS A CLASS: there is no highlighting in it by
  # construction, there it is monospacing and collapsing, and not a code block. But the label
  # itself is needed here too: with short code the language is visible, while a long one is the same
  # work of the agent, and by a collapsed sheet it was impossible to understand whether it was python or
  # bash. We write it as the first line inside the quote, in bold: the line takes up
  # room in the collapsed view, therefore it is one and short.
  @doc false
  def code_block(code, lang) do
    # We cut the code itself, and not the assembled markup: an HTML message has its own limit, while
    # a cropped tag is a broken message instead of a long one.
    code = tail(code, @code_limit)

    if code_lines(code) <= @code_pre_max_lines do
      "<pre><code class=\"language-#{lang}\">" <> escape(code) <> "</code></pre>"
    else
      "<blockquote expandable><b>" <>
        escape(lang) <> "</b>\n" <> escape(code) <> "</blockquote>"
    end
  end

  defp code_lines(code) do
    code
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> length()
  end

  # The output — as a monospaced block, as a tail: what is interesting is what is happening
  # now, and not what it all started with.
  @doc false
  def output_block(output) do
    "<pre>" <> escape(tail(output, 1_500)) <> "</pre>"
  end

  defp tail(text, limit) do
    if String.length(text) <= limit,
      do: text,
      else: "…" <> String.slice(text, -limit, limit)
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp render({:ok, text}) when is_binary(text) and text != "", do: text
  defp render({:ok, _}), do: "(an empty answer)"
  defp render({:error, :cancelled}), do: "Stopped."
  defp render({:error, :busy}), do: "I am still thinking about the previous question. /stop — to interrupt."
  defp render({:error, reason}), do: "Error: #{inspect(reason)}"

  # The only door outward — and the only place where one can learn that it did not
  # go outward. Formerly nobody reported a sending error: `send_message`
  # returned it to the caller, and the caller did not look at it. The answer might not reach
  # the chat, without leaving a single line in the log.
  #
  # The polling of updates is excluded from this rule: its timeouts are an ordinary thing
  # with long polling, and the polling itself already speaks about them.
  defp request(method, params) do
    url = @api <> token() <> "/" <> method

    :post
    |> Finch.build(url, [{"content-type", "application/json"}], JSON.encode!(params))
    |> Finch.request(Sweet.Finch, receive_timeout: 60_000)
    |> case do
      {:ok, %{status: 200, body: body}} ->
        JSON.decode(body)

      {:ok, %{status: status, body: body}} ->
        log_failure(method, "#{status}: #{String.slice(body, 0, 300)}")
        {:error, {status, body}}

      {:error, reason} ->
        log_failure(method, inspect(reason))
        {:error, reason}
    end
  end

  defp log_failure("getUpdates", _reason), do: :ok
  defp log_failure(method, reason), do: Logger.warning("telegram #{method} did not go through: #{reason}")

  # The file goes as multipart/form-data: one cannot pass the contents as JSON, and
  # as a link there is nowhere to — the file lies inside the container.
  defp upload(method, field, chat_id, path) do
    boundary = "sweet#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
    name = Path.basename(path)

    body = [
      part(boundary, ~s(name="chat_id"), nil, to_string(chat_id)),
      # The caption is the file name: in the chat otherwise one cannot understand what exactly was sent.
      part(boundary, ~s(name="caption"), nil, name),
      part(boundary, ~s(name="#{field}"; filename="#{name}"), "application/octet-stream", File.read!(path)),
      "--#{boundary}--\r\n"
    ]

    :post
    |> Finch.build(
      @api <> token() <> "/" <> method,
      [{"content-type", "multipart/form-data; boundary=#{boundary}"}],
      IO.iodata_to_binary(body)
    )
    |> Finch.request(Sweet.Finch, receive_timeout: 300_000)
    |> case do
      {:ok, %{status: 200, body: response}} -> JSON.decode(response)
      {:ok, %{status: status, body: response}} -> {:error, {status, response}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp part(boundary, disposition, type, content) do
    [
      "--#{boundary}\r\n",
      "content-disposition: form-data; #{disposition}\r\n",
      if(type, do: "content-type: #{type}\r\n", else: ""),
      "\r\n",
      content,
      "\r\n"
    ]
  end

  def token, do: Sweet.Secret.get("telegram_bot_token", "TELEGRAM_BOT_TOKEN")
end
