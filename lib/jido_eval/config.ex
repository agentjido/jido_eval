defmodule Jido.Eval.Config do
  @moduledoc """
  Runtime configuration for Jido Eval.

  Central configuration struct that defines evaluation behavior including
  reporting, storage, broadcasting, processing, and middleware components.

  ## Examples

      iex> config = %Jido.Eval.Config{}
      iex> config.run_config.max_workers
      16
      
      iex> config = %Jido.Eval.Config{
      ...>   run_config: %Jido.Eval.RunConfig{max_workers: 8},
      ...>   tags: %{"experiment" => "test_run"}
      ...> }
      iex> config.tags
      %{"experiment" => "test_run"}
  """

  @default_judge_model "openai:gpt-4o"

  @schema Zoi.struct(
            __MODULE__,
            %{
              run_id: Zoi.string() |> Zoi.nullable() |> Zoi.default(nil),
              run_config: Zoi.any() |> Zoi.default(%Jido.Eval.RunConfig{}),
              judge_model: Zoi.any() |> Zoi.default(@default_judge_model),
              judge_opts: Zoi.list(Zoi.any()) |> Zoi.default([]),
              # Deprecated compatibility fields. Use :judge_model and :judge_opts for new code.
              model_spec: Zoi.any() |> Zoi.default(@default_judge_model),
              reporters: Zoi.list(Zoi.any()) |> Zoi.default([{Jido.Eval.Reporter.Console, []}]),
              stores: Zoi.list(Zoi.any()) |> Zoi.default([]),
              broadcasters:
                Zoi.list(Zoi.any())
                |> Zoi.default([{Jido.Eval.Broadcaster.Telemetry, [prefix: [:jido, :eval]]}]),
              processors: Zoi.list(Zoi.any()) |> Zoi.default([]),
              middleware: Zoi.list(Zoi.any()) |> Zoi.default([Jido.Eval.Middleware.Tracing]),
              # Deprecated compatibility field. Use :judge_opts for new code.
              llm_opts: Zoi.list(Zoi.any()) |> Zoi.default([]),
              tags: Zoi.map(Zoi.string(), Zoi.string()) |> Zoi.default(%{}),
              notes: Zoi.string() |> Zoi.default("")
            },
            coerce: true
          )

  @typedoc "Runtime configuration for Jido Eval"
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc """
  Builds a runtime configuration from a map, validating with Zoi.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ %{}) when is_map(attrs) do
    case Zoi.parse(@schema, attrs) do
      {:ok, config} -> {:ok, normalize(config)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Builds a runtime configuration from a map or raises on validation errors.
  """
  @spec new!(map()) :: t()
  def new!(attrs \\ %{}) when is_map(attrs) do
    case new(attrs) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "Invalid #{inspect(__MODULE__)}: #{inspect(reason)}"
    end
  end

  @doc """
  Returns the effective judge model, honoring legacy `model_spec` configs.
  """
  @spec effective_judge_model(t()) :: String.t() | LLMDB.Model.t()
  def effective_judge_model(%__MODULE__{} = config) do
    cond do
      not is_nil(config.judge_model) and config.judge_model != @default_judge_model ->
        config.judge_model

      not is_nil(config.model_spec) and config.model_spec != @default_judge_model ->
        config.model_spec

      not is_nil(config.judge_model) ->
        config.judge_model

      not is_nil(config.model_spec) ->
        config.model_spec

      true ->
        @default_judge_model
    end
  end

  @doc """
  Returns the effective judge options, honoring legacy `llm_opts` configs.
  """
  @spec effective_judge_opts(t()) :: keyword()
  def effective_judge_opts(%__MODULE__{} = config) do
    case config.judge_opts do
      opts when is_list(opts) and opts != [] -> opts
      _ -> config.llm_opts || []
    end
  end

  @doc """
  Normalizes compatibility fields so old and new config names stay in sync.
  """
  @spec normalize(t()) :: t()
  def normalize(%__MODULE__{} = config) do
    judge_model = effective_judge_model(config)
    judge_opts = effective_judge_opts(config)

    %{
      config
      | judge_model: judge_model,
        model_spec: judge_model,
        judge_opts: judge_opts,
        llm_opts: judge_opts
    }
  end

  @doc """
  Generates a new UUID for run_id if not set.

  ## Examples

      iex> config = %Jido.Eval.Config{run_id: "test-id"}
      iex> {:ok, updated} = Jido.Eval.Config.ensure_run_id(config)
      iex> updated.run_id
      "test-id"
      
      iex> config = %Jido.Eval.Config{run_id: nil}
      iex> {:ok, updated} = Jido.Eval.Config.ensure_run_id(config)
      iex> is_binary(updated.run_id)
      true
  """
  @spec ensure_run_id(t()) :: {:ok, t()}
  def ensure_run_id(%__MODULE__{run_id: nil} = config) do
    config = normalize(config)
    run_id = generate_uuid()
    run_config = %{config.run_config | run_id: run_id}
    {:ok, %{config | run_id: run_id, run_config: run_config}}
  end

  def ensure_run_id(%__MODULE__{run_id: run_id} = config) when is_binary(run_id) do
    config = normalize(config)
    run_config = %{config.run_config | run_id: run_id}
    {:ok, %{config | run_config: run_config}}
  end

  defp generate_uuid do
    Uniq.UUID.uuid7()
  end
end
