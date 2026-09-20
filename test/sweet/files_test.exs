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
end
