# Jido Eval

[![Hex.pm](https://img.shields.io/hexpm/v/jido_eval.svg)](https://hex.pm/packages/jido_eval)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jido_eval/)
[![CI](https://github.com/agentjido/jido_eval/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_eval/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jido_eval.svg)](https://github.com/agentjido/jido_eval/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

Jido Eval is an Elixir package for evaluating LLM and agent systems in the Jido ecosystem. It provides a
Ragas-like harness for dataset-based evaluation, structured judge calls through [`req_llm`](https://hex.pm/packages/req_llm),
model metadata from [`llm_db`](https://hex.pm/packages/llm_db), and an initial agent-trace evaluation layer.

The package is focused on two use cases:

1. **LLM evals** - dataset-based evaluation for `ReqLLM` responses and retrieval-backed generation. This is the working core today.
2. **Agent evals** - saved-trace evaluation for tool use and task outcomes. This is an initial spike, not a complete runtime integration.

The base LLM and retrieval layer loads samples, runs grading metrics, calls judge models through [`req_llm`](https://hex.pm/packages/req_llm), preserves judge metadata, and returns auditable results. The agent layer adds saved traces and agent-specific metrics on top of that foundation.

## Current Status

| Use case | Status | Scope |
| --- | --- | --- |
| LLM evals | Available | `ReqLLM`-backed judge calls, datasets, RAG-style metrics, golden eval tests |
| Agent evals | Spike | Saved agent traces, compact trace views, deterministic tool-use checks, structured task-success judging |

## Installation

Add `jido_eval` to your dependencies:

```elixir
def deps do
  [
    {:jido_eval, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

Provider keys are read by `req_llm`. In local development, a `.env` file works well for live evals:

```bash
OPENAI_API_KEY=...
ANTHROPIC_API_KEY=...
```

Jido Eval does not currently ship an Igniter installer because it has no required config files, migrations, or scaffolding side effects.

## Use Case 1: LLM Evals

LLM evals grade the behavior of a model response at the base retrieval layer. This is the place to answer questions like:

- Did the answer stay faithful to retrieved context?
- Were the retrieved contexts relevant to the question?
- Did a model or prompt change improve the retrieval-augmented answer?
- Does a golden dataset still score inside expected bands?

This layer is deliberately smaller than an agent evaluator. It works with samples and judge models, not agent traces.

## Quick Start

```elixir
alias Jido.Eval
alias Jido.Eval.Dataset.InMemory
alias Jido.Eval.Sample.SingleTurn

samples = [
  %SingleTurn{
    id: "capital_france",
    user_input: "What is the capital of France?",
    retrieved_contexts: [
      "France is a country in Western Europe. Its capital and largest city is Paris."
    ],
    response: "The capital of France is Paris.",
    reference: "Paris is the capital of France."
  }
]

{:ok, dataset} = InMemory.new(samples)

{:ok, result} =
  Eval.evaluate(dataset,
    metrics: [:faithfulness, :context_precision],
    judge_model: "openai:gpt-4o-mini",
    judge_opts: [temperature: 0.0]
  )

result.summary_stats
```

The public API keeps the simple shape:

```elixir
{:ok, result} = Jido.Eval.evaluate(dataset, metrics: [:faithfulness])
{:ok, run_id} = Jido.Eval.evaluate_async(dataset, metrics: [:faithfulness])
```

`llm:` and `llm_opts:` are still accepted for compatibility, but new code should use `judge_model:` and `judge_opts:`.

## Evaluating ReqLLM Responses

Jido Eval does not require your generation path to run through the evaluator. Generate with `ReqLLM`, capture the response text and retrieval context, then build samples:

```elixir
{:ok, llm_response} =
  ReqLLM.generate_text(
    LLMDB.model!("openai:gpt-4o-mini"),
    "Answer using the retrieved context: France's capital is Paris.",
    temperature: 0.0
  )

sample = %Jido.Eval.Sample.SingleTurn{
  user_input: "What is the capital of France?",
  retrieved_contexts: ["France's capital is Paris."],
  response: ReqLLM.Response.text(llm_response),
  reference: "Paris is the capital of France."
}
```

The judge path also uses `ReqLLM` directly. Judge calls preserve the raw `%ReqLLM.Response{}`, output text or object, usage, finish reason, provider metadata, latency, model, and cache-hit state.

## Built-In Metrics

- `:faithfulness` extracts factual statements from a response and checks whether each statement is supported by the retrieved contexts.
- `:context_precision` checks whether retrieved contexts are relevant to the input and computes average precision over relevant context positions.

Both built-in metrics use structured object calls through `ReqLLM`, so boolean grading is schema-validated instead of parsed from brittle yes/no text.

## Results

Each evaluation returns a `Jido.Eval.Result` with:

- `sample_results` - per-sample metric results.
- `scores` - backward-compatible score map.
- `metric_results` - per-metric status, score, errors, structured details, and judge-call summaries.
- `summary_stats` - aggregate stats computed from successful metric scores.

Metric failures are recorded per metric so one failed grade does not erase the rest of the sample.

## Model Specs

Pass judge models using `req_llm` and `llm_db` model specs:

```elixir
"openai:gpt-4o-mini"
"anthropic:claude-3-5-sonnet-20241022"
LLMDB.model!("openai:gpt-4o-mini")
```

Jido Eval passes model specs through to `req_llm` and `llm_db` directly instead of maintaining a parallel model map layer.

## Golden Evals

Golden evals are small, stable datasets that protect expected behavior. This repo includes a live golden eval test for the RAG-style harness:

```bash
mix test --include live_eval test/jido_eval/integration/golden_eval_test.exs
```

Live evals are excluded from the default test suite and require provider keys in the environment or local `.env`.

## Use Case 2: Agent Evals

Agent evals are the next intended layer for this package. The current spike supports saved trace evaluation; it is not yet a complete Jido Agent runtime integration.

The problem is different from base LLM grading. Agent evals need to evaluate multi-step behavior:

- Did the agent choose the right tools?
- Did it recover from tool or model errors?
- Did it follow policy and task constraints across a trace?
- Did it reach the correct final outcome for the right reasons?
- Did planning, memory, tool calls, and final response improve or regress?

The current agent trace sample shape is:

```elixir
%Jido.Eval.Sample.AgentTrace{
  id: "refund_success",
  task: "Resolve a customer refund request",
  input: %{customer_id: "cust_123", order_id: "ord_123"},
  expected_outcome: %{refunded: true},
  final_response: "I verified the order and issued the refund.",
  trace: [
    %Jido.Eval.AgentTrace.Span{type: :tool_call, name: "lookup_order", status: :ok},
    %Jido.Eval.AgentTrace.Span{type: :tool_call, name: "issue_refund", status: :ok}
  ],
  expectations: %{
    required_tools: ["lookup_order", "issue_refund"],
    tool_order: ["lookup_order", "issue_refund"],
    forbidden_tools: ["cancel_order"],
    max_tool_calls: 2
  },
  rubrics: %{"policy" => "Must look up the order before issuing a refund."}
}
```

Agent trace samples can be evaluated through the same public API:

```elixir
{:ok, result} =
  Jido.Eval.evaluate(dataset,
    metrics: [:agent_tool_use_correctness, :agent_task_success],
    judge_model: "openai:gpt-4o-mini"
  )
```

The spike includes two metrics:

- `:agent_tool_use_correctness` is deterministic. It checks required tools, forbidden tools, expected tool order, and maximum tool-call count.
- `:agent_task_success` uses a structured `ReqLLM` judge call over a compact trace view containing the task, expected outcome, final response, tool timeline, errors, span counts, and rubrics.

The current LLM eval layer is meant to be the foundation for that work, not the final agent-eval abstraction.

## Development

```bash
mix setup
mix test
mix quality
mix docs
```

`mix quality` runs the Jido package quality gate: formatting, strict compile, Credo, Dialyzer, and MixDoctor.

## License

Apache-2.0. See `LICENSE`.
