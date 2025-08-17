defmodule Jido.Eval.Engine.Worker do
  @moduledoc """
  Individual sample processor for evaluation metrics.

  GenServer-based worker that applies metrics to individual samples,
  handles worker-level errors without crashing the evaluation,
  and reports progress back to the coordinator.

  ## Architecture

  - **Sample Processing**: Applies multiple metrics to a single sample
  - **Error Isolation**: Worker failures don't impact other samples
  - **Middleware Support**: Wraps metric calls with configured middleware
  - **Telemetry Integration**: Emits detailed metric-level events
  - **Timeout Handling**: Respects individual metric timeouts

  ## State Management

  Workers maintain:
  - Current sample being processed
  - Metric execution context
  - Timing and latency tracking
  - Error state and recovery

  ## Examples

      # Started by WorkerPool - not typically called directly
      {:ok, pid} = Jido.Eval.Engine.Worker.start_link([
        run_id: "eval_001",
        metrics: [:faithfulness],
        config: config,
        pool_pid: pool_pid
      ])
      
      GenServer.cast(pid, {:evaluate_sample, sample})
  """

  use GenServer
  require Logger

  alias Jido.Eval.Metric

  defstruct [
    :run_id,
    :metrics,
    :config,
    :pool_pid,
    :timeout,
    :current_sample,
    :start_time,
    :cancelled
  ]

  @doc """
  Start a worker process for sample evaluation.

  ## Parameters

  - `opts` - Worker options:
    - `:run_id` - Evaluation run identifier (required)
    - `:metrics` - List of metrics to apply (required)
    - `:config` - Evaluation configuration (required)
    - `:pool_pid` - Worker pool process ID (required)
    - `:timeout` - Worker timeout in milliseconds

  ## Returns

  - `{:ok, pid}` - Worker started successfully
  - `{:error, reason}` - Failed to start worker
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    metrics = Keyword.fetch!(opts, :metrics)
    config = Keyword.fetch!(opts, :config)
    pool_pid = Keyword.fetch!(opts, :pool_pid)
    timeout = Keyword.get(opts, :timeout, 30_000)

    state = %__MODULE__{
      run_id: run_id,
      metrics: metrics,
      config: config,
      pool_pid: pool_pid,
      timeout: timeout,
      current_sample: nil,
      start_time: nil,
      cancelled: false
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:evaluate_sample, sample}, state) do
    if state.cancelled do
      {:noreply, state}
    else
      # Start sample processing
      start_time = System.monotonic_time(:millisecond)
      updated_state = %{state | current_sample: sample, start_time: start_time}

      # Process sample asynchronously to avoid blocking
      task = Task.async(fn -> process_sample(sample, updated_state) end)

      # Set timeout for sample processing
      Process.send_after(self(), {:timeout, task.ref}, state.timeout)

      {:noreply, %{updated_state | current_sample: {sample, task}}}
    end
  end

  @impl true
  def handle_cast(:cancel, state) do
    Logger.debug("Cancelling worker for run #{state.run_id}")

    # Cancel current processing if active
    state =
      case state.current_sample do
        {_sample, %Task{} = task} ->
          Task.shutdown(task, :brutal_kill)
          %{state | current_sample: nil}

        _ ->
          state
      end

    {:noreply, %{state | cancelled: true}}
  end

  @impl true
  def handle_info({:timeout, task_ref}, state) do
    case state.current_sample do
      {sample, %Task{ref: ^task_ref}} ->
        Logger.warning(
          "Worker timeout processing sample #{sample.id || "unknown"} in run #{state.run_id}"
        )

        # Kill the task
        Task.shutdown(elem(state.current_sample, 1), :brutal_kill)

        # Report timeout error
        error_result = %{
          sample_id: sample.id,
          scores: %{},
          latency_ms: System.monotonic_time(:millisecond) - state.start_time,
          error: "Worker timeout after #{state.timeout}ms",
          tags: sample.tags || %{},
          metadata: %{timeout: true}
        }

        send(state.pool_pid, {:worker_result, self(), error_result})

        {:noreply, %{state | current_sample: nil, start_time: nil}}

      _ ->
        # Stale timeout message, ignore
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Task completed successfully
    case state.current_sample do
      {_sample, %Task{ref: ^ref}} ->
        # Process and send result
        Process.demonitor(ref, [:flush])
        send(state.pool_pid, {:worker_result, self(), result})

        {:noreply, %{state | current_sample: nil, start_time: nil}}

      _ ->
        # Unexpected result, ignore
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # Task failed or was killed
    case state.current_sample do
      {sample, %Task{ref: ^ref}} ->
        Logger.warning(
          "Worker task failed for sample #{sample.id || "unknown"}: #{inspect(reason)}"
        )

        error_result = %{
          sample_id: sample.id,
          scores: %{},
          latency_ms:
            if(state.start_time,
              do: System.monotonic_time(:millisecond) - state.start_time,
              else: 0
            ),
          error: "Worker task failed: #{inspect(reason)}",
          tags: sample.tags || %{},
          metadata: %{task_failure: true}
        }

        send(state.pool_pid, {:worker_result, self(), error_result})

        {:noreply, %{state | current_sample: nil, start_time: nil}}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Private implementation functions

  defp process_sample(sample, state) do
    start_time = System.monotonic_time(:millisecond)

    try do
      # Validate sample for all metrics
      validation_results = validate_sample_for_metrics(sample, state.metrics)

      case validation_results do
        :ok ->
          # Process each metric
          scores = evaluate_metrics(sample, state.metrics, state.config, state.run_id)

          %{
            sample_id: sample.id,
            scores: scores,
            latency_ms: System.monotonic_time(:millisecond) - start_time,
            error: nil,
            tags: sample.tags || %{},
            metadata: %{}
          }

        {:error, reason} ->
          %{
            sample_id: sample.id,
            scores: %{},
            latency_ms: System.monotonic_time(:millisecond) - start_time,
            error: "Sample validation failed: #{inspect(reason)}",
            tags: sample.tags || %{},
            metadata: %{validation_error: true}
          }
      end
    rescue
      error ->
        %{
          sample_id: sample.id || "unknown",
          scores: %{},
          latency_ms: System.monotonic_time(:millisecond) - start_time,
          error: "Unexpected worker error: #{inspect(error)}",
          tags: sample.tags || %{},
          metadata: %{unexpected_error: true}
        }
    end
  end

  defp validate_sample_for_metrics(sample, metrics) do
    # Get metric modules from registry
    metric_modules =
      metrics
      |> Enum.map(fn metric_name ->
        case Jido.Eval.ComponentRegistry.lookup(:metric, metric_name) do
          {:ok, module} -> {metric_name, module}
          {:error, _} -> {:error, {:unknown_metric, metric_name}}
        end
      end)

    # Check for unknown metrics
    case Enum.find(metric_modules, &match?({:error, _}, &1)) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        # Validate sample for each metric
        metric_modules
        |> Enum.map(fn {metric_name, module} ->
          {metric_name, Metric.validate_sample(sample, module)}
        end)
        |> Enum.find(fn {_name, result} -> match?({:error, _}, result) end)
        |> case do
          {metric_name, {:error, reason}} -> {:error, {metric_name, reason}}
          nil -> :ok
        end
    end
  end

  defp evaluate_metrics(sample, metrics, config, run_id) do
    metrics
    |> Enum.map(fn metric_name ->
      {metric_name, evaluate_single_metric(sample, metric_name, config, run_id)}
    end)
    |> Enum.reduce(%{}, fn {metric_name, result}, acc ->
      case result do
        {:ok, score} ->
          Map.put(acc, metric_name, score)

        {:error, reason} ->
          Logger.warning("Metric #{metric_name} failed: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp evaluate_single_metric(sample, metric_name, config, run_id) do
    # Get metric module from registry
    with {:ok, metric_module} <- Jido.Eval.ComponentRegistry.lookup(:metric, metric_name) do
      metric_start_time = System.monotonic_time(:millisecond)

      # Emit metric start telemetry
      :telemetry.execute(
        [:jido, :eval, :metric, :start],
        %{},
        %{
          run_id: run_id,
          sample_id: sample.id,
          metric: metric_name
        }
      )

      # Execute metric with middleware
      result =
        execute_with_middleware(
          config.middleware,
          fn -> metric_module.evaluate(sample, config, []) end,
          %{metric: metric_name, sample: sample, config: config}
        )

      # Calculate metric latency
      metric_duration = System.monotonic_time(:millisecond) - metric_start_time

      # Emit metric completion telemetry
      metric_measurements =
        case result do
          {:ok, score} -> %{duration_ms: metric_duration, score: score}
          {:error, _} -> %{duration_ms: metric_duration}
        end

      :telemetry.execute(
        [:jido, :eval, :metric, :stop],
        metric_measurements,
        %{
          run_id: run_id,
          sample_id: sample.id,
          metric: metric_name,
          success: match?({:ok, _}, result)
        }
      )

      result
    end
  end

  defp execute_with_middleware([], fun, _context), do: fun.()

  defp execute_with_middleware([middleware | rest], fun, context) do
    middleware.call(context, fn -> execute_with_middleware(rest, fun, context) end)
  rescue
    error ->
      Logger.error("Middleware #{middleware} failed: #{inspect(error)}")
      execute_with_middleware(rest, fun, context)
  end
end
