defmodule Jido.Eval.AgentTrace.Span do
  @moduledoc """
  Normalized span within a Jido Agent trace.

  Spans preserve the minimum shape needed for agent eval metrics: event type,
  parent/child identity, inputs, outputs, status, timing, errors, and metadata.
  The structure is intentionally permissive so saved traces from different agent
  runtimes can be normalized without losing raw fields.
  """

  @known_types [:agent_step, :llm_call, :tool_call, :decision, :message, :error, :event]
  @known_statuses [:ok, :error, :skipped, :timeout, :unknown]

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string() |> Zoi.nullable() |> Zoi.default(nil),
              parent_id: Zoi.string() |> Zoi.nullable() |> Zoi.default(nil),
              type: Zoi.any() |> Zoi.default(:event),
              name: Zoi.string() |> Zoi.nullable() |> Zoi.default(nil),
              input: Zoi.any() |> Zoi.default(nil),
              output: Zoi.any() |> Zoi.default(nil),
              status: Zoi.any() |> Zoi.default(:ok),
              started_at: Zoi.any() |> Zoi.default(nil),
              ended_at: Zoi.any() |> Zoi.default(nil),
              duration_ms: Zoi.integer() |> Zoi.nullable() |> Zoi.default(nil),
              error: Zoi.any() |> Zoi.default(nil),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @typedoc "Normalized agent trace span"
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc """
  Builds a normalized span from a map.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    attrs
    |> normalize_attrs()
    |> then(&Zoi.parse(@schema, &1))
  end

  @doc """
  Builds a normalized span or raises on validation errors.
  """
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, span} -> span
      {:error, reason} -> raise ArgumentError, "Invalid #{inspect(__MODULE__)}: #{inspect(reason)}"
    end
  end

  @doc """
  Converts a span to a serializable map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = span) do
    span
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc """
  Returns true when this span is a tool call.
  """
  @spec tool_call?(t()) :: boolean()
  def tool_call?(%__MODULE__{type: :tool_call}), do: true
  def tool_call?(_span), do: false

  @doc """
  Returns true when this span records a failed step.
  """
  @spec failed?(t()) :: boolean()
  def failed?(%__MODULE__{status: status}) when status in [:error, :timeout], do: true
  def failed?(_span), do: false

  @doc """
  Normalizes map data loaded from JSON or emitted by a runtime.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map), do: new(map)

  defp normalize_attrs(attrs) do
    %{
      id: get_value(attrs, :id),
      parent_id: get_value(attrs, :parent_id),
      type: normalize_atom(get_value(attrs, :type), @known_types, :event),
      name: get_value(attrs, :name),
      input: get_value(attrs, :input),
      output: get_value(attrs, :output),
      status: normalize_atom(get_value(attrs, :status), @known_statuses, :ok),
      started_at: get_value(attrs, :started_at),
      ended_at: get_value(attrs, :ended_at),
      duration_ms: get_value(attrs, :duration_ms),
      error: get_value(attrs, :error),
      metadata: get_value(attrs, :metadata) || %{}
    }
  end

  defp get_value(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_atom(value, allowed, default) when is_atom(value) do
    if value in allowed, do: value, else: default
  end

  defp normalize_atom(value, allowed, default) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    Enum.find(allowed, default, &(Atom.to_string(&1) == normalized))
  end

  defp normalize_atom(_value, _allowed, default), do: default
end
