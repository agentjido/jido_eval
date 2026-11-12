defmodule Jido.Eval.Metrics.Agent.ToolUseCorrectness do
  @moduledoc """
  Deterministic tool-use correctness metric for agent traces.

  The metric checks expected tool presence, forbidden tool absence, optional
  ordering constraints, and optional maximum tool-call count from the sample's
  `expectations` map.
  """

  @behaviour Jido.Eval.Metric

  alias Jido.Eval.Sample.AgentTrace

  @impl true
  def name, do: "Agent Tool Use Correctness"

  @impl true
  def description do
    "Checks whether an agent trace used required tools, avoided forbidden tools, and respected expected ordering."
  end

  @impl true
  def required_fields, do: [:task, :trace]

  @impl true
  def sample_types, do: [:agent_trace]

  @impl true
  def score_range, do: {0.0, 1.0}

  @impl true
  def evaluate(%AgentTrace{} = sample, _config, _opts) do
    with :ok <- Jido.Eval.Metric.validate_sample(sample, __MODULE__) do
      tool_names = AgentTrace.tool_names(sample)
      expectations = sample.expectations

      checks = [
        required_tools_check(tool_names, expectation_list(expectations, :required_tools)),
        forbidden_tools_check(tool_names, expectation_list(expectations, :forbidden_tools)),
        tool_order_check(tool_names, expectation_list(expectations, :tool_order)),
        max_tool_calls_check(tool_names, expectation_value(expectations, :max_tool_calls))
      ]

      passed = Enum.count(checks, & &1.passed)
      score = passed / length(checks)

      {:ok,
       %{
         score: score,
         details: %{
           tool_names: tool_names,
           checks: checks
         },
         metadata: %{
           deterministic: true
         }
       }}
    end
  end

  def evaluate(sample, _config, _opts) do
    sample_type = Jido.Eval.Metric.get_sample_type(sample)
    {:error, {:invalid_sample_type, sample_type}}
  end

  defp required_tools_check(_tool_names, []), do: %{name: :required_tools, passed: true, missing: []}

  defp required_tools_check(tool_names, required_tools) do
    missing = required_tools -- tool_names
    %{name: :required_tools, passed: missing == [], expected: required_tools, missing: missing}
  end

  defp forbidden_tools_check(_tool_names, []), do: %{name: :forbidden_tools, passed: true, present: []}

  defp forbidden_tools_check(tool_names, forbidden_tools) do
    present = Enum.filter(forbidden_tools, &(&1 in tool_names))
    %{name: :forbidden_tools, passed: present == [], expected_absent: forbidden_tools, present: present}
  end

  defp tool_order_check(_tool_names, []), do: %{name: :tool_order, passed: true, expected_order: []}

  defp tool_order_check(tool_names, expected_order) do
    passed = ordered_subsequence?(tool_names, expected_order)
    %{name: :tool_order, passed: passed, expected_order: expected_order}
  end

  defp max_tool_calls_check(tool_names, nil), do: %{name: :max_tool_calls, passed: true, count: length(tool_names)}

  defp max_tool_calls_check(tool_names, max_tool_calls) when is_integer(max_tool_calls) do
    count = length(tool_names)
    %{name: :max_tool_calls, passed: count <= max_tool_calls, max: max_tool_calls, count: count}
  end

  defp max_tool_calls_check(tool_names, _invalid) do
    %{name: :max_tool_calls, passed: true, count: length(tool_names), ignored: :invalid_expectation}
  end

  defp ordered_subsequence?(_tool_names, []), do: true
  defp ordered_subsequence?([], _expected_order), do: false

  defp ordered_subsequence?([tool | rest], [tool | expected_rest]), do: ordered_subsequence?(rest, expected_rest)
  defp ordered_subsequence?([_tool | rest], expected_order), do: ordered_subsequence?(rest, expected_order)

  defp expectation_list(expectations, key) do
    expectations
    |> expectation_value(key)
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp expectation_value(expectations, key) when is_map(expectations) do
    Map.get(expectations, key) || Map.get(expectations, Atom.to_string(key))
  end
end
