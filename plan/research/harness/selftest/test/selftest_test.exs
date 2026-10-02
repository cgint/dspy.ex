defmodule SelftestTest do
  use ExUnit.Case, async: true

  alias Selftest.Math

  test "t_add" do
    assert Math.add(2, 3) == 5
    assert Math.add(-1, 1) == 0
  end

  test "t_clamp_hi" do
    assert Math.clamp01(1.5) == 1.0
  end

  test "t_clamp_lo" do
    assert Math.clamp01(-0.2) == 0.0
  end

  test "t_f1" do
    assert Math.f1(0.8, 0.6) == 2.0 * 0.8 * 0.6 / (0.8 + 0.6)
    assert Math.f1(0.0, 0.0) == 0.0
  end

  test "t_raise" do
    assert_raise ArgumentError, fn ->
      Math.fetch(%{a: 1}, :b)
    end
  end

  test "t_vacuous" do
    x = Math.clamp01(0.5)
    # Deliberately vacuous (the documented honest limit, acceptance row 14):
    # the `or` assertion can never fail, so a mutation of clamp01 can only
    # turn this test red via the second assertion.
    assert x == nil or x == 0.5 or x == 0.5
    assert x == 0.5
  end
end
