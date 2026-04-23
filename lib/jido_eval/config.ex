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

  use TypedStruct

  @default_judge_model "openai:gpt-4o"

  typedstruct do
    @typedoc "Runtime configuration for Jido Eval"

    field(:run_id, String.t() | nil, default: nil)
    field(:run_config, Jido.Eval.RunConfig.t(), default: %Jido.Eval.RunConfig{})
    field(:judge_model, String.t() | LLMDB.Model.t(), default: @default_judge_model)
    field(:judge_opts, keyword(), default: [])
    # Deprecated compatibility fields. Use :judge_model and :judge_opts for new code.
    field(:model_spec, String.t() | LLMDB.Model.t(), default: "openai:gpt-4o")
    field(:reporters, [{module(), keyword()}], default: [{Jido.Eval.Reporter.Console, []}])
    field(:stores, [{module(), keyword()}], default: [])

    field(:broadcasters, [{module(), keyword()}],
      default: [{Jido.Eval.Broadcaster.Telemetry, [prefix: [:jido, :eval]]}]
    )

    field(:processors, [{module(), :pre | :post, keyword()}], default: [])
    field(:middleware, [module()], default: [Jido.Eval.Middleware.Tracing])
    # Deprecated compatibility field. Use :judge_opts for new code.
    field(:llm_opts, keyword(), default: [])
    field(:tags, %{String.t() => String.t()}, default: %{})
    field(:notes, String.t(), default: "")
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
