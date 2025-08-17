defmodule Jido.Eval.Engine.Supervisor do
  @moduledoc """
  OTP supervisor for evaluation runs with fault isolation.

  Provides dynamic supervision for worker pools with proper lifecycle
  management, fault isolation, and clean shutdown capabilities.

  ## Architecture

  - **Dynamic Supervision**: Creates worker pools on demand
  - **Fault Isolation**: Individual run failures don't impact other runs
  - **Resource Management**: Limits concurrent evaluations
  - **Clean Shutdown**: Properly terminates evaluations on shutdown
  - **Process Registry**: Integrates with Registry for run tracking

  ## Supervision Strategy

  Uses `:one_for_one` strategy where each worker pool is supervised
  independently. Failed worker pools are restarted according to
  configured restart intensity limits.

  ## Examples

      # Start supervisor (typically done in application tree)
      {:ok, pid} = Jido.Eval.Engine.Supervisor.start_link([])

      # Start supervised worker pool
      spec = {Jido.Eval.Engine.WorkerPool, [config: config, dataset: dataset]}
      {:ok, worker_pid} = DynamicSupervisor.start_child(pid, spec)
  """

  use DynamicSupervisor
  require Logger

  @name __MODULE__

  @doc """
  Start the evaluation engine supervisor.

  ## Parameters

  - `opts` - Supervisor options:
    - `:name` - Supervisor name (defaults to module name)
    - `:max_children` - Maximum concurrent evaluations
    - `:max_seconds` - Restart intensity window
    - `:max_restarts` - Maximum restarts in window

  ## Returns

  - `{:ok, pid}` - Supervisor started successfully
  - `{:error, reason}` - Failed to start supervisor

  ## Examples

      {:ok, pid} = Jido.Eval.Engine.Supervisor.start_link()
      
      {:ok, pid} = Jido.Eval.Engine.Supervisor.start_link([
        max_children: 50,
        max_restarts: 5,
        max_seconds: 30
      ])
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Start a supervised worker pool for evaluation.

  ## Parameters

  - `supervisor` - Supervisor process or name
  - `worker_pool_spec` - Child specification for worker pool

  ## Returns

  - `{:ok, pid}` - Worker pool started successfully
  - `{:error, reason}` - Failed to start worker pool

  ## Examples

      spec = {Jido.Eval.Engine.WorkerPool, [
        config: config,
        dataset: dataset,
        metrics: [:faithfulness]
      ]}
      
      {:ok, worker_pid} = Jido.Eval.Engine.Supervisor.start_worker_pool(spec)
  """
  @spec start_worker_pool(GenServer.server(), map()) ::
          {:ok, pid()} | {:error, term()}
  def start_worker_pool(supervisor \\ @name, worker_pool_spec) do
    DynamicSupervisor.start_child(supervisor, worker_pool_spec)
  end

  @doc """
  Stop a supervised worker pool.

  ## Parameters

  - `supervisor` - Supervisor process or name
  - `worker_pool_pid` - Worker pool process ID
  - `reason` - Termination reason

  ## Returns

  - `:ok` - Worker pool stopped successfully
  - `{:error, reason}` - Failed to stop worker pool

  ## Examples

      :ok = Jido.Eval.Engine.Supervisor.stop_worker_pool(worker_pid)
      :ok = Jido.Eval.Engine.Supervisor.stop_worker_pool(worker_pid, :shutdown)
  """
  @spec stop_worker_pool(GenServer.server(), pid(), term()) ::
          :ok | {:error, term()}
  def stop_worker_pool(supervisor \\ @name, worker_pool_pid, _reason \\ :normal) do
    DynamicSupervisor.terminate_child(supervisor, worker_pool_pid)
  end

  @doc """
  List all supervised worker pools.

  ## Parameters

  - `supervisor` - Supervisor process or name

  ## Returns

  - `{:ok, children}` - List of child processes
  - `{:error, reason}` - Failed to list children

  ## Examples

      {:ok, children} = Jido.Eval.Engine.Supervisor.list_worker_pools()
      IO.inspect(length(children))
  """
  @spec list_worker_pools(GenServer.server()) ::
          {:ok, [tuple()]} | {:error, term()}
  def list_worker_pools(supervisor \\ @name) do
    try do
      children = DynamicSupervisor.which_children(supervisor)
      {:ok, children}
    rescue
      error -> {:error, error}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  @doc """
  Get count of active worker pools.

  ## Parameters

  - `supervisor` - Supervisor process or name

  ## Returns

  - `{:ok, count}` - Number of active worker pools
  - `{:error, reason}` - Failed to get count

  ## Examples

      {:ok, worker_count} = Jido.Eval.Engine.Supervisor.count_worker_pools()
      IO.inspect(worker_count)
  """
  @spec count_worker_pools(GenServer.server()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_worker_pools(supervisor \\ @name) do
    case list_worker_pools(supervisor) do
      {:ok, children} -> {:ok, length(children)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stop all supervised worker pools.

  Useful for graceful shutdown or emergency stops.

  ## Parameters

  - `supervisor` - Supervisor process or name
  - `reason` - Termination reason
  - `timeout` - Maximum time to wait for shutdown

  ## Returns

  - `:ok` - All worker pools stopped
  - `{:error, reason}` - Failed to stop some worker pools

  ## Examples

      :ok = Jido.Eval.Engine.Supervisor.stop_all_worker_pools()
      :ok = Jido.Eval.Engine.Supervisor.stop_all_worker_pools(:shutdown, 10_000)
  """
  @spec stop_all_worker_pools(GenServer.server(), term(), timeout()) ::
          :ok | {:error, term()}
  def stop_all_worker_pools(supervisor \\ @name, reason \\ :shutdown, timeout \\ 10_000) do
    case list_worker_pools(supervisor) do
      {:ok, children} ->
        Logger.info("Stopping #{length(children)} worker pools")

        # Stop all children concurrently
        tasks =
          children
          |> Enum.map(fn {_, pid, _, _} ->
            Task.async(fn ->
              stop_worker_pool(supervisor, pid, reason)
            end)
          end)

        # Wait for all to complete
        results = Task.yield_many(tasks, timeout)

        # Check if any failed
        failed =
          results
          |> Enum.filter(fn {_task, result} ->
            case result do
              {:ok, :ok} -> false
              _ -> true
            end
          end)

        case failed do
          [] ->
            Logger.info("All worker pools stopped successfully")
            :ok

          _ ->
            Logger.error("Failed to stop #{length(failed)} worker pools")
            {:error, :partial_failure}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # DynamicSupervisor callbacks

  @impl true
  def init(opts) do
    max_children = Keyword.get(opts, :max_children, 100)
    max_restarts = Keyword.get(opts, :max_restarts, 10)
    max_seconds = Keyword.get(opts, :max_seconds, 60)

    Logger.info("Starting Jido.Eval engine supervisor with max_children=#{max_children}")

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_children: max_children,
      max_restarts: max_restarts,
      max_seconds: max_seconds
    )
  end

  @doc """
  Get supervisor statistics and health information.

  ## Parameters

  - `supervisor` - Supervisor process or name

  ## Returns

  - `{:ok, stats}` - Supervisor statistics
  - `{:error, reason}` - Failed to get statistics

  ## Examples

      {:ok, stats} = Jido.Eval.Engine.Supervisor.get_stats()
      IO.inspect(stats)
  """
  @spec get_stats(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def get_stats(supervisor \\ @name) do
    try do
      with {:ok, children} <- list_worker_pools(supervisor) do
        # Group children by status
        {active, restarting} =
          children
          |> Enum.split_with(fn {_, pid, _, _} ->
            Process.alive?(pid)
          end)

        stats = %{
          supervisor_pid: supervisor,
          total_children: length(children),
          active_children: length(active),
          restarting_children: length(restarting),
          supervisor_alive: Process.alive?(supervisor),
          uptime_seconds: get_uptime_seconds(supervisor)
        }

        {:ok, stats}
      end
    rescue
      error -> {:error, error}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  # Private helper functions

  defp get_uptime_seconds(supervisor) do
    try do
      case Process.info(supervisor, :start_time) do
        {:start_time, start_time} ->
          now = :erlang.monotonic_time(:second)
          now - start_time

        nil ->
          nil
      end
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end
end
