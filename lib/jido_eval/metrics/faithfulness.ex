defmodule Jido.Eval.Metrics.Faithfulness do
  @moduledoc """
  Faithfulness metric for evaluating how grounded responses are in provided contexts.

  The metric extracts factual statements from a response, checks each statement
  against retrieved contexts using structured judge output, and scores the share
  of statements supported by the contexts.
  """

  @behaviour Jido.Eval.Metric

  alias Jido.Eval.Config
  alias Jido.Eval.Metrics.Utils
  alias Jido.Eval.Sample.SingleTurn

  require Logger

  @statement_extraction_prompt """
  Given the following response, extract all individual factual claims or statements that can be fact-checked.
  Return concise standalone statements. Do not include opinions, filler, or duplicate claims.

  Response:
  {{response}}
  """

  @faithfulness_check_prompt """
  Given the following contexts and a statement, determine whether the statement is supported by or can be inferred from the contexts.
  Judge only against the provided contexts.

  Contexts:
  {{contexts}}

  Statement:
  {{statement}}
  """

  @statement_schema %{
    "type" => "object",
    "required" => ["statements"],
    "additionalProperties" => false,
    "properties" => %{
      "statements" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "required" => ["text"],
          "additionalProperties" => false,
          "properties" => %{
            "text" => %{"type" => "string"}
          }
        }
      }
    }
  }

  @support_schema %{
    "type" => "object",
    "required" => ["supported", "reasoning"],
    "additionalProperties" => false,
    "properties" => %{
      "supported" => %{"type" => "boolean"},
      "reasoning" => %{"type" => "string"}
    }
  }

  @impl true
  def name, do: "Faithfulness"

  @impl true
  def description do
    "Measures how grounded the response is in the provided contexts by checking if " <>
      "all statements in the response can be attributed to the given contexts"
  end

  @impl true
  def required_fields, do: [:response, :retrieved_contexts]

  @impl true
  def sample_types, do: [:single_turn]

  @impl true
  def score_range, do: {0.0, 1.0}

  @impl true
  def evaluate(%SingleTurn{} = sample, config, opts) do
    Logger.debug("Starting faithfulness evaluation")

    with :ok <- Jido.Eval.Metric.validate_sample(sample, __MODULE__),
         {:ok, statements, extraction_call} <- extract_statements(sample.response, config, opts),
         {:ok, statement_results, check_calls} <-
           check_statements_faithfulness(statements, sample.retrieved_contexts, config, opts) do
      supported_count = Enum.count(statement_results, & &1.supported)

      score =
        if statement_results == [], do: 0.0, else: supported_count / length(statement_results)

      Logger.debug("Faithfulness evaluation completed with score: #{score}")

      {:ok,
       %{
         score: score,
         details: %{
           statements: statement_results,
           supported_count: supported_count,
           statement_count: length(statement_results)
         },
         judge_calls: [extraction_call | check_calls]
       }}
    else
      {:error, reason} ->
        Logger.warning("Faithfulness evaluation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def evaluate(sample, _config, _opts) do
    sample_type = Jido.Eval.Metric.get_sample_type(sample)
    {:error, {:invalid_sample_type, sample_type}}
  end

  defp extract_statements(response, config, opts) do
    prompt = Utils.build_prompt(@statement_extraction_prompt, %{response: response})

    case Utils.execute_llm_object_metric(
           "Faithfulness",
           Config.effective_judge_model(config),
           prompt,
           @statement_schema,
           opts
         ) do
      {:ok, {object, call}} ->
        statements = parse_statements(object)
        {:ok, if(statements == [], do: [response], else: statements), call}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_statements(%{statements: statements}) when is_list(statements) do
    statements
    |> Enum.map(fn
      %{text: text} when is_binary(text) -> String.trim(text)
      %{"text" => text} when is_binary(text) -> String.trim(text)
      text when is_binary(text) -> String.trim(text)
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_statements(_object), do: []

  defp check_statements_faithfulness(statements, contexts, config, opts) do
    formatted_contexts = Utils.format_contexts(contexts)

    statements
    |> Task.async_stream(
      fn statement ->
        check_single_statement(statement, formatted_contexts, config, opts)
      end,
      timeout: Keyword.get(opts, :timeout, 30_000),
      max_concurrency: 3
    )
    |> Enum.to_list()
    |> collect_results()
  end

  defp check_single_statement(statement, formatted_contexts, config, opts) do
    prompt =
      Utils.build_prompt(@faithfulness_check_prompt, %{
        contexts: formatted_contexts,
        statement: statement
      })

    case Utils.execute_llm_object_metric(
           "Faithfulness",
           Config.effective_judge_model(config),
           prompt,
           @support_schema,
           opts
         ) do
      {:ok, {object, call}} ->
        object = object || %{}

        {:ok,
         %{
           text: statement,
           supported: Map.get(object, :supported, false),
           reasoning: Map.get(object, :reasoning, "")
         }, call}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_results(results) do
    case Enum.find(results, fn
           {:exit, _} -> true
           {:ok, {:error, _}} -> true
           _ -> false
         end) do
      nil ->
        statement_results =
          Enum.map(results, fn {:ok, {:ok, statement_result, _call}} -> statement_result end)

        calls =
          Enum.map(results, fn {:ok, {:ok, _statement_result, call}} -> call end)

        {:ok, statement_results, calls}

      {:exit, reason} ->
        {:error, {:timeout, reason}}

      {:ok, {:error, reason}} ->
        {:error, reason}
    end
  end
end
