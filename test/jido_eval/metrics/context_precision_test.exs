defmodule Jido.Eval.Metrics.ContextPrecisionTest do
  use ExUnit.Case, async: false

  alias Jido.Eval.Metrics.ContextPrecision
  alias Jido.Eval.{Config, Sample.MultiTurn, Sample.SingleTurn}
  alias ReqLLM.Error

  @moduletag :capture_log

  setup do
    previous_llm_stub = Application.get_env(:jido_eval, :llm_stub)

    config = %Config{
      judge_model: "openai:gpt-3.5-turbo"
    }

    on_exit(fn ->
      if previous_llm_stub do
        Application.put_env(:jido_eval, :llm_stub, previous_llm_stub)
      else
        Application.delete_env(:jido_eval, :llm_stub)
      end
    end)

    %{config: config}
  end

  describe "metric metadata" do
    test "returns correct name" do
      assert ContextPrecision.name() == "Context Precision"
    end

    test "returns correct description" do
      description = ContextPrecision.description()
      assert String.contains?(description, "relevance")
      assert String.contains?(description, "contexts")
      assert String.contains?(description, "question")
    end

    test "returns required fields" do
      assert ContextPrecision.required_fields() == [:user_input, :retrieved_contexts, :reference]
    end

    test "returns supported sample types" do
      assert ContextPrecision.sample_types() == [:single_turn]
    end

    test "returns score range" do
      assert ContextPrecision.score_range() == {0.0, 1.0}
    end
  end

  describe "evaluate/3" do
    test "evaluates perfect precision with all relevant contexts", %{config: config} do
      stub_relevance_judge(%{
        "Paris is the capital and largest city of France." => true,
        "France is a country in Western Europe." => true
      })

      sample = %SingleTurn{
        user_input: "What is the capital of France?",
        retrieved_contexts: [
          "Paris is the capital and largest city of France.",
          "France is a country in Western Europe."
        ],
        reference: "Paris is the capital of France."
      }

      assert {:ok, result} = ContextPrecision.evaluate(sample, config, [])
      assert result.score == 1.0
      assert result.details.relevant_count == 2
      assert result.details.context_count == 2
      assert [%{type: :object}, %{type: :object}] = result.judge_calls
    end

    test "evaluates mixed precision with relevant and irrelevant contexts", %{config: config} do
      stub_relevance_judge(%{
        "Germany is a country in Central Europe." => false,
        "Paris is the capital and largest city of France." => true,
        "Spain shares a border with France." => true
      })

      sample = %SingleTurn{
        user_input: "What is the capital of France?",
        retrieved_contexts: [
          "Germany is a country in Central Europe.",
          "Paris is the capital and largest city of France.",
          "Spain shares a border with France."
        ],
        reference: "Paris is the capital of France."
      }

      assert {:ok, result} = ContextPrecision.evaluate(sample, config, [])

      assert_in_delta result.score, 0.583, 0.01
      assert Enum.map(result.details.contexts, & &1.relevant) == [false, true, true]
    end

    test "evaluates zero precision with no relevant contexts", %{config: config} do
      stub_relevance_judge(%{
        "The weather in Tokyo is nice." => false,
        "Cats are popular pets." => false
      })

      sample = %SingleTurn{
        user_input: "What is the capital of France?",
        retrieved_contexts: [
          "The weather in Tokyo is nice.",
          "Cats are popular pets."
        ],
        reference: "Paris is the capital of France."
      }

      assert {:ok, result} = ContextPrecision.evaluate(sample, config, [])
      assert result.score == 0.0
    end

    test "handles empty contexts list", %{config: config} do
      sample = %SingleTurn{
        user_input: "What is the capital of France?",
        retrieved_contexts: [],
        reference: "Paris is the capital of France."
      }

      assert {:error, {:missing_field, :retrieved_contexts}} =
               ContextPrecision.evaluate(sample, config, [])
    end

    test "handles missing user input", %{config: config} do
      sample = %SingleTurn{
        user_input: nil,
        retrieved_contexts: ["Some context"],
        reference: "Some reference"
      }

      assert {:error, {:missing_field, :user_input}} =
               ContextPrecision.evaluate(sample, config, [])
    end

    test "handles missing reference", %{config: config} do
      sample = %SingleTurn{
        user_input: "What is the capital?",
        retrieved_contexts: ["Some context"],
        reference: nil
      }

      assert {:error, {:missing_field, :reference}} =
               ContextPrecision.evaluate(sample, config, [])
    end

    test "rejects multi-turn samples", %{config: config} do
      sample = %MultiTurn{
        conversation: [%{role: :user, content: "Hello"}]
      }

      assert {:error, {:invalid_sample_type, :multi_turn}} =
               ContextPrecision.evaluate(sample, config, [])
    end

    test "returns ReqLLM errors from judge calls", %{config: config} do
      error = Error.API.Request.exception(reason: :unavailable, status: 503)

      Application.put_env(:jido_eval, :llm_stub, fn :object, _model, _prompt, _schema, _opts ->
        {:error, error}
      end)

      sample = %SingleTurn{
        user_input: "What is the capital of France?",
        retrieved_contexts: ["Paris is the capital of France."],
        reference: "Paris"
      }

      assert {:error, ^error} = ContextPrecision.evaluate(sample, config, [])
    end

    test "defaults irrelevant when structured relevance field is absent", %{config: config} do
      Application.put_env(:jido_eval, :llm_stub, fn :object, _model, _prompt, _schema, _opts ->
        {:ok, %{reasoning: "Ambiguous"}}
      end)

      sample = %SingleTurn{
        user_input: "What is the capital of France?",
        retrieved_contexts: ["Paris is the capital of France."],
        reference: "Paris"
      }

      assert {:ok, result} = ContextPrecision.evaluate(sample, config, [])
      assert result.score == 0.0
    end

    test "evaluates single relevant context", %{config: config} do
      stub_relevance_judge(%{"Paris is the capital and largest city of France." => true})

      sample = %SingleTurn{
        user_input: "What is the capital of France?",
        retrieved_contexts: ["Paris is the capital and largest city of France."],
        reference: "Paris is the capital of France."
      }

      assert {:ok, result} = ContextPrecision.evaluate(sample, config, [])
      assert result.score == 1.0
    end

    test "calculates precision correctly when relevant context is first", %{config: config} do
      stub_relevance_judge(%{
        "Paris is the capital and largest city of France." => true,
        "The weather in Tokyo is nice." => false
      })

      sample = %SingleTurn{
        user_input: "What is the capital of France?",
        retrieved_contexts: [
          "Paris is the capital and largest city of France.",
          "The weather in Tokyo is nice."
        ],
        reference: "Paris is the capital of France."
      }

      assert {:ok, result} = ContextPrecision.evaluate(sample, config, [])
      assert result.score == 1.0
    end
  end

  describe "performance" do
    @describetag :skip
    @describetag :benchmark
    test "evaluates sample with multiple contexts within reasonable time", %{config: config} do
      stub_relevance_judge(%{
        "Paris is the capital of France." => true,
        "France is in Europe." => true,
        "Germany borders France." => false,
        "Spain also borders France." => false,
        "The Mediterranean Sea is south of France." => false
      })

      sample = %SingleTurn{
        user_input: "What is the capital of France?",
        retrieved_contexts: [
          "Paris is the capital of France.",
          "France is in Europe.",
          "Germany borders France.",
          "Spain also borders France.",
          "The Mediterranean Sea is south of France."
        ],
        reference: "Paris"
      }

      {time_micro, {:ok, _result}} =
        :timer.tc(fn -> ContextPrecision.evaluate(sample, config, timeout: 15_000) end)

      assert time_micro < 15_000_000
    end
  end

  defp stub_relevance_judge(relevance_by_context) do
    Application.put_env(:jido_eval, :llm_stub, fn :object,
                                                  %LLMDB.Model{},
                                                  prompt,
                                                  _schema,
                                                  _opts ->
      relevant =
        relevance_by_context
        |> Enum.find_value(false, fn {context, value} ->
          if String.contains?(prompt, context), do: value
        end)

      {:ok, %{relevant: relevant, reasoning: "structured judge result"}}
    end)
  end
end
