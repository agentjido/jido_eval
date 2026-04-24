defmodule Jido.Eval.Integration.GoldenEvalTest do
  use ExUnit.Case

  alias Jido.Eval.Dataset.InMemory
  alias Jido.Eval.Sample.SingleTurn

  @moduletag :live_eval
  @moduletag :golden_eval
  @moduletag timeout: 120_000

  setup do
    previous_llm_stub = Application.get_env(:jido_eval, :llm_stub)
    previous_judge_opts = Application.get_env(:jido_eval, :judge_opts)
    previous_llm_opts = Application.get_env(:jido_eval, :llm_opts)
    live_env_state = Jido.Eval.Test.LiveEnv.load!(["OPENAI_API_KEY"])

    Application.delete_env(:jido_eval, :llm_stub)
    Application.delete_env(:jido_eval, :judge_opts)
    Application.delete_env(:jido_eval, :llm_opts)

    on_exit(fn ->
      Jido.Eval.Test.LiveEnv.restore!(live_env_state)

      if previous_llm_stub do
        Application.put_env(:jido_eval, :llm_stub, previous_llm_stub)
      else
        Application.delete_env(:jido_eval, :llm_stub)
      end

      if previous_judge_opts do
        Application.put_env(:jido_eval, :judge_opts, previous_judge_opts)
      else
        Application.delete_env(:jido_eval, :judge_opts)
      end

      if previous_llm_opts do
        Application.put_env(:jido_eval, :llm_opts, previous_llm_opts)
      else
        Application.delete_env(:jido_eval, :llm_opts)
      end
    end)
  end

  test "Ragas-like golden RAG suite produces expected score bands" do
    {:ok, dataset} = InMemory.new(golden_samples())

    {:ok, result} =
      Jido.Eval.evaluate(dataset,
        metrics: [:faithfulness, :context_precision],
        judge_model: "openai:gpt-4o-mini",
        judge_opts: [temperature: 0.0],
        reporters: [],
        broadcasters: [],
        processors: [],
        config: %Jido.Eval.Config{middleware: []}
      )

    results_by_id = Map.new(result.sample_results, &{&1.sample_id, &1})

    assert_in_band(results_by_id["golden_grounded"], :faithfulness, {0.8, 1.0})
    assert_in_band(results_by_id["golden_grounded"], :context_precision, {0.8, 1.0})

    assert_in_band(results_by_id["golden_unsupported_claim"], :faithfulness, {0.0, 0.85})

    assert_in_band(
      results_by_id["golden_low_precision_contexts"],
      :context_precision,
      {0.0, 0.75}
    )

    assert result.summary_stats.faithfulness.count == 3
    assert result.summary_stats.context_precision.count == 3
  end

  defp golden_samples do
    [
      %SingleTurn{
        id: "golden_grounded",
        user_input: "What is the capital of France?",
        retrieved_contexts: [
          "France is a country in Western Europe. Its capital and largest city is Paris.",
          "Paris is located in northern France on the River Seine."
        ],
        response: "The capital of France is Paris.",
        reference: "Paris is the capital of France.",
        tags: %{"golden" => "grounded"}
      },
      %SingleTurn{
        id: "golden_unsupported_claim",
        user_input: "What is the capital of France?",
        retrieved_contexts: [
          "France is a country in Western Europe. Its capital and largest city is Paris."
        ],
        response: "The capital of France is Paris, and the national parliament meets in Geneva.",
        reference: "Paris is the capital of France.",
        tags: %{"golden" => "unsupported_claim"}
      },
      %SingleTurn{
        id: "golden_low_precision_contexts",
        user_input: "How do solar panels generate electricity?",
        retrieved_contexts: [
          "Sourdough bread uses wild yeast and lactic acid bacteria for fermentation.",
          "Solar panels contain photovoltaic cells that convert sunlight directly into electricity.",
          "The Roman Empire used extensive road networks for military and trade movement."
        ],
        response: "Solar panels use photovoltaic cells to convert sunlight into electricity.",
        reference: "Solar panels generate electricity when photovoltaic cells convert sunlight into current.",
        tags: %{"golden" => "low_precision_contexts"}
      }
    ]
  end

  defp assert_in_band(sample_result, metric, {minimum, maximum}) do
    score = sample_result.scores[metric]

    assert is_float(score)

    assert score >= minimum and score <= maximum,
           "Expected #{sample_result.sample_id} #{metric} score #{score} to be between #{minimum} and #{maximum}"

    assert sample_result.metric_results[metric].status == :ok
  end
end
