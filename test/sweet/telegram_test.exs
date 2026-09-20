defmodule Sweet.TelegramTest do
  use ExUnit.Case, async: true

  # A formatted message arrives as a tree, and the inventory needs a readable
  # title, and not JSON. The tree can be of any shape — what matters is that the title
  # is assembled from its texts and is not longer than the caption of a button.
  test "the title is assembled from the texts of the tree" do
    tree = %{"blocks" => [%{"text" => "Hello"}, %{"text" => "world"}]}

    assert Sweet.Telegram.rich_title(tree) =~ "Hello"
    assert Sweet.Telegram.rich_title(tree) =~ "world"
  end

  test "the title is truncated to the length of the caption" do
    tree = %{"text" => String.duplicate("a", 500)}

    assert String.length(Sweet.Telegram.rich_title(tree)) <= 60
  end

  test "a tree without texts gives an empty title, and not a fall" do
    assert Sweet.Telegram.rich_title(%{"n" => 1}) == ""
  end

  # The translation of the markup of the model into what a rich message renders. This breaks
  # silently: Telegram answers `ok`, while formulas and tables arrive empty,
  # therefore we check here, and not with the eyes in the chat.
  describe "prepare/1" do
    test "the block ```latex becomes a display formula" do
      out = Sweet.Telegram.prepare("Here it is:\n\n```latex\ne^{i\\pi} + 1 = 0\n```\n")

      assert out =~ "$$e^{i\\pi} + 1 = 0$$"
      refute out =~ "```"
    end

    test "a block with code is not touched" do
      code = "```python\nx = 1\n```"

      assert Sweet.Telegram.prepare(code) == code
    end

    test "tabular becomes a markdown table" do
      latex = """
      \\begin{tabular}{ll}
      \\hline
      Symbol & What it means \\\\
      \\hline
      $e$ & the base \\\\
      $i$ & the imaginary unit \\\\
      \\hline
      \\end{tabular}
      """

      out = Sweet.Telegram.prepare(latex)

      assert out =~ "| Symbol | What it means |"
      assert out =~ "| --- | --- |"
      assert out =~ "| $e$ | the base |"
      refute out =~ "tabular"
      refute out =~ "hline"
    end

    test "the caption of a table remains a line above it" do
      latex = """
      \\begin{table}[h]
      \\centering
      \\caption{Five constants}
      \\begin{tabular}{ll}
      Symbol & Meaning \\\\
      $e$ & the base \\\\
      \\end{tabular}
      \\end{table}
      """

      out = Sweet.Telegram.prepare(latex)

      assert out =~ "*Five constants*"
      assert out =~ "| Symbol | Meaning |"
      refute out =~ "caption"
    end

    test "a table inside a ```latex block is translated too" do
      out =
        Sweet.Telegram.prepare(
          "```latex\n\\begin{tabular}{cc}\n1 & 2 \\\\\n3 & 4 \\\\\n\\end{tabular}\n```"
        )

      assert out =~ "| 1 | 2 |"
      assert out =~ "| 3 | 4 |"
      refute out =~ "```"
    end

    test "the align environment is assembled into aligned" do
      out = Sweet.Telegram.prepare("\\begin{align}\na &= b \\\\\nc &= d\n\\end{align}")

      assert out =~ "$$\\begin{aligned}"
      assert out =~ "\\end{aligned}$$"
    end

    test "a dollar before a digit is escaped as before" do
      assert Sweet.Telegram.prepare("it cost $50 per turn") =~ "\\$50"
    end

    test "ready mathematics in dollars is not spoiled" do
      assert Sweet.Telegram.prepare("here $e^{i\\pi}$ and that is all") =~ "$e^{i\\pi}$"
    end
  end

  describe "the language caption of code" do
    test "short code goes off as a block with the class of the language" do
      out = Sweet.Telegram.code_block("IO.puts 1", "elixir")

      assert out =~ "<pre><code class=\"language-elixir\">"
      assert out =~ "IO.puts 1"
    end

    test "long code goes off as a collapsed quote and the language is captioned by the first line" do
      code = Enum.map_join(1..80, "\n", &"line #{&1}")
      out = Sweet.Telegram.code_block(code, "bash")

      assert String.starts_with?(out, "<blockquote expandable><b>bash</b>\n")
      assert out =~ "line 80"
      refute out =~ "<pre>"
    end

    test "code in a quote is escaped as before" do
      code = Enum.map_join(1..80, "\n", fn _ -> "if a < b && c > d" end)
      out = Sweet.Telegram.code_block(code, "python")

      assert out =~ "&lt;"
      assert out =~ "&amp;"
      refute out =~ "a < b"
    end
  end
end
