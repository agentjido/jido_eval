defmodule Jido.Eval.Metrics.Agent.ToolUseCorrectnessTest do
  use ExUnit.Case, async: true

  alias Jido.Eval.Config
  alias Jido.Eval.Metrics.Agent.ToolUseCorrectness
  alias Jido.Eval.Sample.{AgentTrace, SingleTurn}

  describe "metadata" do
    test "declares agent trace support" do
      assert ToolUseCorrectness.name() == "Agent Tool Use Correctness"
      assert ToolUseCorrectness.required_fields() == [:task, :trace]
      assert ToolUseCorrectness.sample_types() == [:agent_trace]
      assert ToolUseCorrectness.score_range() == {0.0, 1.0}
    end
  end

  describe "evaluate/3" do
    test "scores perfect tool usage" do
      sample =
        agent_trace(%{
          required_tools: ["lookup_order", "issue_refund"],
          tool_order: ["lookup_order", "issue_refund"],
          forbidden_tools: ["cancel_order"],
          max_tool_calls: 2
        })

      assert {:ok, result} = ToolUseCorrectness.evaluate(sample, %Config{}, [])
      assert result.score == 1.0
      assert result.metadata.deterministic == true
      assert Enum.all?(result.details.checks, & &1.passed)
    end

    test "records partial failures in check details" do
      sample =
        agent_trace(%{
          required_tools: ["lookup_order", "issue_refund", "notify_customer"],
          tool_order: ["issue_refund", "lookup_order"],
          forbidden_tools: ["issue_refund"],
          max_tool_calls: 1
        })

      assert {:ok, result} = ToolUseCorrectness.evaluate(sample, %Config{}, [])

      assert result.score == 0.0
      refute Enum.any?(result.details.checks, & &1.passed)
      assert Enum.find(result.details.checks, &(&1.name == :required_tools)).missing == ["notify_customer"]
    end

    test "passes when no expectations are supplied" do
      sample =
        AgentTrace.new!(%{
          task: "Resolve refund",
          trace: [%{type: "tool_call", name: "lookup_order", status: "ok"}]
        })

      assert {:ok, result} = ToolUseCorrectness.evaluate(sample, %Config{}, [])
      assert result.score == 1.0

      assert Enum.map(result.details.checks, & &1.name) == [
               :required_tools,
               :forbidden_tools,
               :tool_order,
               :max_tool_calls
             ]
    end

    test "ignores invalid max tool call expectations" do
      sample = agent_trace(%{max_tool_calls: "two"})

      assert {:ok, result} = ToolUseCorrectness.evaluate(sample, %Config{}, [])
      assert Enum.find(result.details.checks, &(&1.name == :max_tool_calls)).ignored == :invalid_expectation
    end

    test "rejects non-agent samples" do
      assert {:error, {:invalid_sample_type, :single_turn}} =
               ToolUseCorrectness.evaluate(%SingleTurn{response: "ok"}, %Config{}, [])
    end
  end

  defp agent_trace(expectations) do
    AgentTrace.new!(%{
      task: "Resolve refund",
      trace: [
        %{type: "tool_call", name: "lookup_order", status: "ok"},
        %{type: "tool_call", name: "issue_refund", status: "ok"}
      ],
      expectations: expectations
    })
  end
end
