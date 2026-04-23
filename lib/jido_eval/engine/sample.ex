defmodule Jido.Eval.Engine.Sample do
  @moduledoc """
  Sample processing logic for individual evaluation samples.

  Handles the evaluation of a single sample against multiple metrics,
  collecting scores and building structured results.
  """

  require Logger

  alias Jido.Eval.{Config, ComponentRegistry}
  alias Jido.Eval.Metrics.{ContextPrecision, Faithfulness}

  @doc """
  Process a single sample with the given metrics.

  Takes a sample and runs all metrics against it, collecting scores
  and building a structured sample result.

  ## Parameters

  - `sample` - The sample to evaluate
  - `metrics` - List of metric atoms or modules to apply
  - `config` - Evaluation configuration

  ## Returns

  Returns a map containing the sample result with scores for each metric.
  """
  @spec process(term(), [atom()], Config.t()) :: map()
  def process(sample, metrics, config) do
    start_time = System.monotonic_time(:millisecond)

    metric_results =
      metrics
      |> Enum.map(&evaluate_metric(&1, sample, config))
      |> Map.new()

    end_time = System.monotonic_time(:millisecond)
    processing_time = end_time - start_time

    # Extract sample ID and tags
    sample_id = Map.get(sample, :id, nil)
    sample_tags = Map.get(sample, :tags, %{})

    # Build sample result matching expected structure
    %{
      sample_id: sample_id,
      scores: extract_scores(metric_results),
      metric_results: metric_results,
      latency_ms: processing_time,
      error: extract_error(metric_results),
      tags: sample_tags,
      metadata: %{}
    }
  end

  # Evaluate a single metric against a sample
  defp evaluate_metric(metric, sample, config) do
    # Resolve metric atom to module
    metric_module =
      case ComponentRegistry.lookup(:metric, metric) do
        {:ok, module} -> module
        {:error, _} -> built_in_metric(metric)
      end

    try do
      case metric_module.evaluate(sample, config, Config.effective_judge_opts(config)) do
        {:ok, score} ->
          {metric, normalize_success(score)}

        {:error, reason} ->
          Logger.warning("Metric #{metric} failed for sample: #{inspect(reason)}")
          {metric, normalize_error(reason)}
      end
    rescue
      error ->
        Logger.error("Metric #{metric} crashed: #{inspect(error)}")
        {metric, normalize_error({:exception, error})}
    end
  end

  defp built_in_metric(metric) do
    case metric do
      :faithfulness ->
        Faithfulness

      :context_precision ->
        ContextPrecision

      module ->
        # Assume it's already a module
        module
    end
  end

  defp normalize_success(%{score: score} = result) when is_number(score) do
    %{
      status: :ok,
      score: score / 1.0,
      error: nil,
      details: Map.get(result, :details, %{}),
      judge_calls: Map.get(result, :judge_calls, []),
      metadata: Map.get(result, :metadata, %{})
    }
  end

  defp normalize_success(score) when is_number(score) do
    %{status: :ok, score: score / 1.0, error: nil, details: %{}, judge_calls: [], metadata: %{}}
  end

  defp normalize_success(other) do
    %{
      status: :ok,
      score: nil,
      error: nil,
      details: %{result: other},
      judge_calls: [],
      metadata: %{}
    }
  end

  defp normalize_error(reason) do
    %{status: :error, score: nil, error: reason, details: %{}, judge_calls: [], metadata: %{}}
  end

  defp extract_scores(metric_results) do
    metric_results
    |> Enum.flat_map(fn
      {metric, %{status: :ok, score: score}} when is_number(score) -> [{metric, score}]
      _ -> []
    end)
    |> Map.new()
  end

  # Extract first error only when all metrics failed, preserving backward sample error behavior.
  defp extract_error(metric_results) do
    results = Map.values(metric_results)

    if results != [] and Enum.all?(results, &(&1.status == :error)) do
      Enum.find_value(results, &inspect(&1.error))
    end
  end
end
