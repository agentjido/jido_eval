defmodule Jido.Eval.Engine do
  @moduledoc """
  Main execution coordinator for Jido Eval.

  Provides both synchronous and asynchronous evaluation execution with
  OTP supervision, worker pools, and real-time monitoring capabilities.

  ## Architecture

  - **Synchronous Mode**: Direct evaluation with blocking execution
  - **Asynchronous Mode**: Supervised evaluation with progress tracking
  - **Worker Pools**: Bounded concurrency with fault isolation
  - **Registry Integration**: Real-time progress querying
  - **Telemetry Events**: Comprehensive monitoring support

  ## Examples

      # Synchronous evaluation
      {:ok, result} = Jido.Eval.Engine.evaluate_sync(dataset, config)

      # Asynchronous evaluation with monitoring
      {:ok, run_id} = Jido.Eval.Engine.start_evaluation(dataset, config)
      
      # Check progress
      {:ok, progress} = Jido.Eval.Engine.get_progress(run_id)

      # Wait for completion
      {:ok, result} = Jido.Eval.Engine.await_result(run_id, 30_000)
  """

  require Logger

  alias Jido.Eval.{Config, Result, Dataset}
  alias Jido.Eval.Engine.WorkerPool

  @registry_name Jido.Eval.Engine.Registry
  @supervisor_name Jido.Eval.Engine.Supervisor

  @doc """
  Start an asynchronous evaluation run with supervision.

  Creates a supervised worker pool and starts evaluation in the background.
  Returns immediately with a run ID for progress tracking.

  ## Parameters

  - `dataset` - Dataset implementing the Dataset protocol
  - `config` - Evaluation configuration
  - `metrics` - List of metric atoms or modules
  - `opts` - Additional options

  ## Returns

  - `{:ok, run_id}` - Evaluation started successfully
  - `{:error, reason}` - Failed to start evaluation

  ## Examples

      {:ok, run_id} = Jido.Eval.Engine.start_evaluation(
        dataset,
        %Jido.Eval.Config{},
        [:faithfulness, :context_precision]
      )

      # Monitor progress
      :telemetry.attach([:jido, :eval, :progress], handler_fn, nil)
  """
  @spec start_evaluation(Dataset.t(), Config.t(), [atom()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def start_evaluation(dataset, config, metrics, opts \\ []) do
    with {:ok, config} <- Config.ensure_run_id(config),
         {:ok, _pid} <- start_worker_pool(config, dataset, metrics, opts) do
      {:ok, config.run_id}
    end
  end

  @doc """
  Execute evaluation synchronously.

  Blocks until evaluation completes and returns the final result.
  Uses the same worker pool architecture but waits for completion.

  ## Parameters

  - `dataset` - Dataset implementing the Dataset protocol
  - `config` - Evaluation configuration
  - `metrics` - List of metric atoms or modules
  - `opts` - Additional options (timeout, etc.)

  ## Returns

  - `{:ok, result}` - Evaluation completed successfully
  - `{:error, reason}` - Evaluation failed

  ## Examples

      {:ok, result} = Jido.Eval.Engine.evaluate_sync(
        dataset,
        config,
        [:faithfulness, :context_precision],
        timeout: 30_000
      )

      IO.inspect(result.summary_stats)
  """
  @spec evaluate_sync(Dataset.t(), Config.t(), [atom()], keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def evaluate_sync(dataset, config, metrics, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, config.run_config.timeout)

    with {:ok, run_id} <- start_evaluation(dataset, config, metrics, opts),
         {:ok, result} <- await_result(run_id, timeout) do
      {:ok, result}
    end
  end

  @doc """
  Get current progress for a running evaluation.

  ## Parameters

  - `run_id` - Evaluation run identifier

  ## Returns

  - `{:ok, progress}` - Current progress information
  - `{:error, :not_found}` - Run not found or completed
  - `{:error, reason}` - Other error

  ## Examples

      {:ok, current_progress} = Jido.Eval.Engine.get_progress(run_id)
      IO.inspect(current_progress)
  """
  @spec get_progress(String.t()) :: {:ok, map()} | {:error, term()}
  def get_progress(run_id) do
    case Registry.lookup(@registry_name, run_id) do
      [{pid, _}] when is_pid(pid) ->
        try do
          progress = GenServer.call(pid, :get_progress, 5_000)
          {:ok, progress}
        catch
          :exit, _ -> {:error, :process_unavailable}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Wait for evaluation result with timeout.

  ## Parameters

  - `run_id` - Evaluation run identifier
  - `timeout` - Maximum wait time in milliseconds

  ## Returns

  - `{:ok, result}` - Evaluation completed
  - `{:error, :timeout}` - Evaluation timed out
  - `{:error, reason}` - Other error

  ## Examples

      {:ok, result} = Jido.Eval.Engine.await_result(run_id, 30_000)
  """
  @spec await_result(String.t(), non_neg_integer()) :: {:ok, Result.t()} | {:error, term()}
  def await_result(run_id, timeout) do
    case Registry.lookup(@registry_name, run_id) do
      [{pid, _}] when is_pid(pid) ->
        try do
          result = GenServer.call(pid, :await_result, timeout)
          {:ok, result}
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
          :exit, _ -> {:error, :process_unavailable}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Cancel a running evaluation.

  ## Parameters

  - `run_id` - Evaluation run identifier

  ## Returns

  - `:ok` - Cancellation initiated
  - `{:error, :not_found}` - Run not found

  ## Examples

      :ok = Jido.Eval.Engine.cancel_evaluation(run_id)
  """
  @spec cancel_evaluation(String.t()) :: :ok | {:error, term()}
  def cancel_evaluation(run_id) do
    case Registry.lookup(@registry_name, run_id) do
      [{pid, _}] when is_pid(pid) ->
        GenServer.cast(pid, :cancel)
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  List currently running evaluations.

  ## Returns

  - `{:ok, runs}` - List of active run information

  ## Examples

      {:ok, runs} = Jido.Eval.Engine.list_running()
      IO.inspect(length(runs))
  """
  @spec list_running() :: {:ok, [map()]}
  def list_running do
    runs =
      Registry.select(@registry_name, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.map(fn {run_id, pid} ->
        try do
          progress = GenServer.call(pid, :get_progress, 1_000)
          %{run_id: run_id, pid: pid, progress: progress}
        catch
          :exit, _ -> %{run_id: run_id, pid: pid, progress: :unavailable}
        end
      end)

    {:ok, runs}
  end

  # Private implementation functions

  defp start_worker_pool(config, dataset, metrics, opts) do
    child_spec = {
      WorkerPool,
      [
        config: config,
        dataset: dataset,
        metrics: metrics,
        opts: opts,
        registry: @registry_name
      ]
    }

    case DynamicSupervisor.start_child(@supervisor_name, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Start the engine components.

  Called during application startup to initialize the registry and supervisor.

  ## Returns

  - `:ok` - Engine started successfully
  - `{:error, reason}` - Failed to start engine
  """
  @spec start() :: :ok | {:error, term()}
  def start do
    with :ok <- start_registry(),
         {:ok, _pid} <- start_supervisor() do
      :ok
    end
  end

  defp start_registry do
    case Registry.start_link(
           keys: :unique,
           name: @registry_name,
           partitions: System.schedulers_online()
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_supervisor do
    case DynamicSupervisor.start_link(
           strategy: :one_for_one,
           name: @supervisor_name,
           max_children: 100,
           max_seconds: 60,
           max_restarts: 10
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end
end
