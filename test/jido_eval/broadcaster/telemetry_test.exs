defmodule Jido.Eval.Broadcaster.TelemetryTest do
  use ExUnit.Case, async: false

  alias Jido.Eval.Broadcaster.Telemetry
  alias Jido.Eval.Result

  test "publishes map data as measurements and metadata" do
    event = [:jido_eval_test, :sample]
    parent = self()

    :telemetry.attach(
      "jido-eval-test-map",
      event,
      fn ^event, measurements, metadata, _config ->
        send(parent, {:telemetry_event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("jido-eval-test-map") end)

    assert :ok = Telemetry.publish(:sample, %{count: 2, duration: 10, id: "s1"}, prefix: [:jido_eval_test])

    assert_receive {:telemetry_event, %{count: 2, duration: 10}, %{id: "s1"}}
  end

  test "publishes structs and non-map data as metadata" do
    struct_event = [:jido_eval_test, :summary]
    value_event = [:jido_eval_test, :raw]
    parent = self()

    :telemetry.attach_many(
      "jido-eval-test-structs",
      [struct_event, value_event],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("jido-eval-test-structs") end)

    result = %Result{run_id: "run-1", sample_count: 3}
    assert :ok = Telemetry.publish(:summary, result, prefix: [:jido_eval_test])
    assert :ok = Telemetry.publish(:raw, :started, prefix: [:jido_eval_test])

    assert_receive {:telemetry_event, ^struct_event, %{sample_count: 3}, metadata}
    assert metadata.struct == Result
    assert metadata.data == result

    assert_receive {:telemetry_event, ^value_event, %{}, %{data: :started}}
  end
end
