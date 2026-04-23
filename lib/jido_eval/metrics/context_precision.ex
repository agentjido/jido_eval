defmodule Jido.Eval.Metrics.ContextPrecision do
  @moduledoc """
  Context Precision metric for evaluating retrieved context relevance.

  The metric asks a structured judge whether each retrieved context is useful for
  answering the user question, then calculates average precision over the
  retrieval order.
  """

  @behaviour Jido.Eval.Metric

  alias Jido.Eval.Config
  alias Jido.Eval.Metrics.Utils
  alias Jido.Eval.Sample.SingleTurn

  require Logger

  @relevance_check_prompt """
  Given a user question, a reference answer, and a context passage, determine whether the context is relevant for answering the question.

  A context is relevant if it contains information that helps answer the user's question, even if it does not contain the full answer.

  User Question:
  {{user_input}}

  Reference Answer:
  {{reference}}

  Context:
  {{context}}
  """

  @relevance_schema %{
    "type" => "object",
    "required" => ["relevant", "reasoning"],
    "additionalProperties" => false,
    "properties" => %{
      "relevant" => %{"type" => "boolean"},
      "reasoning" => %{"type" => "string"}
    }
  }

  @impl true
  def name, do: "Context Precision"

  @impl true
  def description do
    "Measures the relevance of retrieved contexts to the user question by evaluating " <>
      "how many retrieved contexts are useful for answering the question"
  end

  @impl true
  def required_fields, do: [:user_input, :retrieved_contexts, :reference]

  @impl true
  def sample_types, do: [:single_turn]

  @impl true
  def score_range, do: {0.0, 1.0}

  @impl true
  def evaluate(%SingleTurn{} = sample, config, opts) do
    Logger.debug("Starting context precision evaluation")

    with :ok <- Jido.Eval.Metric.validate_sample(sample, __MODULE__),
         {:ok, context_results, judge_calls} <- evaluate_context_relevance(sample, config, opts),
         {:ok, precision_score} <- calculate_precision(Enum.map(context_results, & &1.relevant)) do
      Logger.debug("Context precision evaluation completed with score: #{precision_score}")

      {:ok,
       %{
         score: precision_score,
         details: %{
           contexts: context_results,
           relevant_count: Enum.count(context_results, & &1.relevant),
           context_count: length(context_results)
         },
         judge_calls: judge_calls
       }}
    else
      {:error, reason} ->
        Logger.warning("Context precision evaluation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def evaluate(sample, _config, _opts) do
    sample_type = Jido.Eval.Metric.get_sample_type(sample)
    {:error, {:invalid_sample_type, sample_type}}
  end

  defp evaluate_context_relevance(%SingleTurn{retrieved_contexts: []}, _config, _opts),
    do: {:ok, [], []}

  defp evaluate_context_relevance(sample, config, opts) do
    sample.retrieved_contexts
    |> Enum.with_index()
    |> Task.async_stream(
      fn {context, index} ->
        evaluate_single_context(sample, context, index, config, opts)
      end,
      timeout: Keyword.get(opts, :timeout, 30_000),
      max_concurrency: 3
    )
    |> Enum.to_list()
    |> collect_relevance_results()
  end

  defp evaluate_single_context(sample, context, index, config, opts) do
    prompt =
      Utils.build_prompt(@relevance_check_prompt, %{
        user_input: sample.user_input,
        reference: sample.reference,
        context: context
      })

    case Utils.execute_llm_object_metric(
           "Context Precision",
           Config.effective_judge_model(config),
           prompt,
           @relevance_schema,
           opts
         ) do
      {:ok, {object, call}} ->
        object = object || %{}

        {:ok,
         %{
           index: index,
           context: context,
           relevant: Map.get(object, :relevant, false),
           reasoning: Map.get(object, :reasoning, "")
         }, call}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_relevance_results(results) do
    case Enum.find(results, fn
           {:exit, _} -> true
           {:ok, {:error, _}} -> true
           _ -> false
         end) do
      nil ->
        context_results =
          results
          |> Enum.map(fn {:ok, {:ok, context_result, _call}} -> context_result end)
          |> Enum.sort_by(& &1.index)

        calls =
          Enum.map(results, fn {:ok, {:ok, _context_result, call}} -> call end)

        {:ok, context_results, calls}

      {:exit, reason} ->
        {:error, {:timeout, reason}}

      {:ok, {:error, reason}} ->
        {:error, reason}
    end
  end

  defp calculate_precision([]), do: {:ok, 0.0}

  defp calculate_precision(relevance_scores) do
    precisions =
      relevance_scores
      |> Enum.with_index(1)
      |> Enum.map(fn {is_relevant, position} ->
        if is_relevant do
          relevant_count =
            relevance_scores
            |> Enum.take(position)
            |> Enum.count(& &1)

          relevant_count / position
        else
          0.0
        end
      end)

    relevant_precisions = Enum.filter(precisions, &(&1 > 0.0))

    average_precision =
      if relevant_precisions == [] do
        0.0
      else
        Enum.sum(relevant_precisions) / length(relevant_precisions)
      end

    {:ok, average_precision}
  end
end
