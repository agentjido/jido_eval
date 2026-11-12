defmodule Jido.Eval.Sample.AgentTraceTest do
  use ExUnit.Case, async: true

  alias Jido.Eval.AgentTrace.Span
  alias Jido.Eval.Sample.AgentTrace

  describe "new/1" do
    test "normalizes trace spans from maps" do
      assert {:ok, sample} =
               AgentTrace.new(%{
                 "id" => "refund_success",
                 "task" => "Resolve refund",
                 "trace" => [
                   %{"type" => "tool_call", "name" => "lookup_order", "status" => "ok"},
                   %{"type" => "tool_call", "name" => "issue_refund", "status" => "ok"}
                 ],
                 "expectations" => %{"required_tools" => ["lookup_order", "issue_refund"]}
               })

      assert sample.id == "refund_success"
      assert [%Span{type: :tool_call}, %Span{type: :tool_call}] = sample.trace
      assert AgentTrace.tool_names(sample) == ["lookup_order", "issue_refund"]
    end

    test "rejects missing task" do
      assert {:error, "Agent trace sample must include a task"} =
               AgentTrace.new(%{trace: [%{type: :tool_call, name: "lookup_order"}]})
    end

    test "rejects empty traces" do
      assert {:error, "Agent trace cannot be empty"} =
               AgentTrace.new(%{task: "Resolve refund", trace: []})
    end

    test "rejects malformed trace entries without raising" do
      assert {:error, {:invalid_span, "not a span"}} =
               AgentTrace.new(%{task: "Resolve refund", trace: ["not a span"]})
    end

    test "rejects non-list trace values" do
      assert {:error, [_ | _]} = AgentTrace.new(%{task: "Resolve refund", trace: "not a list"})
    end

    test "new!/1 raises on invalid attrs" do
      assert_raise ArgumentError, fn ->
        AgentTrace.new!(%{task: "Resolve refund", trace: []})
      end
    end
  end

  describe "to_map/1" do
    test "serializes spans for JSONL storage" do
      sample =
        AgentTrace.new!(%{
          id: "sample",
          task: "Resolve refund",
          trace: [%{id: "s1", type: "tool_call", name: "lookup_order"}],
          tags: %{"suite" => "refunds"}
        })

      assert %{
               id: "sample",
               trace: [%{id: "s1", type: :tool_call, name: "lookup_order"}],
               tags: %{"suite" => "refunds"}
             } = AgentTrace.to_map(sample)
    end
  end
end
