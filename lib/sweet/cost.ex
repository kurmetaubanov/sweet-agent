defmodule Sweet.Cost do
  @moduledoc """
  What a turn cost.

  We count ourselves, and not out of a good life: DeepSeek does not give out the cost — in
  `usage` only tokens arrive (checked by a request to the gateway, both ordinary and
  streaming). The tokens at the same time are reliable, they are from the provider; only the arithmetic
  here is invented.

  The tariff depends on the moment: peak hours are twice as expensive, but only on weekdays —
  weekends go entirely by the cheap tariff. Therefore the price of a turn is a function of
  the moment when the turn happened, and not a constant.
  """

  @doc """
  The cost in dollars by the token counter.

  `at` — the moment by which the tariff is chosen; by default now. UTC is taken,
  because the peak hours of the provider are set in UTC — both the hours and the days of the week.
  """
  def of(usage, at \\ DateTime.utc_now()) do
    price = price(at)

    # The input is divided into two parts with a different price: what was read from the cache,
    # and everything else. Writing to the cache goes at the price of a miss — it has no
    # separate tariff.
    miss = get(usage, :input) + get(usage, :cache_write)
    hit = get(usage, :cache_read)
    out = get(usage, :output)

    (miss * price.cache_miss + hit * price.cache_hit + out * price.output) / 1_000_000
  end

  @doc "The tariff for a given moment: peak or not peak."
  def price(at \\ DateTime.utc_now()) do
    # Saturday and Sunday do not know peak hours: on weekends the tariff is cheap
    # around the clock.
    weekday? = Date.day_of_week(at) <= 5

    if weekday? and at.hour in Application.fetch_env!(:sweet, :price_peak_hours_utc) do
      Application.fetch_env!(:sweet, :price_peak)
    else
      Application.fetch_env!(:sweet, :price_off_peak)
    end
  end

  @doc """
  The usage line for the chat: how long the turn went, the tokens and the money for the turn, plus
  what has accumulated for the session.

  `elapsed_ms` — the clock of the turn. It is counted by the session, and not by the task of the turn: the start of the turn and
  the receipt of its result are its business, the task knows nothing about these two moments.

  We show the tokens not for the sake of beauty: the price of input and output differs threefold, and
  from one sum it is unclear why the turn cost so much.
  """
  def report(turn, session, elapsed_ms) do
    "⏱ #{duration(elapsed_ms)} · input #{n(get(turn, :input))} / output #{n(get(turn, :output))}" <>
      cache_part(turn) <>
      " — $#{money(of(turn))} per turn, $#{money(of(session))} per session"
  end

  # How long the turn went. The time is here from the first digit of the line: the clock is what the turn
  # is measured with, and the place is next to them.
  #
  # One unit for any duration — the millisecond. The former three steps
  # (fractions of a second, seconds, minutes) read differently on different turns: in
  # "5.0 s" the fraction was always there, although it meant nothing, and at the boundary of 9 999 ms
  # the line managed to show "10.0 s" before becoming "10 s". The digits are
  # separated by a space with the same `n/1` as the tokens: "129 000 ms" is readable, and
  # it is simpler to compare turns with each other on one scale.
  defp duration(ms), do: "#{n(ms)} ms"

  defp cache_part(usage) do
    case {get(usage, :cache_read), get(usage, :cache_write)} do
      {0, 0} -> ""
      {read, 0} -> " / from the cache #{n(read)}"
      {0, write} -> " / to the cache #{n(write)}"
      {read, write} -> " / cache #{n(read)}↓ #{n(write)}↑"
    end
  end

  defp get(usage, key), do: Map.get(usage, key) || 0

  # Four digits: a turn cheaper than a cent — the usual two would give "$0.00" on everything.
  defp money(amount), do: :erlang.float_to_binary(amount * 1.0, decimals: 4)

  # The digits with spaces: 12400 reads worse than 12 400.
  defp n(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1 ")
    |> String.reverse()
  end
end
