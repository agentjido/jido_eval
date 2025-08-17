defmodule Jido.Eval.Engine.WorkerTest do
  use ExUnit.Case, async: true

  alias Jido.Eval.Engine.Worker
  alias Jido.Eval.{Config, RunConfig, Sample}

  defp test_config do
    %Config{
      run_id: "worker_test_run",
      model_spec: "test:mock",
      run_config: %RunConfig{timeout: 5_000}
    }
  end

  defp test_sample do
    %Sample.SingleTurn{
      id: "test_sample",
      user_input: "What is the capital of France?",
      response: "Paris is the capital of France.",
      retrieved_contexts: ["France's capital is Paris."],
      tags: %{"category" => "geography"}
    }
  end

  setup do
    # Start a mock pool process to receive results
    {:ok, pool_pid} = Agent.start_link(fn -> [] end)

    # Capture messages sent to pool
    test_pid = self()

    pool_wrapper =
      spawn_link(fn ->
        receive do
          {:worker_result, worker_pid, result} ->
            send(test_pid, {:worker_result, worker_pid, result})

          {:worker_error, worker_pid, error} ->
            send(test_pid, {:worker_error, worker_pid, error})
        end
      end)

    %{pool_pid: pool_wrapper}
  end

  describe "start_link/1" do
    test "starts worker with required options", %{pool_pid: pool_pid} do
      opts = [
        run_id: "test_run",
        metrics: [:faithfulness],
        config: test_config(),
        pool_pid: pool_pid
      ]

      {:ok, worker_pid} = Worker.start_link(opts)
      assert Process.alive?(worker_pid)
    end

    test "requires run_id option" do
      opts = [
        metrics: [:faithfulness],
        config: test_config(),
        pool_pid: self()
      ]

      assert_raise KeyError, fn ->
        Worker.start_link(opts)
      end
    end

    test "requires metrics option" do
      opts = [
        run_id: "test_run",
        config: test_config(),
        pool_pid: self()
      ]

      assert_raise KeyError, fn ->
        Worker.start_link(opts)
      end
    end
  end

  describe "evaluate_sample message" do
    test "processes sample and reports result", %{pool_pid: pool_pid} do
      opts = [
        run_id: "test_run",
        metrics: [:faithfulness],
        config: test_config(),
        pool_pid: pool_pid,
        timeout: 10_000
      ]

      {:ok, worker_pid} = Worker.start_link(opts)
      sample = test_sample()

      GenServer.cast(worker_pid, {:evaluate_sample, sample})

      # Wait for result
      assert_receive {:worker_result, ^worker_pid, result}, 15_000

      assert result.sample_id == "test_sample"
      assert is_map(result.scores)
      assert is_integer(result.latency_ms)
      assert result.error == nil
      assert result.tags == %{"category" => "geography"}
    end

    test "handles sample with missing required fields", %{pool_pid: pool_pid} do
      opts = [
        run_id: "test_run",
        # Requires response and retrieved_contexts
        metrics: [:faithfulness],
        config: test_config(),
        pool_pid: pool_pid
      ]

      {:ok, worker_pid} = Worker.start_link(opts)

      # Sample missing required fields
      incomplete_sample = %Sample.SingleTurn{
        id: "incomplete_sample",
        user_input: "Question",
        # Missing response and retrieved_contexts
        tags: %{}
      }

      GenServer.cast(worker_pid, {:evaluate_sample, incomplete_sample})

      assert_receive {:worker_result, ^worker_pid, result}, 5_000

      assert result.sample_id == "incomplete_sample"
      assert result.scores == %{}
      assert String.contains?(result.error, "validation failed")
    end

    test "handles worker timeout", %{pool_pid: pool_pid} do
      opts = [
        run_id: "test_run",
        metrics: [:faithfulness],
        config: test_config(),
        pool_pid: pool_pid,
        # Very short timeout
        timeout: 100
      ]

      {:ok, worker_pid} = Worker.start_link(opts)
      sample = test_sample()

      GenServer.cast(worker_pid, {:evaluate_sample, sample})

      # Should timeout and report error
      assert_receive {:worker_result, ^worker_pid, result}, 5_000

      assert result.sample_id == "test_sample"
      assert result.scores == %{}
      assert String.contains?(result.error, "timeout")
      assert result.metadata.timeout == true
    end

    test "handles unknown metrics", %{pool_pid: pool_pid} do
      opts = [
        run_id: "test_run",
        metrics: [:nonexistent_metric],
        config: test_config(),
        pool_pid: pool_pid
      ]

      {:ok, worker_pid} = Worker.start_link(opts)
      sample = test_sample()

      GenServer.cast(worker_pid, {:evaluate_sample, sample})

      assert_receive {:worker_result, ^worker_pid, result}, 5_000

      assert result.sample_id == "test_sample"
      assert result.scores == %{}
      assert String.contains?(result.error, "unknown_metric")
    end

    test "processes multiple metrics", %{pool_pid: pool_pid} do
      opts = [
        run_id: "test_run",
        metrics: [:faithfulness, :context_precision],
        config: test_config(),
        pool_pid: pool_pid
      ]

      {:ok, worker_pid} = Worker.start_link(opts)
      sample = test_sample()

      GenServer.cast(worker_pid, {:evaluate_sample, sample})

      assert_receive {:worker_result, ^worker_pid, result}, 15_000

      # Should have scores for metrics that succeeded
      assert is_map(result.scores)
      # The exact metrics that succeed depend on the mock implementation
    end

    test "ignores evaluate_sample when cancelled", %{pool_pid: pool_pid} do
      opts = [
        run_id: "test_run",
        metrics: [:faithfulness],
        config: test_config(),
        pool_pid: pool_pid
      ]

      {:ok, worker_pid} = Worker.start_link(opts)

      # Cancel first
      GenServer.cast(worker_pid, :cancel)

      # Then try to evaluate
      GenServer.cast(worker_pid, {:evaluate_sample, test_sample()})

      # Should not receive any result
      refute_receive {:worker_result, ^worker_pid, _result}, 2_000
    end
  end

  describe "cancel message" do
    test "cancels active processing", %{pool_pid: pool_pid} do
      opts = [
        run_id: "test_run",
        metrics: [:faithfulness],
        config: test_config(),
        pool_pid: pool_pid,
        # Long timeout so we can cancel
        timeout: 10_000
      ]

      {:ok, worker_pid} = Worker.start_link(opts)
      sample = test_sample()

      # Start processing
      GenServer.cast(worker_pid, {:evaluate_sample, sample})

      # Give it a moment to start
      Process.sleep(100)

      # Cancel
      GenServer.cast(worker_pid, :cancel)

      # Should not receive result or receive cancelled result
      receive do
        {:worker_result, ^worker_pid, _result} ->
          # If we do receive result, processing completed before cancel
          :ok
      after
        2_000 ->
          # No result received, cancel was effective
          :ok
      end
    end
  end

  describe "error scenarios" do
    test "handles task crashes gracefully", %{pool_pid: pool_pid} do
      opts = [
        run_id: "test_run",
        metrics: [:faithfulness],
        config: test_config(),
        pool_pid: pool_pid
      ]

      {:ok, worker_pid} = Worker.start_link(opts)

      # Create a sample that might cause processing to fail
      problematic_sample = %Sample.SingleTurn{
        id: "crash_sample",
        # This might cause crashes in processing
        user_input: nil,
        response: "Answer",
        retrieved_contexts: ["Context"],
        tags: %{}
      }

      GenServer.cast(worker_pid, {:evaluate_sample, problematic_sample})

      # Should still report a result, even if processing failed
      assert_receive {:worker_result, ^worker_pid, result}, 5_000

      assert result.sample_id == "crash_sample"
      # Should have error reported
      assert result.error != nil
    end

    test "handles concurrent evaluation requests", %{pool_pid: pool_pid} do
      opts = [
        run_id: "test_run",
        metrics: [:faithfulness],
        config: test_config(),
        pool_pid: pool_pid
      ]

      {:ok, worker_pid} = Worker.start_link(opts)

      sample1 = %{test_sample() | id: "sample_1"}
      sample2 = %{test_sample() | id: "sample_2"}

      # Send multiple samples rapidly
      GenServer.cast(worker_pid, {:evaluate_sample, sample1})
      GenServer.cast(worker_pid, {:evaluate_sample, sample2})

      # Should process one at a time, second should be ignored or queued
      assert_receive {:worker_result, ^worker_pid, result1}, 10_000

      # May or may not receive second result depending on implementation
      receive do
        {:worker_result, ^worker_pid, _result2} -> :ok
      after
        1_000 -> :ok
      end

      assert result1.sample_id in ["sample_1", "sample_2"]
    end
  end

  describe "telemetry integration" do
    test "emits telemetry events during processing", %{pool_pid: pool_pid} do
      # Attach telemetry handler
      test_pid = self()
      handler_id = :worker_telemetry_test

      :telemetry.attach_many(
        handler_id,
        [
          [:jido, :eval, :metric, :start],
          [:jido, :eval, :metric, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      opts = [
        run_id: "telemetry_test_run",
        metrics: [:faithfulness],
        config: test_config(),
        pool_pid: pool_pid
      ]

      {:ok, worker_pid} = Worker.start_link(opts)
      sample = test_sample()

      GenServer.cast(worker_pid, {:evaluate_sample, sample})

      # Should receive telemetry events
      assert_receive {:telemetry, [:jido, :eval, :metric, :start], _measurements, metadata}, 5_000
      assert metadata.run_id == "telemetry_test_run"
      assert metadata.metric == :faithfulness

      assert_receive {:telemetry, [:jido, :eval, :metric, :stop], measurements, metadata}, 10_000
      assert metadata.run_id == "telemetry_test_run"
      assert metadata.metric == :faithfulness
      assert is_number(measurements.duration_ms)

      # Cleanup
      :telemetry.detach(handler_id)
    end
  end
end
