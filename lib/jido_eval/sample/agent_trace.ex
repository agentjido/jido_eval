defmodule Jido.Eval.Sample.AgentTrace do
  @moduledoc """
  Agent trace evaluation sample.

  This sample type captures a completed agent run for trajectory and outcome
  evaluation. It is deliberately broader than the single-turn and multi-turn LLM
  samples because agent evals need task intent, final output, trace spans, tool
  expectations, rubrics, and metadata.
  """

  alias Jido.Eval.AgentTrace.Span

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string() |> Zoi.nullable() |> Zoi.default(nil),
              task: Zoi.string() |> Zoi.nullable() |> Zoi.default(nil),
              input: Zoi.any() |> Zoi.default(nil),
              expected_outcome: Zoi.any() |> Zoi.default(nil),
              final_response: Zoi.any() |> Zoi.default(nil),
              trace: Zoi.list(Zoi.any()) |> Zoi.default([]),
              expectations: Zoi.map() |> Zoi.default(%{}),
              rubrics: Zoi.map(Zoi.string(), Zoi.string()) |> Zoi.default(%{}),
              tags: Zoi.map(Zoi.string(), Zoi.string()) |> Zoi.default(%{}),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @typedoc "Agent trace sample"
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc """
  Creates an agent trace sample with normalized spans.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, normalized_attrs} <- normalize_attrs(attrs),
         {:ok, sample} <- Zoi.parse(@schema, normalized_attrs),
         :ok <- validate(sample) do
      {:ok, sample}
    end
  end

  @doc """
  Creates an agent trace sample or raises on validation errors.
  """
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, sample} -> sample
      {:error, reason} -> raise ArgumentError, "Invalid #{inspect(__MODULE__)}: #{inspect(reason)}"
    end
  end

  @doc """
  Validates the minimum trace fields required for agent evals.
  """
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{} = sample) do
    cond do
      blank?(sample.task) ->
        {:error, "Agent trace sample must include a task"}

      not is_list(sample.trace) ->
        {:error, "Agent trace must be a list of spans"}

      sample.trace == [] ->
        {:error, "Agent trace cannot be empty"}

      not Enum.all?(sample.trace, &match?(%Span{}, &1)) ->
        {:error, "Agent trace items must be normalized spans"}

      true ->
        :ok
    end
  end

  @doc """
  Returns tool-call spans in trace order.
  """
  @spec tool_calls(t()) :: [Span.t()]
  def tool_calls(%__MODULE__{trace: trace}) do
    Enum.filter(trace, &Span.tool_call?/1)
  end

  @doc """
  Returns tool names in trace order.
  """
  @spec tool_names(t()) :: [String.t()]
  def tool_names(%__MODULE__{} = sample) do
    sample
    |> tool_calls()
    |> Enum.map(& &1.name)
    |> Enum.reject(&blank?/1)
  end

  @doc """
  Converts a sample to a serializable map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = sample) do
    sample
    |> Map.from_struct()
    |> Map.update!(:trace, &Enum.map(&1, fn span -> Span.to_map(span) end))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc """
  Creates a sample from a map, normalizing JSON string keys.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map), do: new(map)

  defp normalize_attrs(attrs) do
    with {:ok, trace} <- normalize_trace(get_value(attrs, :trace)) do
      {:ok,
       %{
         id: get_value(attrs, :id),
         task: get_value(attrs, :task),
         input: get_value(attrs, :input),
         expected_outcome: get_value(attrs, :expected_outcome),
         final_response: get_value(attrs, :final_response),
         trace: trace,
         expectations: get_value(attrs, :expectations) || %{},
         rubrics: get_value(attrs, :rubrics) || %{},
         tags: get_value(attrs, :tags) || %{},
         metadata: get_value(attrs, :metadata) || %{}
       }}
    end
  end

  defp normalize_trace(nil), do: {:ok, []}

  defp normalize_trace(spans) when is_list(spans) do
    Enum.reduce_while(spans, {:ok, []}, fn
      %Span{} = span, {:ok, acc} ->
        {:cont, {:ok, [span | acc]}}

      span, {:ok, acc} when is_map(span) ->
        case Span.new(span) do
          {:ok, normalized_span} -> {:cont, {:ok, [normalized_span | acc]}}
          {:error, reason} -> {:halt, {:error, {:invalid_span, reason}}}
        end

      other, {:ok, _acc} ->
        {:halt, {:error, {:invalid_span, other}}}
    end)
    |> case do
      {:ok, normalized_spans} -> {:ok, Enum.reverse(normalized_spans)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_trace(other), do: {:ok, other}

  defp get_value(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
