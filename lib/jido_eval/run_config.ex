defmodule Jido.Eval.RunConfig do
  @moduledoc """
  Configuration for evaluation run execution.

  Controls runtime behavior including timeouts, parallelism, and caching.

  ## Examples

      iex> config = %Jido.Eval.RunConfig{}
      iex> config.max_workers
      16
      
      iex> config = %Jido.Eval.RunConfig{timeout: 300_000, max_workers: 8}
      iex> config.timeout
      300000
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              run_id: Zoi.string() |> Zoi.nullable() |> Zoi.default(nil),
              timeout: Zoi.integer() |> Zoi.default(180_000),
              max_workers: Zoi.integer() |> Zoi.default(16),
              seed: Zoi.integer() |> Zoi.default(42),
              retry_policy: Zoi.any() |> Zoi.default(%Jido.Eval.RetryPolicy{}),
              enable_caching: Zoi.boolean() |> Zoi.default(false),
              telemetry_prefix: Zoi.list(Zoi.atom()) |> Zoi.default([:jido, :eval]),
              enable_real_time_events: Zoi.boolean() |> Zoi.default(true)
            },
            coerce: true
          )

  @typedoc "Execution configuration for evaluation runs"
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc """
  Builds a run configuration from a map, validating with Zoi.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ %{}) when is_map(attrs), do: Zoi.parse(@schema, attrs)

  @doc """
  Builds a run configuration from a map or raises on validation errors.
  """
  @spec new!(map()) :: t()
  def new!(attrs \\ %{}) when is_map(attrs) do
    case new(attrs) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "Invalid #{inspect(__MODULE__)}: #{inspect(reason)}"
    end
  end
end
