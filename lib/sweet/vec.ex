defmodule Sweet.Vec do
  @moduledoc """
  Vectors: closeness and length. Neither state nor process — pure arithmetic.

  A separate module because two use this measure, ones not connected with each
  other by anything: the memory of a conversation and the skills. To keep the formula at one of
  them would mean that the second depends on it for the sake of arithmetic.
  """

  @doc """
  The cosine between vectors. Exactly the cosine, and not the dot product.

  We divide by the lengths deliberately, although today this changes nothing: in
  `multilingual-e5-small` in the sentence-transformers configuration there is a layer of
  normalization, the vectors come out unit ones, and the division gives the same number.

  Insurance in case of a change of model (`embed_model` in the config). The dot
  product equals `cosine × length of the candidate × length of the query`. The length of the
  query is a common factor, it does not affect the order; while the lengths of the candidates are
  different, and a long vector will overtake a closer but short one. In the selection this
  would look like "a long paragraph of memory displaced an exact description of a skill":
  neither an error, nor a warning, just slightly worse output — and try to guess.

  Formerly the normalization came out by itself, the centering ended with it.
  The centering was removed — the cover disappeared together with it.
  """
  def cosine(a, b), do: cosine(a, norm(a), b, norm(b))

  @doc """
  The same, but with ready lengths.

  The length of a vector never changes, therefore it is counted once — on writing
  a paragraph or a skill — and is stored next to it. Otherwise on every turn we would recount
  the length of the query anew for EVERY candidate, that is, do three times more
  work than needed: three passes over the vector instead of one.
  """
  def cosine(a, norm_a, b, norm_b) do
    case norm_a * norm_b do
      +0.0 -> 0.0
      product -> dot(a, b) / product
    end
  end

  @doc "The length of a vector."
  def norm(vector), do: :math.sqrt(dot(vector, vector))

  @doc """
  The dot product.

  A vector is a binary of f32, and not a list of float. The reason is shared memory: the search
  goes over the whole archive, and not over one session, and every day the candidates
  become more. A list of float costs dearly twice — for every number a
  list cell and a packed number (that is ~24 bytes instead of four), while
  `Enum.zip` besides creates a tuple for every pair. A binary is matched
  in place, without a single allocation of memory.

  The precision of f32 spoils nothing here: the embedder itself counts in float32, so
  double precision would store zeroes.
  """
  def dot(a, b) when is_binary(a) and is_binary(b), do: dot(a, b, 0.0)

  # The lists remained for the sake of skills whose vectors were counted by the old code, and for the sake of
  # direct calls from the tests: the arithmetic is the same, the price is different.
  def dot(a, b) when is_list(a) and is_list(b) do
    a |> Enum.zip(b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
  end

  defp dot(<<x::float-32-little, a::binary>>, <<y::float-32-little, b::binary>>, acc) do
    dot(a, b, acc + x * y)
  end

  defp dot(_a, _b, acc), do: acc

  @doc "A list of float from the embedder — into an f32 binary, as it is stored."
  def pack(vector) when is_list(vector) do
    for value <- vector, into: <<>>, do: <<value::float-32-little>>
  end

  def pack(vector) when is_binary(vector), do: vector
end
