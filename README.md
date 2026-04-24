# Jido Eval

Jido Eval is an Elixir package for evaluating LLM applications in the Jido ecosystem. The current core is a
Ragas-like harness for dataset-based evaluation with structured judge calls through [`req_llm`](https://hex.pm/packages/req_llm)
and model metadata from [`llm_db`](https://hex.pm/packages/llm_db).

Agentic evals are expected to build on this foundation later. This package keeps the basic evaluation layer small:
load samples, run metrics, preserve per-metric judge metadata, and return an auditable `Jido.Eval.Result`.

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

Jido Eval does not currently ship an Igniter installer because the package has no required config files, migrations, or
scaffolding side effects. Add provider keys through `req_llm` configuration or environment variables.

## Quick Start

```elixir
alias Jido.Eval
alias Jido.Eval.Dataset.InMemory
alias Jido.Eval.Sample.SingleTurn

samples = [
  %SingleTurn{
    user_input: "What is the capital of France?",
    retrieved_contexts: ["France's capital is Paris."],
    response: "Paris is the capital of France."
  }
]

{:ok, dataset} = InMemory.new(samples)

{:ok, result} =
  Eval.evaluate(dataset,
    metrics: [:faithfulness, :context_precision],
    judge_model: "openai:gpt-4o",
    judge_opts: [temperature: 0.0]
  )

result.summary_stats
```

`llm:` and `llm_opts:` remain accepted compatibility aliases, but new code should use `judge_model:` and
`judge_opts:`.

## Built-In Metrics

- `:faithfulness` extracts factual statements from a response and checks whether each statement is supported by the
  retrieved contexts.
- `:context_precision` checks whether retrieved contexts are relevant to the input and computes average precision over
  relevant context positions.

Both built-in metrics use structured `req_llm` object calls so result details include schema-validated booleans,
reasoning, judge-call summaries, usage, finish reason, provider metadata, latency, and cache-hit state.

## Model Specs

Pass judge models using `req_llm` model specs:

```elixir
"openai:gpt-4o"
"anthropic:claude-3-5-sonnet-20241022"
LLMDB.model!("openai:gpt-4o")
```

Jido Eval deliberately passes model specs through to `req_llm` and `llm_db` directly instead of maintaining a parallel
model map layer.

## Live Evals

Live evals are excluded from the default test suite. To run them, create a local `.env` with provider keys:

```bash
OPENAI_API_KEY=...
ANTHROPIC_API_KEY=...
```

Then run:

```bash
mix test --include live_eval
```

## Development

```bash
mix setup
mix test
mix quality
mix coveralls
mix docs
```

`mix quality` runs the Jido package quality gate: formatting, strict compile, Credo, Dialyzer, and MixDoctor.

## License

Apache-2.0. See `LICENSE`.
