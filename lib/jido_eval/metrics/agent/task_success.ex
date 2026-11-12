defmodule Jido.Eval.Metrics.Agent.TaskSuccess do
  @moduledoc """
  Structured judge metric for evaluating whether an agent completed its task.

  The judge receives a compact trace view rather than the full raw trace. This
  keeps the metric auditable and limits token usage while preserving the final
  response, tool timeline, errors, expected outcome, and rubrics.
  """

  @behaviour Jido.Eval.Metric

  alias Jido.Eval.{AgentTrace, Config}
  alias Jido.Eval.Metrics.Utils
  alias Jido.Eval.Sample.AgentTrace, as: AgentTraceSample

  @prompt """
  Evaluate whether the agent completed the task successfully.

  Judge only from the compact trace view, expected outcome, final response, and rubrics.
  Return a calibrated score from 0.0 to 1.0.

  Compact trace view:
  {{trace_view}}
  """

  @schema %{
    "type" => "object",
    "required" => ["success", "score", "reasoning"],
    "additionalProperties" => false,
    "properties" => %{
      "success" => %{"type" => "boolean"},
      "score" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
      "reasoning" => %{"type" => "string"},
      "failure_modes" => %{
        "type" => "array",
        "items" => %{"type" => "string"}
      }
    }
  }

  @impl true
  def name, do: "Agent Task Success"

  @impl true
  def description do
    "Uses a structured judge call over a compact trace view to score whether an agent completed its task."
  end

  @impl true
  def required_fields, do: [:task, :trace]

  @impl true
  def sample_types, do: [:agent_trace]

  @impl true
  def score_range, do: {0.0, 1.0}

  @impl true
  def evaluate(%AgentTraceSample{} = sample, config, opts) do
    with :ok <- Jido.Eval.Metric.validate_sample(sample, __MODULE__),
         {:ok, prompt} <- build_prompt(sample),
         {:ok, {object, call}} <-
           Utils.execute_llm_object_metric(
             "Agent Task Success",
             Config.effective_judge_model(config),
             prompt,
             @schema,
             opts
           ) do
      score = object |> Map.get(:score, 0.0) |> clamp_score()

      {:ok,
       %{
         score: score,
         details: %{
           success: Map.get(object, :success, score >= 0.5),
           reasoning: Map.get(object, :reasoning, ""),
           failure_modes: Map.get(object, :failure_modes, []),
           compact_view: AgentTrace.compact_view(sample)
         },
         judge_calls: [call]
       }}
    end
  end

  def evaluate(sample, _config, _opts) do
    sample_type = Jido.Eval.Metric.get_sample_type(sample)
    {:error, {:invalid_sample_type, sample_type}}
  end

  defp build_prompt(sample) do
    case Jason.encode(AgentTrace.compact_view(sample)) do
      {:ok, trace_view} ->
        {:ok, Utils.build_prompt(@prompt, %{trace_view: trace_view})}

      {:error, reason} ->
        {:error, {:encode_trace_view_failed, reason}}
    end
  end

  defp clamp_score(score) when is_number(score), do: score |> max(0.0) |> min(1.0) |> Kernel./(1.0)
  defp clamp_score(_score), do: 0.0
end
