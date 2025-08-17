defmodule Jido.Eval.Engine.WorkerPool do
  @moduledoc """
  Concurrent processing manager for evaluation samples.

  Manages a pool of workers with bounded concurrency, load balancing,
  backpressure handling, and progress tracking. Coordinates the evaluation
  of individual samples across multiple workers.

  ## Architecture

  - **Worker Management**: Spawns and monitors worker processes
  - **Load Balancing**: Distributes samples across available workers
  - **Backpressure**: Queues samples when all workers are busy
  - **Progress Tracking**: Aggregates results and tracks completion
  - **Fault Tolerance**: Individual worker failures don't impact evaluation

  ## State Management

  The worker pool maintains:
  - Active worker processes and their current assignments
  - Pending sample queue for backpressure handling
  - Aggregated results and progress statistics
  - Component execution for reporters, stores, broadcasters

  ## Examples

      # Started by Engine - not typically called directly
      {:ok, pid} = Jido.Eval.Engine.WorkerPool.start_link([
        config: config,
        dataset: dataset, 
        metrics: [:faithfulness],
        opts: []
      ])
  """

  use GenServer
  require Logger

  alias Jido.Eval.{Result, Dataset}
  alias Jido.Eval.Engine.Worker

  @default_opts [
    worker_timeout: 30_000,
    queue_timeout: 5_000
  ]

  defstruct [
    :config,
    :dataset,
    :metrics,
    :opts,
    :registry,
    :result,
    :sample_stream,
    :workers,
    :pending_queue,
    :completed_count,
    :total_count,
    :start_time,
    :cancelled,
    :awaiting_pids
  ]

  @doc """
  Start a worker pool for evaluation execution.

  ## Parameters

  - `opts` - Worker pool options:
    - `:config` - Evaluation configuration (required)
    - `:dataset` - Dataset to evaluate (required)  
    - `:metrics` - List of metrics to apply (required)
    - `:opts` - Additional evaluation options
    - `:registry` - Registry name for run tracking

  ## Returns

  - `{:ok, pid}` - Worker pool started successfully
  - `{:error, reason}` - Failed to start worker pool
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(config.run_id, opts[:registry]))
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    dataset = Keyword.fetch!(opts, :dataset)
    metrics = Keyword.fetch!(opts, :metrics)
    registry = opts[:registry]

    # Validate metrics exist
    case validate_metrics(metrics) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Invalid metrics for run #{config.run_id}: #{inspect(reason)}")
        {:stop, {:invalid_metrics, reason}}
    end

    # Get dataset stream and count
    sample_stream = Dataset.to_stream(dataset)
    total_count = Dataset.count(dataset)

    # Initialize result structure
    result = Result.new(config.run_id, config)

    # Emit telemetry for run start
    emit_telemetry(:run, :start, %{total: total_count}, %{
      run_id: config.run_id,
      dataset_type: Dataset.sample_type(dataset),
      metrics: metrics,
      config: config
    })

    # Execute pre-processors
    execute_processors(config.processors, :pre, %{
      run_id: config.run_id,
      dataset: dataset,
      metrics: metrics,
      total_count: total_count
    })

    state = %__MODULE__{
      config: config,
      dataset: dataset,
      metrics: metrics,
      opts: Keyword.merge(@default_opts, opts[:opts] || []),
      registry: registry,
      result: result,
      sample_stream: sample_stream,
      workers: %{},
      pending_queue: :queue.new(),
      completed_count: 0,
      total_count: total_count,
      start_time: System.monotonic_time(:millisecond),
      cancelled: false,
      awaiting_pids: []
    }

    # Start workers and begin processing
    {:ok, state, {:continue, :start_workers}}
  end

  @impl true
  def handle_continue(:start_workers, state) do
    max_workers = state.config.run_config.max_workers

    # Start initial batch of workers
    workers = start_workers(max_workers, state)
    updated_state = %{state | workers: workers}

    # Begin processing samples
    {:noreply, process_next_samples(updated_state)}
  end

  @impl true
  def handle_call(:get_progress, _from, state) do
    progress = %{
      run_id: state.config.run_id,
      total: state.total_count,
      completed: state.completed_count,
      pending: :queue.len(state.pending_queue),
      active_workers: map_size(state.workers),
      start_time: state.start_time,
      elapsed_ms: System.monotonic_time(:millisecond) - state.start_time,
      cancelled: state.cancelled
    }

    {:reply, progress, state}
  end

  @impl true
  def handle_call(:await_result, from, state) do
    if evaluation_complete?(state) do
      result = finalize_result(state)
      {:reply, result, state}
    else
      # Add caller to waiting list
      updated_state = %{state | awaiting_pids: [from | state.awaiting_pids]}
      {:noreply, updated_state}
    end
  end

  @impl true
  def handle_cast(:cancel, state) do
    Logger.info("Cancelling evaluation run #{state.config.run_id}")

    # Cancel all active workers
    Enum.each(state.workers, fn {worker_pid, _worker_state} ->
      GenServer.cast(worker_pid, :cancel)
    end)

    updated_state = %{state | cancelled: true}

    # Notify any awaiting processes
    notify_awaiting_processes(updated_state, {:error, :cancelled})

    {:noreply, %{updated_state | awaiting_pids: []}}
  end

  @impl true
  def handle_info({:worker_result, worker_pid, sample_result}, state) do
    # Remove worker from active set
    updated_workers = Map.delete(state.workers, worker_pid)

    # Add sample result to aggregated results
    updated_result = Result.add_sample_result(state.result, sample_result)
    updated_completed = state.completed_count + 1

    # Emit progress telemetry
    emit_telemetry(
      :progress,
      %{
        completed: updated_completed,
        total: state.total_count
      },
      %{
        run_id: state.config.run_id,
        progress_pct: updated_completed / state.total_count * 100
      }
    )

    # Emit sample completion telemetry
    emit_telemetry(:sample, :stop, sample_result.latency_ms || 0, %{
      run_id: state.config.run_id,
      sample_id: sample_result.sample_id,
      scores: sample_result.scores,
      error: sample_result.error
    })

    updated_state = %{
      state
      | workers: updated_workers,
        result: updated_result,
        completed_count: updated_completed
    }

    # Execute reporters for this sample
    execute_reporters(state.config.reporters, :sample, sample_result)

    # Execute broadcasters for progress
    execute_broadcasters(state.config.broadcasters, :progress, %{
      completed: updated_completed,
      total: state.total_count,
      sample_result: sample_result
    })

    # Check if evaluation is complete
    if evaluation_complete?(updated_state) do
      finalized_result = finalize_result(updated_state)
      notify_awaiting_processes(updated_state, finalized_result)

      # Schedule cleanup
      Process.send_after(self(), :cleanup, 1_000)

      {:noreply, %{updated_state | awaiting_pids: []}}
    else
      # Continue processing with next samples
      {:noreply, process_next_samples(updated_state)}
    end
  end

  @impl true
  def handle_info({:worker_error, worker_pid, error}, state) do
    Logger.warning("Worker #{inspect(worker_pid)} failed: #{inspect(error)}")

    # Remove failed worker
    updated_workers = Map.delete(state.workers, worker_pid)

    # Start replacement worker if not cancelled and samples remain
    workers =
      if not state.cancelled and samples_remaining?(state) do
        case start_worker(state) do
          {:ok, new_worker_pid} ->
            Map.put(updated_workers, new_worker_pid, :idle)

          {:error, reason} ->
            Logger.error("Failed to start replacement worker: #{inspect(reason)}")
            updated_workers
        end
      else
        updated_workers
      end

    updated_state = %{state | workers: workers}

    {:noreply, process_next_samples(updated_state)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, worker_pid, reason}, state) do
    Logger.debug("Worker #{inspect(worker_pid)} terminated: #{inspect(reason)}")

    # Remove from workers map
    updated_workers = Map.delete(state.workers, worker_pid)

    # Start replacement if needed
    workers =
      if not state.cancelled and samples_remaining?(state) do
        case start_worker(state) do
          {:ok, new_worker_pid} ->
            Map.put(updated_workers, new_worker_pid, :idle)

          {:error, _reason} ->
            updated_workers
        end
      else
        updated_workers
      end

    updated_state = %{state | workers: workers}

    {:noreply, process_next_samples(updated_state)}
  end

  @impl true
  def handle_info(:cleanup, state) do
    Logger.debug("Cleaning up worker pool for run #{state.config.run_id}")

    # Stop all remaining workers
    Enum.each(state.workers, fn {worker_pid, _} ->
      GenServer.stop(worker_pid, :normal)
    end)

    {:stop, :normal, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Private helper functions

  defp via_tuple(run_id, nil), do: {:global, {__MODULE__, run_id}}
  defp via_tuple(run_id, registry), do: {:via, Registry, {registry, run_id}}

  defp validate_metrics(metrics) do
    invalid_metrics =
      metrics
      |> Enum.reject(fn metric ->
        case Jido.Eval.ComponentRegistry.lookup(:metric, metric) do
          {:ok, _module} -> true
          {:error, _} -> false
        end
      end)

    case invalid_metrics do
      [] -> :ok
      metrics -> {:error, {:unknown_metrics, metrics}}
    end
  end

  defp start_workers(count, state) do
    1..count
    |> Enum.reduce(%{}, fn _, acc ->
      case start_worker(state) do
        {:ok, worker_pid} ->
          Map.put(acc, worker_pid, :idle)

        {:error, reason} ->
          Logger.error("Failed to start worker: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp start_worker(state) do
    worker_opts = [
      run_id: state.config.run_id,
      metrics: state.metrics,
      config: state.config,
      pool_pid: self(),
      timeout: state.opts[:worker_timeout]
    ]

    case Worker.start_link(worker_opts) do
      {:ok, pid} ->
        Process.monitor(pid)
        {:ok, pid}

      error ->
        error
    end
  end

  defp process_next_samples(state) do
    # Find idle workers
    idle_workers =
      state.workers
      |> Enum.filter(fn {_pid, worker_state} -> worker_state == :idle end)
      |> Enum.map(fn {pid, _state} -> pid end)

    # Assign samples to idle workers
    updated_state = assign_samples_to_workers(state, idle_workers)

    updated_state
  end

  defp assign_samples_to_workers(state, []), do: state

  defp assign_samples_to_workers(state, [worker_pid | remaining_workers]) do
    case get_next_sample(state) do
      {:ok, sample, updated_state} ->
        # Assign sample to worker
        GenServer.cast(worker_pid, {:evaluate_sample, sample})

        # Update worker state to busy
        updated_workers = Map.put(updated_state.workers, worker_pid, :busy)

        # Emit sample start telemetry
        emit_telemetry(:sample, :start, %{}, %{
          run_id: state.config.run_id,
          sample_id: sample.id,
          metrics: state.metrics
        })

        # Continue with remaining workers
        assign_samples_to_workers(
          %{updated_state | workers: updated_workers},
          remaining_workers
        )

      {:empty, updated_state} ->
        # No more samples available
        updated_state
    end
  end

  defp get_next_sample(state) do
    # Try to get from pending queue first
    case :queue.out(state.pending_queue) do
      {{:value, sample}, updated_queue} ->
        {:ok, sample, %{state | pending_queue: updated_queue}}

      {:empty, _queue} ->
        # Try to get from stream
        case Enum.take(state.sample_stream, 1) do
          [sample] ->
            # Update stream to skip this sample
            updated_stream = Stream.drop(state.sample_stream, 1)
            {:ok, sample, %{state | sample_stream: updated_stream}}

          [] ->
            {:empty, state}
        end
    end
  end

  defp evaluation_complete?(state) do
    # All samples processed and no active workers
    state.completed_count >= state.total_count or
      (samples_remaining?(state) == false and map_size(state.workers) == 0) or
      state.cancelled
  end

  defp samples_remaining?(state) do
    state.completed_count < state.total_count and not state.cancelled
  end

  defp finalize_result(state) do
    finalized_result = Result.finalize(state.result)

    # Execute post-processors
    execute_processors(state.config.processors, :post, finalized_result)

    # Execute summary reporters
    execute_reporters(state.config.reporters, :summary, finalized_result)

    # Execute stores
    execute_stores(state.config.stores, finalized_result)

    # Execute final broadcasters
    execute_broadcasters(state.config.broadcasters, :completed, finalized_result)

    # Emit run completion telemetry
    emit_telemetry(
      :run,
      :stop,
      %{
        duration_ms: finalized_result.duration_ms || 0,
        total: finalized_result.sample_count,
        completed: finalized_result.completed_count,
        errors: finalized_result.error_count
      },
      %{
        run_id: state.config.run_id,
        result: finalized_result
      }
    )

    finalized_result
  end

  defp notify_awaiting_processes(state, result) do
    Enum.each(state.awaiting_pids, fn from ->
      GenServer.reply(from, result)
    end)
  end

  # Component execution functions

  defp execute_processors(processors, phase, data) do
    processors
    |> Enum.filter(fn {_module, processor_phase, _opts} -> processor_phase == phase end)
    |> Enum.each(fn {module, _phase, opts} ->
      try do
        module.process(data, opts)
      rescue
        error -> Logger.error("Processor #{module} failed: #{inspect(error)}")
      end
    end)
  end

  defp execute_reporters(reporters, event, data) do
    Enum.each(reporters, fn {module, opts} ->
      try do
        module.report(event, data, opts)
      rescue
        error -> Logger.error("Reporter #{module} failed: #{inspect(error)}")
      end
    end)
  end

  defp execute_stores(stores, result) do
    Enum.each(stores, fn {module, opts} ->
      try do
        module.store(result, opts)
      rescue
        error -> Logger.error("Store #{module} failed: #{inspect(error)}")
      end
    end)
  end

  defp execute_broadcasters(broadcasters, event, data) do
    Enum.each(broadcasters, fn {module, opts} ->
      try do
        module.publish(event, data, opts)
      rescue
        error -> Logger.error("Broadcaster #{module} failed: #{inspect(error)}")
      end
    end)
  end

  defp emit_telemetry(
         event_name,
         measurements_or_event,
         metadata_or_measurements,
         metadata \\ %{}
       )

  defp emit_telemetry(event_name, event_type, measurements, metadata)
       when event_type in [:start, :stop] do
    :telemetry.execute(
      [:jido, :eval, event_name, event_type],
      measurements,
      metadata
    )
  end

  defp emit_telemetry(event_name, measurements, metadata, _) do
    :telemetry.execute(
      [:jido, :eval, event_name],
      measurements,
      metadata
    )
  end
end
