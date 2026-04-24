# Jido Eval Usage Rules

Use these rules when generating code that depends on Jido Eval.

## Package Role

Jido Eval provides dataset-based and future agentic evaluation tools for LLM systems. The current stable surface is the
Ragas-like basic eval harness.

## Core API

- Use `Jido.Eval.evaluate/2` for synchronous evaluation.
- Use `Jido.Eval.evaluate_async/2`, `Jido.Eval.get_progress/1`, `Jido.Eval.await_result/2`, and `Jido.Eval.cancel/1`
  for async runs.
- Prefer `judge_model:` and `judge_opts:` when configuring judge calls.
- Treat `llm:` and `llm_opts:` as legacy compatibility aliases.

## Datasets

- Use `Jido.Eval.Dataset.InMemory` for tests and small eval suites.
- Use `Jido.Eval.Dataset.JSONL` for streaming datasets.
- Use `Jido.Eval.Dataset.CSV` only for flat single-turn samples.

## Metrics

- Built-in metric names are `:faithfulness` and `:context_precision`.
- Metric implementations should return either a numeric score or a metric result map containing score, details, and
  judge call summaries.
- Use structured `req_llm` object calls for judge outputs instead of parsing free-form yes/no text.

## Models

- Pass model specs directly to `req_llm` or `llm_db`.
- Do not add local model-spec shim maps.
- Examples: `"openai:gpt-4o"`, `"anthropic:claude-3-5-sonnet-20241022"`, or `LLMDB.model!("openai:gpt-4o")`.

## Testing

- Keep live evals tagged with `:live_eval`.
- Use deterministic stubs for default unit tests.
- Preserve judge metadata in assertions when changing metric behavior.
