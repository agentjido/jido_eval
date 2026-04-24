defmodule Jido.Eval.ErrorTest do
  use ExUnit.Case, async: true

  alias Jido.Eval.Error

  describe "helpers" do
    test "builds validation errors" do
      error = Error.validation_error("invalid sample", %{field: :sample, value: nil})

      assert %Error.InvalidInputError{} = error
      assert error.message == "invalid sample"
      assert error.field == :sample
      assert error.value == nil
    end

    test "builds config errors" do
      error = Error.config_error("bad config", %{field: :judge_model, value: :bad})

      assert %Error.ConfigError{} = error
      assert error.message == "bad config"
      assert error.field == :judge_model
      assert error.value == :bad
    end

    test "builds execution errors" do
      error = Error.execution_error("judge failed", %{provider: :openai})

      assert %Error.ExecutionFailureError{} = error
      assert error.message == "judge failed"
      assert error.details == %{provider: :openai}
    end
  end
end
