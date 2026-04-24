# Examples

Runnable examples for Jido Eval live outside `lib/` so example setup does not leak into the library dependency graph.

## Basic Eval

```bash
OPENAI_API_KEY=... mix run examples/basic_eval.exs
```

The example builds a small in-memory dataset and runs the built-in faithfulness metric with `req_llm`.
