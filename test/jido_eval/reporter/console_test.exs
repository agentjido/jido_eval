defmodule Jido.Eval.Reporter.ConsoleTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Jido.Eval.Reporter.Console

  setup do
    previous_capture_log = Application.get_env(:ex_unit, :capture_log)

    on_exit(fn ->
      if is_nil(previous_capture_log) do
        Application.delete_env(:ex_unit, :capture_log)
      else
        Application.put_env(:ex_unit, :capture_log, previous_capture_log)
      end
    end)
  end

  describe "report/3" do
    test "skips console output when ExUnit capture_log is enabled" do
      Application.put_env(:ex_unit, :capture_log, true)

      assert capture_io(fn ->
               assert :ok = Console.report(:sample, %{sample_id: "s1", scores: %{faithfulness: 1.0}}, [])
             end) == ""
    end

    test "dispatches sample and summary events when output is enabled" do
      Application.put_env(:ex_unit, :capture_log, false)

      sample_output =
        capture_io(fn ->
          assert :ok = Console.report(:sample, %{sample_id: "s1", scores: %{faithfulness: 0.875}}, [])
        end)

      assert sample_output =~ "Sample s1"
      assert sample_output =~ "faithfulness=0.875"

      summary_output =
        capture_io(fn ->
          assert :ok =
                   Console.report(
                     :summary,
                     %{
                       run_id: "run-1",
                       sample_count: 2,
                       completed_count: 1,
                       error_count: 1,
                       duration_ms: 123,
                       pass_rate: 0.5,
                       summary_stats: %{faithfulness: %{avg: 0.75, min: 0.5, max: 1.0}},
                       error_categories: %{"judge_error" => 1}
                     },
                     []
                   )
        end)

      assert summary_output =~ "EVALUATION SUMMARY"
      assert summary_output =~ "Run ID: run-1"
      assert summary_output =~ "Errors: 1"
      assert summary_output =~ "Pass Rate: 50.0%"
      assert summary_output =~ "faithfulness: avg=0.750 min=0.500 max=1.000"
      assert summary_output =~ "judge_error: 1"

      assert :ok = Console.report(:unknown, %{}, [])
    end
  end

  describe "handle_sample/2" do
    test "prints successful samples, failed samples, and empty scores" do
      success =
        capture_io(fn ->
          assert :ok = Console.handle_sample(%{sample_id: "ok", scores: %{faithfulness: 1}}, [])
        end)

      assert success =~ "Sample ok"
      assert success =~ "faithfulness=1.000"

      empty =
        capture_io(fn ->
          assert :ok = Console.handle_sample(%{sample_id: "empty", scores: %{}}, [])
        end)

      assert empty =~ "no scores"

      failure =
        capture_io(fn ->
          assert :ok = Console.handle_sample(%{sample_id: "bad", error: "failed"}, [])
        end)

      assert failure =~ "Sample bad: ERROR - failed"
    end
  end

  describe "handle_summary/2" do
    test "prints minimal summary data" do
      output =
        capture_io(fn ->
          assert :ok = Console.handle_summary(%{}, [])
        end)

      assert output =~ "Run ID: unknown"
      assert output =~ "Samples: 0/0 completed"
      assert output =~ "Duration: 0ms"
    end
  end
end
