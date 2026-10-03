defmodule Sweet.FilesTest do
  use ExUnit.Case, async: true

  alias Sweet.Files

  # The name comes from Telegram, that is, from outside. A path in it is a record into the wrong
  # place than we think; we check that nothing remains of the directories.
  test "a path is cut out of the name" do
    refute Files.safe_name("../../etc/passwd") =~ "/"
    refute Files.safe_name("/etc/passwd") =~ "/"
  end

  test "an empty name does not remain empty" do
    assert Files.safe_name(nil) == "file"
    assert Files.safe_name("") != ""
  end

  test "an ordinary name is not crippled" do
    assert Files.safe_name("report 2026.xlsx") =~ "2026"
  end

  test "pictures differ from other files" do
    assert Files.image?("/tmp/a.JPG")
    assert Files.image?("/tmp/a.png")
    refute Files.image?("/tmp/a.xlsx")
  end

  # A gif is shown in the chat as a picture, but the model must be given it as a picture too:
  # an animation sent as a still frame loses the very thing it was sent for.
  test "a media type is given only to what the API accepts" do
    assert Files.media_type("/tmp/a.jpg") == "image/jpeg"
    assert Files.media_type("/tmp/a.JPEG") == "image/jpeg"
    assert Files.media_type("/tmp/a.gif") == "image/gif"
    assert Files.media_type("/tmp/a.webp") == "image/webp"
    assert Files.media_type("/tmp/a.pdf") == nil
    refute Files.picture?("/tmp/a.pdf")
  end

  # The picture travels to the model as BYTES: the path in the text does not put it there, the model
  # does not open files. The type of the picture goes into the block itself — the API demands it.
  test "a picture is assembled into a block with base64 inside" do
    path = Path.join(System.tmp_dir!(), "sweet-block-#{System.unique_integer([:positive])}.png")
    File.write!(path, <<137, 80, 78, 71, 1, 2, 3>>)
    on_exit(fn -> File.rm(path) end)

    assert %{"type" => "image", "source" => source} = Files.image_block(path)
    assert source["type"] == "base64"
    assert source["media_type"] == "image/png"
    assert Base.decode64!(source["data"]) == <<137, 80, 78, 71, 1, 2, 3>>
  end

  # A file that is not a picture has no block at all: the agent will open it with its tools.
  # To send a pdf as an `image` block would mean to get a 400 from the API on every such message.
  test "a file that is not a picture gives no block" do
    path = Path.join(System.tmp_dir!(), "sweet-block-#{System.unique_integer([:positive])}.pdf")
    File.write!(path, "%PDF-1.4")
    on_exit(fn -> File.rm(path) end)

    assert Files.image_block(path) == nil
  end

  # The API refuses a picture heavier than 10 MB in base64. The refusal is at the session's door
  # and would break the whole turn; the file itself remains in inbox anyway.
  test "a picture too heavy for the API gives no block" do
    path = Path.join(System.tmp_dir!(), "sweet-block-#{System.unique_integer([:positive])}.png")
    File.write!(path, :binary.copy(<<1>>, 7_000_001))
    on_exit(fn -> File.rm(path) end)

    assert Files.image_block(path) == nil
  end
end
