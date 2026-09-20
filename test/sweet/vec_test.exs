defmodule Sweet.VecTest do
  use ExUnit.Case, async: true

  alias Sweet.Vec

  test "the cosine of a thing with itself is one" do
    v = [1.0, 2.0, 3.0]
    assert_in_delta Vec.cosine(v, v), 1.0, 1.0e-6
  end

  test "perpendicular vectors are zero" do
    assert_in_delta Vec.cosine([1.0, 0.0], [0.0, 1.0]), 0.0, 1.0e-6
  end

  test "opposite ones are minus one" do
    assert_in_delta Vec.cosine([1.0, 2.0], [-1.0, -2.0]), -1.0, 1.0e-6
  end

  test "a zero vector does not fall and does not divide by zero" do
    assert Vec.cosine([0.0, 0.0], [1.0, 1.0]) == 0.0
  end

  # The vectors are stored packed in a binary — on 3000 paragraphs this is a difference by
  # factors in memory. The packing must be lossless for the counting.
  test "a packed vector is counted the same way as a list" do
    a = [0.1, -0.2, 0.3, 0.4]
    b = [0.5, 0.6, -0.7, 0.8]

    assert_in_delta Vec.cosine(Vec.pack(a), Vec.pack(b)), Vec.cosine(a, b), 1.0e-5
  end

  test "packing an already packed one spoils nothing" do
    packed = Vec.pack([1.0, 2.0])
    assert Vec.pack(packed) == packed
  end

  test "the length is counted by Pythagoras" do
    assert_in_delta Vec.norm([3.0, 4.0]), 5.0, 1.0e-6
  end
end
