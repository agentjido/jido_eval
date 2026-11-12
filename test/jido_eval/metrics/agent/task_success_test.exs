defmodule Jido.Eval.Metrics.Agent.TaskSuccessTest do
  use ExUnit.Case, async: false

  alias Jido.Eval.Config
  alias Jido.Eval.Metrics.Agent.TaskSuccess
  alias Jido.Eval.Sample.{AgentTrace, SingleTurn}
  alias ReqLLM.Error

  @moduletag :capture_log

  setup do
    previous_llm_stub = Application.get_env(:jido_eval, :llm_stub)

    on_exit(fn ->
      if previous_llm_stub do
        Application.put_env(:jido_eval, :llm_stub, previous_llm_stub)
      else
        Application.delete_env(:jido_eval, :llm_stub)
      end
    end)

    %{config: %Config{judge_model: "openai:gpt-4o-mini"}}
  end

  describe "metadata" do
    test "declares agent trace support" do
      assert TaskSuccess.name() == "Agent Task Success"
      assert TaskSuccess.required_fields() == [:task, :trace]
      assert TaskSuccess.sample_types() == [:agent_trace]
      assert TaskSuccess.score_range() == {0.0, 1.0}
    end
  end

  describe "evaluate/3" do
    test "scores task success through structured judge output", %{config: config} do
      Application.put_env(:jido_eval, :llm_stub, fn
        :object, _model, prompt, _schema, _opts ->
          assert String.contains?(prompt, "Compact trace view")
          assert String.contains?(prompt, "lookup_order")
          {:ok, %{success: true, score: 0.92, reasoning: "The refund was correctly issued.", failure_modes: []}}
      end)

      assert {:ok, result} = TaskSuccess.evaluate(agent_trace(), config, [])

      assert result.score == 0.92
      assert result.details.success == true
      assert result.details.reasoning == "The refund was correctly issued."
      assert [%{type: :object, output: %{score: 0.92, success: true}}] = result.judge_calls
    end

    test "clamps invalid numeric judge scores", %{config: config} do
      Application.put_env(:jido_eval, :llm_stub, fn :object, _model, _prompt, _schema, _opts ->
        {:ok, %{success: true, score: 2.0, reasoning: "Overconfident", failure_modes: []}}
      end)

      assert {:ok, result} = TaskSuccess.evaluate(agent_trace(), config, [])
      assert result.score == 1.0
    end

    test "defaults non-numeric judge scores to zero", %{config: config} do
      Application.put_env(:jido_eval, :llm_stub, fn :object, _model, _prompt, _schema, _opts ->
        {:ok, %{success: false, score: "bad", reasoning: "No score", failure_modes: ["invalid"]}}
      end)

      assert {:ok, result} = TaskSuccess.evaluate(agent_trace(), config, [])
      assert result.score == 0.0
      assert result.details.success == false
      assert result.details.failure_modes == ["invalid"]
    end

    test "returns ReqLLM errors from judge calls", %{config: config} do
      error = Error.API.Request.exception(reason: :unavailable, status: 503)

      Application.put_env(:jido_eval, :llm_stub, fn :object, _model, _prompt, _schema, _opts ->
        {:error, error}
      end)

      assert {:error, ^error} = TaskSuccess.evaluate(agent_trace(), config, [])
    end

    test "rejects non-agent samples", %{config: config} do
      assert {:error, {:invalid_sample_type, :single_turn}} =
               TaskSuccess.evaluate(%SingleTurn{response: "ok"}, config, [])
    end
  end

  defp agent_trace do
    AgentTrace.new!(%{
      task: "Resolve refund",
      expected_outcome: %{refunded: true},
      final_response: "Refund issued.",
      trace: [
        %{type: "llm_call", name: "plan", output: "Look up order then refund."},
        %{type: "tool_call", name: "lookup_order", output: %{eligible: true}},
        %{type: "tool_call", name: "issue_refund", output: %{refund_id: "ref_123"}}
      ],
      rubrics: %{"policy" => "Look up order before issuing refund"}
    })
  end
end
