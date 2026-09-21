defmodule Sweet.LLM do
  @moduledoc """
  A client of the Anthropic Messages API on top of Finch.

  The key is read at runtime from `/run/secrets` (see `Sweet.Secret`) and lives only
  in the brain. It is never passed to the hand — the hand has no network outward at all
  (`internal`).

  Two modes: `complete/2` (wait for the answer whole) and `stream/3` (in pieces,
  with a callback for every fragment of text). Both return one and the same —
  `%{content:, stop_reason:, usage:}`, therefore the caller does not care by which
  path the answer arrived.
  """

  require Logger

  @version "2023-06-01"

  defp endpoint, do: Application.fetch_env!(:sweet, :api_base) <> "/v1/messages"

  def complete(messages, opts \\ []) do
    request = build(messages, opts, false)

    timed("complete", fn ->
      retrying(fn ->
        case Finch.request(request, Sweet.Finch, receive_timeout: 600_000) do
          {:ok, %{status: 200, body: body}} ->
            resp = JSON.decode!(body)

            {:ok,
             %{
               stop_reason: resp["stop_reason"],
               content: resp["content"],
               usage: usage(resp["usage"])
             }}

          {:ok, %{status: status, body: body}} ->
            {:error, {:api_error, status, body}}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end)
  end

  @doc """
  The same, but as a stream. `on_delta` is called on every piece of text —
  so that the person sees the answer at once, and not after half a minute.

  One can retry a stream only while nothing has been given outward: if the subscriber
  has already seen half the answer, a repeat will show it twice. Therefore an attempt that
  has managed to give out at least one piece is considered final.

  `:on_notice` — where to tell the person that the stream has fallen silent. Not obligatory:
  without it the silence is visible only in the log.
  """
  def stream(messages, on_delta, opts \\ []) do
    request = build(messages, opts, true)
    on_notice = Keyword.get(opts, :on_notice, fn _text -> :ok end)

    timed("stream", fn ->
      attempts(request, on_delta, on_notice, Application.fetch_env!(:sweet, :api_attempts), 1)
    end)
  end

  # Its own loop of attempts, and not the common `retrying/2`: here a repeat has a condition
  # that exists nowhere else — whether a piece of the answer has managed to travel to the person.
  # To repeat after that is impossible: it would see the beginning of one answer and
  # another whole. Formerly the process dictionary was asked about this; now the sign
  # is returned together with the error, as is proper for it.
  defp attempts(request, on_delta, on_notice, limit, attempt) do
    case attempt_stream(request, on_delta, on_notice) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason, delivered} ->
        if attempt < limit and worth_retrying?(reason) and not delivered do
          Logger.warning(
            "llm: attempt #{attempt} of #{limit} failed — #{inspect(reason)}, repeating"
          )

          Process.sleep(Application.fetch_env!(:sweet, :api_retry_delay_ms) * attempt)
          attempts(request, on_delta, on_notice, limit, attempt + 1)
        else
          {:error, reason}
        end
    end
  end

  # The call of the model is the longest place of a turn and until now the most mute: not
  # a line about the fact that the request went off, how long it lasted and how it ended.
  # A turn hung inside it looked from outside like complete silence: neither
  # an answer, nor an error, nor a trace in the log — and one had to sort it out by guessing.
  #
  # The timeout of a whole answer here is 10 minutes, the attempts three. The stream lives by other
  # clocks: there we wait not for the answer whole, but for the next piece (`api_idle_timeout_ms`),
  # and a request that has fallen silent forever is broken off on it, and not after half an hour.
  defp timed(kind, fun) do
    started = System.monotonic_time(:millisecond)
    Logger.info("llm #{kind}: the request has gone off")
    result = fun.()
    elapsed = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, %{usage: usage, stop_reason: stop}} ->
        Logger.info(
          "llm #{kind}: answer in #{elapsed} ms, stop=#{stop}, " <>
            "input #{Map.get(usage, :input, 0)}, output #{Map.get(usage, :output, 0)}"
        )

      {:error, reason} ->
        Logger.warning("llm #{kind}: error in #{elapsed} ms — #{inspect(reason)}")
    end

    result
  end

  # The state of the parsing travels as the accumulator of the stream, and not as the process dictionary.
  # Formerly the buffer and the blocks lay in Process.put: the parsing functions depended on
  # something that is not in their signature, and one could see what had accumulated there
  # only from inside that same process. Finch carries the accumulator through all
  # the pieces anyway — the state has its place in it.
  #
  # There is one exception, and it is below: the sign “a piece has already gone off”. It is obliged to
  # survive a break of the stream, while the accumulator does not survive a break.
  defp attempt_stream(request, on_delta, on_notice) do
    watch = start_watch(on_notice)
    empty = %{buffer: "", blocks: %{}, stop_reason: nil, usage: %{}}

    # The sign “a piece of the answer has already gone to the person” lives OUTSIDE the accumulator of the stream.
    # Formerly it lay in the accumulator, and this made it useless exactly where
    # it is needed: on a break of the connection `Finch.stream/5` does not give the accumulator
    # at all, the error came with `delivered: false`, the request was repeated —
    # and the person saw the beginning of one answer and another whole. That is, exactly what
    # the sign was started for.
    #
    # `:counters`, and not a process dictionary: the counter is passed explicitly, is visible in
    # the signatures and is read after the stream has already collapsed.
    delivered = :counters.new(1, [])

    on_delta = fn text ->
      :counters.add(delivered, 1, 1)
      on_delta.(text)
    end

    collect = fn
      {:status, status}, acc ->
        Map.put(acc, :status, status)

      {:headers, _headers}, acc ->
        acc

      {:data, data}, acc ->
        send(watch, :alive)
        %{acc | sse: feed(acc.sse, data, on_delta)}

      # A kind of message that we did not expect (HTTP/2 trailers, for example).
      # Without this clause it would be a `FunctionClauseError` inside the stream, that is,
      # the death of the turn for no reason at all; there is nothing for us to parse in it.
      _other, acc ->
        acc
    end

    result =
      try do
        case Finch.stream(request, Sweet.Finch, %{status: nil, sse: empty}, collect,
               receive_timeout: Application.fetch_env!(:sweet, :api_idle_timeout_ms)
             ) do
          {:ok, %{status: 200, sse: sse}} ->
            content = sse.blocks |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&finalize(elem(&1, 1)))

            # What the answer consisted of. Without this line “the model is silent” and “its
            # words were lost at our side” look the same: in the log one sees only the
            # number of tokens on the output, and what they are occupied with — no.
            Logger.info("llm stream: blocks #{blocks_line(content)}")

            {:ok, %{stop_reason: sse.stop_reason, content: content, usage: sse.usage}}

          # We give the error together with the sign: whether at least a piece of the answer has managed
          # travel to the person. On this depends whether one may repeat.
          {:ok, %{status: status}} ->
            {:error, {:api_error, status, nil}, delivered?(delivered)}

          # A break in the middle of the stream. Finch gives the accumulator back together with
          # the error (it has done so since 0.20), but the sign is read from our counter, and not
          # from it: the counter lived through the break, and the accumulator may have died with
          # the stream. Part of the answer could already have gone off.
          {:error, reason, _acc} ->
            {:error, reason, delivered?(delivered)}
        end
      after
        send(watch, :stop)
      end

    result
  end

  defp delivered?(counter), do: :counters.get(counter, 1) > 0

  # The watchdog of silence. A request that went into nowhere until now looked the same
  # as a working one: “typing…” in the chat, not a line in the log. The watchdog counts the time
  # since the last piece and speaks aloud — into the log every half a minute, to the person
  # once, when the pause has become indecent.
  #
  # It lives under `Sweet.Tasks`, and not beside the tree: it was the last process
  # about which the supervisor did not know — there was nowhere to count the watchdogs and
  # no one to put them out on a stop.
  #
  # The link is left deliberately: a broken-off turn is obliged to carry the watchdog with it,
  # otherwise it counts the silence of a request that no longer exists. By the same it is
  # put out if the stream ended earlier (`send(watch, :stop)`).
  defp start_watch(on_notice) do
    {:ok, pid} =
      Task.Supervisor.start_child(Sweet.Tasks, fn -> watch(on_notice, 0) end, restart: :temporary)

    Process.link(pid)
    pid
  end

  defp watch(on_notice, silent_ms) do
    heartbeat = Application.fetch_env!(:sweet, :api_heartbeat_ms)
    notice_after = Application.fetch_env!(:sweet, :api_notice_after_ms)

    receive do
      :alive -> watch(on_notice, 0)
      :stop -> :ok
    after
      heartbeat ->
        silent_ms = silent_ms + heartbeat
        seconds = div(silent_ms, 1000)
        Logger.info("llm stream: silent for #{seconds} s")

        # Exactly once per pause: on the next round the threshold is already behind, but
        # `silent_ms - heartbeat` has not yet overstepped it.
        if silent_ms >= notice_after and silent_ms - heartbeat < notice_after do
          on_notice.("the model is silent for #{seconds} s — waiting for an answer")
        end

        watch(on_notice, silent_ms)
    end
  end

  # --- Retries ---

  # Without frills: we count attempts, wait between them, give up. We repeat
  # only network failures and 429/5xx — on a 400 a repeat is pointless, the answer will not
  # change.
  defp retrying(fun, retryable? \\ fn -> true end) do
    attempts = Application.fetch_env!(:sweet, :api_attempts)
    do_retry(fun, retryable?, attempts, 1)
  end

  defp do_retry(fun, retryable?, attempts, attempt) do
    case fun.() do
      {:error, reason} when attempt < attempts ->
        if worth_retrying?(reason) and retryable?.() do
          Logger.warning(
            "llm: attempt #{attempt} of #{attempts} failed — #{inspect(reason)}, repeating"
          )

          Process.sleep(Application.fetch_env!(:sweet, :api_retry_delay_ms) * attempt)
          do_retry(fun, retryable?, attempts, attempt + 1)
        else
          {:error, reason}
        end

      result ->
        result
    end
  end

  defp worth_retrying?({:api_error, status, _body}), do: status == 429 or status >= 500
  defp worth_retrying?(_transport_error), do: true

  # --- Parsing SSE ---

  # The frames are separated by an empty line, but they come cut up anyhow,
  # therefore an unfinished tail remains in the buffer until the next piece.
  defp feed(sse, data, on_delta) do
    {events, rest} = split_events(sse.buffer <> data)

    Enum.reduce(events, %{sse | buffer: rest}, fn event, acc ->
      case JSON.decode(event) do
        {:ok, decoded} -> apply_event(decoded, acc, on_delta)
        {:error, _} -> acc
      end
    end)
  end

  defp split_events(buffer) do
    parts = String.split(buffer, "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)

    payloads =
      complete
      |> Enum.flat_map(&String.split(&1, "\n"))
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(&String.replace_prefix(&1, "data: ", ""))

    {payloads, rest}
  end

  defp apply_event(%{"type" => "message_start", "message" => message}, sse, _on_delta) do
    %{sse | usage: usage(message["usage"])}
  end

  defp apply_event(%{"type" => "content_block_start", "index" => i, "content_block" => block}, sse, _) do
    %{sse | blocks: Map.put(sse.blocks, i, {block, ""})}
  end

  defp apply_event(%{"type" => "content_block_delta", "index" => i, "delta" => delta}, sse, on_delta) do
    case delta do
      %{"type" => "text_delta", "text" => text} ->
        on_delta.(text)
        append(sse, i, text)

      # The arguments of a tool arrive in pieces of JSON — we do not show them,
      # we only accumulate until content_block_stop.
      %{"type" => "input_json_delta", "partial_json" => chunk} ->
        append(sse, i, chunk)

      # The reasoning of the model. We accumulate it on a par with the text, but do not
      # give it into the stream to the person: `on_delta` is the answer, while this does not yet relate to the answer.
      # Formerly such pieces fell into `_ ->` and were lost silently, and together
      # with them — everything the model says when taking up the tools: in models with
      # reasoning there is no text block next to the call at all.
      %{"type" => "thinking_delta", "thinking" => chunk} ->
        append(sse, i, chunk)

      %{"type" => "reasoning_delta", "reasoning" => chunk} ->
        append(sse, i, chunk)

      _ ->
        sse
    end
  end

  defp apply_event(%{"type" => "message_delta"} = event, sse, _on_delta) do
    %{
      sse
      | stop_reason: get_in(event, ["delta", "stop_reason"]) || sse.stop_reason,
        usage: Map.merge(sse.usage, usage(event["usage"]))
    }
  end

  defp apply_event(_event, sse, _on_delta), do: sse

  defp append(sse, index, chunk) do
    %{sse | blocks: Map.update!(sse.blocks, index, fn {block, acc} -> {block, acc <> chunk} end)}
  end

  # We bring the accumulated block to the same form in which complete/2 gives it.
  defp finalize({%{"type" => "text"} = block, acc}), do: Map.put(block, "text", acc)

  defp finalize({%{"type" => "thinking"} = block, acc}), do: Map.put(block, "thinking", acc)

  defp finalize({%{"type" => "reasoning"} = block, acc}), do: Map.put(block, "reasoning", acc)

  defp finalize({%{"type" => "tool_use"} = block, acc}) do
    input =
      case JSON.decode(acc) do
        {:ok, decoded} when is_map(decoded) -> decoded
        _ -> %{}
      end

    Map.put(block, "input", input)
  end

  defp finalize({block, _acc}), do: block

  # The composition of the answer in one line: the type of the block and how many characters are in it.
  defp blocks_line(content) do
    Enum.map_join(content, ", ", fn block ->
      size =
        block
        |> Map.take(["text", "thinking", "reasoning"])
        |> Map.values()
        |> Enum.map(&String.length/1)
        |> Enum.sum()

      "#{block["type"]}(#{size})"
    end)
  end

  # --- Common ---

  defp build(messages, opts, stream?) do
    body =
      %{
        model: Keyword.get(opts, :model, Application.fetch_env!(:sweet, :model)),
        max_tokens: Keyword.get(opts, :max_tokens, Application.fetch_env!(:sweet, :max_tokens)),
        temperature: 0,
        system: Keyword.get(opts, :system, ""),
        tools: Keyword.get(opts, :tools, Sweet.Harness.Prompt.tools()),
        messages: messages
      }
      |> then(fn body -> if stream?, do: Map.put(body, :stream, true), else: body end)

    Finch.build(:post, endpoint(), headers(), JSON.encode!(body))
  end

  defp usage(nil), do: %{}

  defp usage(usage) do
    %{
      input: usage["input_tokens"],
      output: usage["output_tokens"],
      cache_read: usage["cache_read_input_tokens"],
      # A cache write is billed as a cache miss, and not for free — without it
      # the usage would be counted as understated.
      cache_write: usage["cache_creation_input_tokens"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp headers do
    [
      {"x-api-key", api_key()},
      {"anthropic-version", @version},
      {"content-type", "application/json"}
    ]
  end

  defp api_key do
    Sweet.Secret.get("anthropic_api_key", "ANTHROPIC_API_KEY") ||
      raise "the model key is not set: there is neither /run/secrets/anthropic_api_key nor ANTHROPIC_API_KEY"
  end
end
