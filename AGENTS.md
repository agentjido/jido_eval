# AGENT.md - Jido Eval Development Guide

Jido Eval is an Elixir package for evaluating LLMs. It follows the Ragas SDK (Python) pattern. It is designed for use within the Jido Ecosystem.

## Ragas Version

This package is based on Ragas version 0.3.1, available as of 2025-08-18 at https://github.com/explodinggradients/ragas/tree/v0.3.1

## Commands

- **Test**: `mix test` (all), `mix test test/path/to/specific_test.exs` (single file), `mix test --trace` (verbose)
- **Lint**: `mix credo` (basic), `mix credo --strict` (strict mode)
- **Format**: `mix format` (format code), `mix format --check-formatted` (verify formatting)
- **Quality**: `mix quality` or `mix q` (runs format, compile, credo, dialyzer, doctor)
- **Hooks**: `mix install_hooks` (explicit maintainer step; hooks do not auto-install)
- **Compile**: `mix compile` (basic), `mix compile --warnings-as-errors` (strict)
- **Type Check**: `mix dialyzer --format dialyxir`
- **Coverage**: `mix test --cover` (basic), `mix coveralls.html` (HTML report)
- **Docs**: `mix docs` (generate documentation)

## SDLC

- **Coverage Goal**: Test coverage goal should be 90%+
- **Code Quality**: Use `mix quality` to run all checks
  - Fix all compiler warnings
  - Fix all dialyzer warnings
  - Fix Credo issues at priority `higher` and above
  - Keep `mix doctor --raise` passing
  - Add `@type` to all custom types
  - Add `@spec` to all public functions
  - Add `@doc` to all public functions and `@moduledoc` to all modules

## Code Style

- **Formatting**: Uses [`mix format`](.formatter.exs), line length max 120 chars
- **Types**: Add `@spec` to all public functions, use `@type` for custom types
- **Docs**: `@moduledoc` for modules, `@doc` for public functions with examples
- **Testing**: Mirror lib structure in test/, use ExUnit with async when possible, tag slow/integration tests
- **HTTP Testing**: Use Req.Test for HTTP mocking instead of Mimic - provides cleaner stubs and better integration
- **Error Handling**: Return `{:ok, result}` or `{:error, reason}` tuples, use `with` for complex flows
- **Schemas**: Use Zoi for core struct schemas, types, defaults, and validation boundaries
- **Imports**: Group aliases at module top, prefer explicit over wildcard imports
- **Naming**: `snake_case` for functions/variables, `PascalCase` for modules
- **Logging**: Avoid Logger metadata - integrate all fields into log message strings instead of using keyword lists

## Architecture

Jido Eval follows a **pluggable component architecture** with clean separation of concerns:

- **Core Data Layer**: Sample structures and Dataset protocol for flexible data sources
- **Component System**: Pluggable behaviours for reporters, stores, broadcasters, processors, middleware
- **Execution Engine**: OTP-supervised evaluation with fault isolation and concurrency control
- **Judge Integration**: Retry-enabled wrapper around `req_llm` with caching and auditable response metadata

## Public API Overview

### Simple Evaluation (Ragas-compatible)
```elixir
# Quick evaluation with defaults
{:ok, result} = Jido.Eval.evaluate(dataset)

# With specific metrics
{:ok, result} = Jido.Eval.evaluate(dataset, metrics: [:faithfulness, :context_precision])
```

### Advanced Configuration
```elixir
# Enterprise features with pluggable components
{:ok, result} = Jido.Eval.evaluate(dataset, 
  metrics: [:faithfulness, :context_precision],
  judge_model: "openai:gpt-4o",
  judge_opts: [temperature: 0.0],
  run_config: %Jido.Eval.RunConfig{timeout: 30_000},
  reporters: [{MyApp.JSONReporter, format: :json}],
  stores: [{MyApp.PostgresStore, table: "evaluations"}],
  broadcasters: [{Phoenix.PubSub, topic: "evals"}]
)
```

### Async Evaluation with Monitoring
```elixir
# Async evaluation with real-time monitoring
{:ok, run_id} = Jido.Eval.evaluate(dataset, sync: false)
:telemetry.attach([:jido, :eval, :progress], fn event, measurements, metadata, _ ->
  IO.puts("Progress: #{metadata.completed}/#{metadata.total}")
end)
```

## Data Architecture

### Sample Structures
- **`Jido.Eval.Sample.SingleTurn`**: Single Q&A interactions with context, response, and metadata
- **`Jido.Eval.Sample.MultiTurn`**: Multi-turn conversations using message maps
- **Helper Functions**: Convert between string and Message formats, validation with clear errors

### Dataset Protocol
- **`Jido.Eval.Dataset`**: Protocol for pluggable data sources (to_stream/1, sample_type/1, count/1)
- **Built-in Adapters**: InMemory (lists), JSONL (streaming), CSV (single-turn only)
- **Memory Efficient**: Streaming preserves memory usage regardless of dataset size

### Configuration System
- **`Jido.Eval.Config`**: Runtime configuration with pluggable components
- **`Jido.Eval.RunConfig`**: Execution parameters (timeout, workers, retry policy)
- **`Jido.Eval.RetryPolicy`**: Retry behavior with exponential backoff and jitter

### Component Registry
- **`Jido.Eval.ComponentRegistry`**: ETS-based registry for hot-reloadable components
- **Component Types**: reporter, store, broadcaster, processor, middleware
- **Runtime Discovery**: Dynamic component lookup and registration

## ReqLLM Integration

This package uses `req_llm` directly for judge calls in the basic eval harness. New code should pass `judge_model:` and
`judge_opts:`. The legacy `llm:` and `llm_opts:` aliases remain accepted for compatibility.

### Text Generation

```elixir
# Simple text generation
{:ok, call} = Jido.Eval.LLM.text("openai:gpt-4o", "Evaluate this response")
call.output

# With rich messages
messages = [
  %{role: :system, content: "You are an evaluation expert"},
  %{role: :user, content: "Rate this response"}
]
{:ok, evaluation} = Jido.Eval.LLM.generate_text("openai:gpt-4o", messages)
```

### Structured Data Generation

```elixir
# Schema-validated evaluation results
schema =
  Zoi.object(%{
    score: Zoi.float(),
    reasoning: Zoi.string(),
    categories: Zoi.list(Zoi.string()) |> Zoi.default([])
  })

{:ok, call} = Jido.Eval.LLM.object(
  "openai:gpt-4o",
  "Evaluate this response",
  schema
)
call.output
```

### Model Specifications

This package passes model specs directly to `req_llm` and `llm_db`:

- String: `"openai:gpt-4o"` or `"anthropic:claude-3-5-sonnet-20241022"` (primary format)
- Model struct: `LLMDB.model!("openai:gpt-4o")`

Do not add local model-spec shim maps.

### Configuration

Provider keys are read by `req_llm`. Live eval tests use Dotenvy to load `.env` when run with `--include live_eval`.
