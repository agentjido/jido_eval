defmodule Jido.Eval.AgentTrace do
  @moduledoc """
  Helpers for deriving compact, auditable views from agent traces.

  Agent metrics should avoid sending entire raw traces to judge models. These
  helpers extract focused views such as tool timelines, error spans, and compact
  task summaries that can be used by deterministic metrics or structured judges.
  """

  alias Jido.Eval.AgentTrace.Span
  alias Jido.Eval.Sample.AgentTrace, as: AgentTraceSample

  @doc """
  Builds a compact view suitable for structured judge metrics.
  """
  @spec compact_view(AgentTraceSample.t()) :: map()
  def compact_view(%AgentTraceSample{} = sample) do
    %{
      task: sample.task,
      input: sample.input,
      expected_outcome: sample.expected_outcome,
      final_response: sample.final_response,
      tool_timeline: tool_timeline(sample),
      errors: error_timeline(sample),
      span_counts: span_counts(sample),
      rubrics: sample.rubrics
    }
  end

  @doc """
  Returns a compact ordered timeline of tool calls.
  """
  @spec tool_timeline(AgentTraceSample.t()) :: [map()]
  def tool_timeline(%AgentTraceSample{} = sample) do
    sample
    |> AgentTraceSample.tool_calls()
    |> Enum.map(fn span ->
      %{
        id: span.id,
        name: span.name,
        input: span.input,
        output: span.output,
        status: span.status,
        duration_ms: span.duration_ms,
        error: span.error
      }
    end)
  end

  @doc """
  Returns failed spans in trace order.
  """
  @spec error_timeline(AgentTraceSample.t()) :: [map()]
  def error_timeline(%AgentTraceSample{trace: trace}) do
    trace
    |> Enum.filter(&Span.failed?/1)
    |> Enum.map(fn span ->
      %{
        id: span.id,
        type: span.type,
        name: span.name,
        status: span.status,
        error: span.error
      }
    end)
  end

  @doc """
  Counts spans by type.
  """
  @spec span_counts(AgentTraceSample.t()) :: %{atom() => non_neg_integer()}
  def span_counts(%AgentTraceSample{trace: trace}) do
    Enum.frequencies_by(trace, & &1.type)
  end
end
