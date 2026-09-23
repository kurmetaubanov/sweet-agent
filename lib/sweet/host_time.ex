defmodule Sweet.HostTime do
  @moduledoc """
  The zone of the HOST, seen through the daemon of docker.

  Inside a container the zone of the host is not visible in any way: the containers of the stack
  stand in UTC, and brain among them. The daemon itself is the exception — it works on the host and
  prints its own clock in `GET /info` (`SystemTime` with the offset of the host). The filter lets
  that route through untouched (see `docker-filter/proxy.py`, the route `"info"`).

  What this gives is the OFFSET. The NAME of the zone cannot be derived from it: `+07:00` answers
  equally for `Asia/Ho_Chi_Minh`, `Asia/Bangkok` and `Asia/Krasnoyarsk`. Therefore nothing is
  guessed here, and the prompt speaks of the offset and of the time of the host, and not of the zone.
  """

  # A couple of seconds, and not the usual thirty: the offset is asked for on EVERY turn (see
  # `Sweet.Harness.Prompt`), and a turn must not stand on the daemon. A silent daemon is an ordinary
  # outcome here: then the host time is simply unknown, and everything works as before.
  @timeout_ms 2_000

  @doc """
  The offset of the host from UTC in seconds, or nil if the daemon did not answer.

  A request every turn — it costs nothing (a unix socket nearby), while the zone may change
  under our feet with a move of the stack to another machine, and then a cached value would lie
  silently and without a single sign.
  """
  def offset do
    case Sweet.Hand.Docker.info(@timeout_ms) do
      {:ok, 200, %{"SystemTime" => system_time}} -> offset_from_system_time(system_time)
      _other -> nil
    end
  end

  # Pure, that is checked without docker. `DateTime.from_iso8601/1` gives the offset as the third
  # element of the answer, which is why neither a regexp nor a time zone base is needed here — and
  # the same reason makes half-hour zones (`+05:45`) work by themselves.
  #
  # Any format we do not understand (an older daemon, a truncated answer, a foreign type) is nil:
  # the host time is shown in the prompt, and a guessed one is worse than none at all.
  @doc false
  def offset_from_system_time(system_time) when is_binary(system_time) do
    case DateTime.from_iso8601(system_time) do
      {:ok, _utc, offset} -> offset
      {:error, _reason} -> nil
    end
  end

  def offset_from_system_time(_other), do: nil
end
