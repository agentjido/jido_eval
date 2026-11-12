defmodule Jido.Eval.AgentTrace.SpanTest do
  use ExUnit.Case, async: true

  alias Jido.Eval.AgentTrace.Span

  describe "new/1" do
    test "normalizes known atom and string values" do
      assert {:ok, span} =
               Span.new(%{
                 id: "s1",
                 parent_id: "root",
                 type: "tool-call",
                 name: "lookup_order",
                 status: "timeout",
                 duration_ms: 10,
                 metadata: %{"attempt" => 1}
               })

      assert span.type == :tool_call
      assert span.status == :timeout
      assert span.parent_id == "root"
      assert Span.tool_call?(span)
      assert Span.failed?(span)
    end

    test "defaults unknown type and status values" do
      assert {:ok, span} = Span.new(%{type: "custom-runtime-event", status: "weird"})

      assert span.type == :event
      assert span.status == :ok
      refute Span.tool_call?(span)
      refute Span.failed?(span)
    end

    test "new!/1 raises for invalid attrs" do
      assert_raise ArgumentError, fn ->
        Span.new!(%{duration_ms: "slow"})
      end
    end
  end

  test "to_map/1 drops nil values and preserves payloads" do
    span = Span.new!(%{type: :llm_call, name: "plan", input: %{task: "x"}, output: "plan"})

    assert %{type: :llm_call, name: "plan", input: %{task: "x"}, output: "plan"} = Span.to_map(span)
    refute Map.has_key?(Span.to_map(span), :parent_id)
  end
end
