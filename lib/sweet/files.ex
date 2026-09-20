defmodule Sweet.Files do
  @moduledoc """
  The exchange of files with the person through two folders in the working directory of the agent.

      exchange/inbox/    brain puts here what was sent into the chat
      exchange/outbox/   brain takes from here and sends into the chat

  The folders lie inside `/workspace`, that is, they are visible both to the hand and to brain: the hand writes there
  the result with an ordinary `open(...)`, no special tool is needed for this.
  "Put a file into a folder" is simpler to explain to the model than a call schema.

  We remember what has already been sent by a timestamp, and not by moving to an archive: the file
  remains lying where it was put, and the agent can append to it later.
  The mark lives in `priv/`, therefore it survives a restart.

  We take it AFTER the end of the turn: by that moment everything the agent wrote is already
  appended and closed, and there is no reason to build a check "the file has stopped changing".
  """

  require Logger

  @image_exts ~w(.png .jpg .jpeg .webp)
  # The Telegram limit for bots.
  @max_bytes 50 * 1024 * 1024
  # So that one turn does not arrange an avalanche of a hundred files.
  @max_per_turn 10

  # Both folders under a common `exchange/`, and not right in the root of the working directory:
  # that way one can see that this is one device of exchange, and not two random folders.
  def inbox, do: Path.join(root(), "exchange/inbox")
  def outbox, do: Path.join(root(), "exchange/outbox")

  @doc """
  Create the exchange folders and open them for writing to both sides.

  The chmod here is mandatory, and not for new folders. They are created by brain, and it
  works as root; the hand, however, lives under uid 1000, and into a folder with the usual mode
  755 it cannot write — the agent ran into "read-only" and put the files wherever
  it pleased, past the sending. We set the rights on every start, and not only on
  creation: mkdir_p on an existing folder silently changes nothing, and folders already
  created by root would have remained closed.

  777 is not scary here: these are two folders inside the working directory of the agent, both
  sides are its own containers, and nothing sensitive lies in them.
  """
  def ensure do
    for dir <- [inbox(), outbox()] do
      File.mkdir_p!(dir)
      File.chmod(dir, 0o777)
    end
  end

  @doc """
  The files from outbox that appeared after the previous sending.

  It returns `{files, new_mark}` — the mark is saved by the caller, and
  only if the sending succeeded. Otherwise a file that fell during the sending would be
  lost forever.
  """
  def pending do
    ensure()
    mark = mark()

    files =
      outbox()
      |> File.ls!()
      |> Enum.map(&Path.join(outbox(), &1))
      |> Enum.filter(&suitable?(&1, mark))
      |> Enum.sort_by(&mtime/1)

    {Enum.take(files, @max_per_turn), length(files) - @max_per_turn}
  end

  @doc "Remember that everything up to this moment has already been sent."
  def mark(files) do
    files
    |> Enum.map(&mtime/1)
    |> Enum.max(fn -> mark() end)
    |> then(&File.write!(mark_path(), to_string(&1)))
  end

  @doc "Telegram shows a picture in the chat, gives the rest as a file."
  def image?(path), do: Path.extname(path) |> String.downcase() |> then(&(&1 in @image_exts))

  @doc """
  A safe name for a sent file.

  The name comes from Telegram, that is, from the person, while we put it into the working
  folder of the agent. Without cleaning, `../../` in the name would lead the file beyond inbox.
  """
  def safe_name(nil), do: "file"

  def safe_name(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^\w.\-]/u, "_")
    |> case do
      "" -> "file"
      safe -> safe
    end
  end

  defp suitable?(path, mark) do
    case File.stat(path, time: :posix) do
      {:ok, %{type: :regular, size: size, mtime: mtime}} ->
        mtime > mark and size > 0 and size <= @max_bytes

      _ ->
        false
    end
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> 0
    end
  end

  defp mark do
    case File.read(mark_path()) do
      {:ok, text} -> text |> String.trim() |> String.to_integer()
      {:error, _} -> 0
    end
  rescue
    # The mark is spoiled — we consider that nothing was sent. An extra
    # sending is annoying, a lost file is worse.
    ArgumentError -> 0
  end

  defp mark_path, do: Path.join(Path.dirname(Application.fetch_env!(:sweet, :recall_dir)), "outbox.mark")

  defp root, do: Application.fetch_env!(:sweet, :workspace_guest_path)
end
