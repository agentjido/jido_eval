# AGENT.md - Jido Eval Development Guide

Jido Eval is an Elixir package for evaluating LLMs. It follows the Ragas SDK (Python) pattern. It is designed for use within the Jido Ecosystem.

## Commands

- **Test**: `mix test` (all), `mix test test/path/to/specific_test.exs` (single file), `mix test --trace` (verbose)
- **Lint**: `mix credo` (basic), `mix credo --strict` (strict mode)
- **Format**: `mix format` (format code), `mix format --check-formatted` (verify formatting)
- **Quality**: `mix quality` or `mix q` (runs format, compile, dialyzer, credo, doctor, docs)
- **Compile**: `mix compile` (basic), `mix compile --warnings-as-errors` (strict)
- **Type Check**: `mix dialyzer --format dialyxir`
- **Coverage**: `mix test --cover` (basic), `mix coveralls.html` (HTML report)
- **Docs**: `mix docs` (generate documentation)

## SDLC

- **Coverage Goal**: Test coverage goal should be 80%+
- **Code Quality**: Use `mix quality` to run all checks
  - Fix all compiler warnings
  - Fix all dialyzer warnings
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
- **Imports**: Group aliases at module top, prefer explicit over wildcard imports
- **Naming**: `snake_case` for functions/variables, `PascalCase` for modules
- **Logging**: Avoid Logger metadata - integrate all fields into log message strings instead of using keyword lists

## Architecture

__TODO__

## Public API Overview

__TODO__

## Data Architecture

__TODO__

## Jido AI Integration

This package uses `jido_ai` for all LLM interactions. Follow these patterns:

### Text Generation

```elixir
# Simple text generation
{:ok, response} = Jido.AI.generate_text("openai:gpt-4o", "Evaluate this response")

# With rich messages
import Jido.AI.Messages
messages = [
  system("You are an evaluation expert"),
  user("Rate this response: #{response}")
]
{:ok, evaluation} = Jido.AI.generate_text("openai:gpt-4o", messages)
```

### Structured Data Generation

```elixir
# Schema-validated evaluation results
schema = [
  score: [type: :float, required: true],
  reasoning: [type: :string, required: true],
  categories: [type: {:list, :string}, default: []]
]

{:ok, result} = Jido.AI.generate_object(
  "openai:gpt-4o",
  "Evaluate this response",
  schema
)
```

### Model Specifications

Use these formats consistently:
- String: `"openai:gpt-4o"` or `"anthropic:claude-3-5-sonnet-20241022"`
- Tuple: `{:openai, model: "gpt-4o", temperature: 0.1}` (for evaluations requiring consistency)
- Struct: `%Jido.AI.Model{}` (when building complex configurations)

### Configuration

Access provider keys via:
- `Jido.AI.api_key(:openai)` - Get API key for provider
- `Jido.AI.config([:openai, :api_key], nil)` - Get config with fallback

