defmodule JidoEvalTest do
  use ExUnit.Case
  doctest JidoEval

  test "greets the world" do
    assert JidoEval.hello() == :world
  end
end
