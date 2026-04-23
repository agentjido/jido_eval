defmodule Jido.Eval.Metrics.FaithfulnessTest do
  use ExUnit.Case, async: false

  alias Jido.Eval.Metrics.Faithfulness
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
      assert Faithfulness.name() == "Faithfulness"
    end

    test "returns correct description" do
      description = Faithfulness.description()
      assert String.contains?(description, "grounded")
      assert String.contains?(description, "contexts")
    end

    test "returns required fields" do
      assert Faithfulness.required_fields() == [:response, :retrieved_contexts]
    end

    test "returns supported sample types" do
      assert Faithfulness.sample_types() == [:single_turn]
    end

    test "returns score range" do
      assert Faithfulness.score_range() == {0.0, 1.0}
    end
  end

  describe "evaluate/3" do
    test "evaluates faithful response with perfect score", %{config: config} do
      stub_structured_judge(
        extraction: [%{text: "Paris is the capital of France."}],
        support: %{"Paris is the capital of France." => true}
      )

      sample = %SingleTurn{
        response: "Paris is the capital of France.",
        retrieved_contexts: ["France's capital city is Paris."]
      }

      assert {:ok, result} = Faithfulness.evaluate(sample, config, [])
      assert result.score == 1.0
      assert result.details.supported_count == 1
      assert result.details.statement_count == 1
      assert [%{type: :object}, %{type: :object}] = result.judge_calls
    end

    test "evaluates partially faithful response", %{config: config} do
      stub_structured_judge(
        extraction: [
          %{text: "Paris is the capital of France."},
          %{text: "London is the capital of Germany."}
        ],
        support: %{
          "Paris is the capital of France." => true,
          "London is the capital of Germany." => false
        }
      )

      sample = %SingleTurn{
        response: "Paris is the capital of France. London is the capital of Germany.",
        retrieved_contexts: ["France's capital city is Paris."]
      }

      assert {:ok, result} = Faithfulness.evaluate(sample, config, [])
      assert result.score == 0.5
      assert Enum.map(result.details.statements, & &1.supported) == [true, false]
    end

    test "evaluates unfaithful response with zero score", %{config: config} do
      stub_structured_judge(
        extraction: [%{text: "Mars is inhabited by aliens."}],
        support: %{"Mars is inhabited by aliens." => false}
      )

      sample = %SingleTurn{
        response: "Mars is inhabited by aliens.",
        retrieved_contexts: ["Mars is a planet in our solar system."]
      }

      assert {:ok, result} = Faithfulness.evaluate(sample, config, [])
      assert result.score == 0.0
    end

    test "handles empty response", %{config: config} do
      sample = %SingleTurn{
        response: "",
        retrieved_contexts: ["Some context"]
      }

      assert {:error, {:missing_field, :response}} =
               Faithfulness.evaluate(sample, config, [])
    end

    test "handles missing contexts", %{config: config} do
      sample = %SingleTurn{
        response: "Some response",
        retrieved_contexts: nil
      }

      assert {:error, {:missing_field, :retrieved_contexts}} =
               Faithfulness.evaluate(sample, config, [])
    end

    test "handles empty contexts list", %{config: config} do
      sample = %SingleTurn{
        response: "Some response",
        retrieved_contexts: []
      }

      assert {:error, {:missing_field, :retrieved_contexts}} =
               Faithfulness.evaluate(sample, config, [])
    end

    test "rejects multi-turn samples", %{config: config} do
      sample = %MultiTurn{
        conversation: [%{role: :user, content: "Hello"}]
      }

      assert {:error, {:invalid_sample_type, :multi_turn}} =
               Faithfulness.evaluate(sample, config, [])
    end

    test "returns ReqLLM errors from judge calls", %{config: config} do
      error = Error.API.Request.exception(reason: :rate_limit, status: 429)

      Application.put_env(:jido_eval, :llm_stub, fn :object, _model, _prompt, _schema, _opts ->
        {:error, error}
      end)

      sample = %SingleTurn{
        response: "Paris is the capital of France.",
        retrieved_contexts: ["France's capital city is Paris."]
      }

      assert {:error, ^error} = Faithfulness.evaluate(sample, config, [])
    end

    test "defaults unsupported when structured support field is absent", %{config: config} do
      Application.put_env(:jido_eval, :llm_stub, fn
        :object, _model, prompt, _schema, _opts ->
          if String.contains?(prompt, "extract all individual factual claims") do
            {:ok, %{statements: [%{text: "Paris is the capital of France."}]}}
          else
            {:ok, %{reasoning: "Ambiguous"}}
          end
      end)

      sample = %SingleTurn{
        response: "Paris is the capital of France.",
        retrieved_contexts: ["France's capital city is Paris."]
      }

      assert {:ok, result} = Faithfulness.evaluate(sample, config, [])
      assert result.score == 0.0
    end

    test "uses entire response as statement when extraction returns no statements", %{
      config: config
    } do
      Application.put_env(:jido_eval, :llm_stub, fn
        :object, _model, prompt, _schema, _opts ->
          if String.contains?(prompt, "extract all individual factual claims") do
            {:ok, %{statements: []}}
          else
            {:ok, %{supported: true, reasoning: "Supported by context"}}
          end
      end)

      sample = %SingleTurn{
        response: "Paris is the capital of France.",
        retrieved_contexts: ["France's capital city is Paris."]
      }

      assert {:ok, result} = Faithfulness.evaluate(sample, config, [])
      assert result.score == 1.0

      assert [%{text: "Paris is the capital of France.", supported: true}] =
               result.details.statements
    end
  end

  describe "performance" do
    @describetag :skip
    @describetag :benchmark
    test "evaluates sample within reasonable time", %{config: config} do
      stub_structured_judge(
        extraction: [%{text: "Paris is the capital of France."}],
        support: %{"Paris is the capital of France." => true}
      )

      sample = %SingleTurn{
        response: "Paris is the capital of France and it's located in Europe.",
        retrieved_contexts: ["France's capital city is Paris, located in northern France."]
      }

      {time_micro, {:ok, _result}} =
        :timer.tc(fn -> Faithfulness.evaluate(sample, config, timeout: 10_000) end)

      assert time_micro < 10_000_000
    end
  end

  defp stub_structured_judge(opts) do
    statements = Keyword.fetch!(opts, :extraction)
    support = Keyword.fetch!(opts, :support)

    Application.put_env(:jido_eval, :llm_stub, fn
      :object, %LLMDB.Model{}, prompt, _schema, _opts ->
        cond do
          String.contains?(prompt, "extract all individual factual claims") ->
            {:ok, %{statements: statements}}

          true ->
            supported =
              support
              |> Enum.find_value(false, fn {statement, value} ->
                if String.contains?(prompt, statement), do: value
              end)

            {:ok, %{supported: supported, reasoning: "structured judge result"}}
        end
    end)
  end
end
