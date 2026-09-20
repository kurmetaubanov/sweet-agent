defmodule Sweet do
  @moduledoc """
  The IEx front end. For now all user input is from here.

      iex> {:ok, s} = Sweet.start()
      iex> Sweet.ask(s, "count the sha256 of the files in /workspace")
      iex> Sweet.usage(s)
      iex> Sweet.stop(s)

  A long turn is interrupted from another IEx session: `Sweet.cancel(s)`.
  """

  @doc """
  Bring up a session. The hand will appear at the first execution of code.

  If a session with such an id is already alive, IT is returned, and not a second one with the same
  name: `start_link` of a session registers it in the registry under `session:<id>`,
  and OTP answers `{:error, {:already_started, pid}}`. Formerly a duplicate silently
  came up nameless, the person talked to it, while the events of background jobs
  went by name to the first session — the postponed result did not reach the
  conversation at all.
  """
  def start(opts \\ []) do
    case DynamicSupervisor.start_child(Sweet.SessionSupervisor, {Sweet.Session, opts}) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc """
  Ask a question and print the answer as it is generated.

  It blocks the caller until the end of the turn, but the session itself is free at the same time —
  therefore `Sweet.cancel/1` from a neighbouring IEx works.
  """
  def ask(session, text) do
    Sweet.Session.ask_async(session, text)
    await()
  end

  @doc "Interrupt the current turn together with the code being executed."
  def cancel(session), do: Sweet.Session.cancel(session)

  @doc "The tokens spent per session."
  def usage(session), do: Sweet.Session.usage(session)

  @doc "Finish a session and kill its hand."
  def stop(session) do
    DynamicSupervisor.terminate_child(Sweet.SessionSupervisor, session)
  end

  @doc "The list of live sessions."
  def sessions, do: DynamicSupervisor.which_children(Sweet.SessionSupervisor)

  defp await do
    receive do
      # The console has no need to know the beginning of a turn: it itself began it.
      {:sweet_turn, _session, _question} ->
        await()

      {:sweet_delta, _session, text} ->
        IO.write(text)
        await()

      {:sweet_tool, _session, code, lang} ->
        IO.write("\n\e[2m» #{lang}\n#{code}\e[0m\n")
        await()

      {:sweet_notice, _session, text} ->
        IO.write("\n\e[2m#{text}\e[0m\n")
        await()

      {:sweet_aside, _session, text} ->
        IO.write("\n\e[2m#{text}\e[0m\n")
        await()

      {:sweet_done, _session, result} ->
        IO.write("\n")
        result
    end
  end
end
