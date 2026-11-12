defmodule Jido.Eval.AgentTraceTest do
  use ExUnit.Case, async: true

  alias Jido.Eval.AgentTrace
  alias Jido.Eval.Sample.AgentTrace, as: AgentTraceSample

  test "builds compact trace views for agent judges" do
    sample =
      AgentTraceSample.new!(%{
        task: "Resolve refund",
        expected_outcome: %{refunded: true},
        final_response: "Refund issued.",
        trace: [
          %{id: "s1", type: "llm_call", name: "plan", status: "ok"},
          %{id: "s2", type: "tool_call", name: "lookup_order", status: "ok"},
          %{id: "s3", type: "tool_call", name: "issue_refund", status: "ok"},
          %{id: "s4", type: "tool_call", name: "notify_customer", status: "error", error: "timeout"}
        ],
        rubrics: %{"policy" => "Look up the order first"}
      })

    view = AgentTrace.compact_view(sample)

    assert view.task == "Resolve refund"
    assert Enum.map(view.tool_timeline, & &1.name) == ["lookup_order", "issue_refund", "notify_customer"]
    assert [%{name: "notify_customer", status: :error}] = view.errors
    assert view.span_counts == %{llm_call: 1, tool_call: 3}
  end
end
