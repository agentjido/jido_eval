defmodule Jido.Eval.Integration.AgentTraceEvalTest do
  use ExUnit.Case, async: false

  alias Jido.Eval.Dataset.InMemory
  alias Jido.Eval.Sample.AgentTrace

  @moduletag :capture_log

  setup do
    previous_llm_stub = Application.get_env(:jido_eval, :llm_stub)

    Application.put_env(:jido_eval, :llm_stub, fn
      :object, _model, prompt, _schema, _opts ->
        assert String.contains?(prompt, "Compact trace view")
        {:ok, %{success: true, score: 0.95, reasoning: "The trace completed the expected refund.", failure_modes: []}}
    end)

    on_exit(fn ->
      if previous_llm_stub do
        Application.put_env(:jido_eval, :llm_stub, previous_llm_stub)
      else
        Application.delete_env(:jido_eval, :llm_stub)
      end
    end)
  end

  test "evaluates agent traces with deterministic and judge metrics" do
    {:ok, dataset} =
      InMemory.new([
        AgentTrace.new!(%{
          id: "refund_success",
          task: "Resolve a customer refund request",
          expected_outcome: %{refunded: true},
          final_response: "I verified the order and issued the refund.",
          trace: [
            %{type: "tool_call", name: "lookup_order", output: %{eligible: true}},
            %{type: "tool_call", name: "issue_refund", output: %{refund_id: "ref_123"}}
          ],
          expectations: %{
            required_tools: ["lookup_order", "issue_refund"],
            tool_order: ["lookup_order", "issue_refund"],
            forbidden_tools: ["cancel_order"],
            max_tool_calls: 2
          },
          tags: %{"suite" => "refunds"}
        })
      ])

    assert {:ok, result} =
             Jido.Eval.evaluate(dataset,
               metrics: [:agent_tool_use_correctness, :agent_task_success],
               judge_model: "openai:gpt-4o-mini",
               reporters: [],
               broadcasters: [],
               config: %Jido.Eval.Config{middleware: []}
             )

    [sample_result] = result.sample_results
    assert sample_result.sample_id == "refund_success"
    assert sample_result.scores.agent_tool_use_correctness == 1.0
    assert sample_result.scores.agent_task_success == 0.95
    assert result.summary_stats.agent_task_success.count == 1
  end
end
