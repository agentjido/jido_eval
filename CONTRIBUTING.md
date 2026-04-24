# Contributing

Jido Eval follows the shared Jido package quality standards:

https://jido.run/docs/contributors/package-quality-standards

## Development Setup

```bash
mix setup
```

Git hooks are not installed automatically. Maintainers can install them explicitly from the primary checkout:

```bash
mix install_hooks
```

## Quality Gate

Before opening a pull request, run:

```bash
mix quality
mix test
mix coveralls
mix docs
mix deps.audit
mix deps.unlock --check-unused
```

Live evals are excluded by default. If you have provider keys in `.env`, run:

```bash
mix test --include live_eval
```

## Commit Style

Use Conventional Commits:

```bash
feat: add evaluator metric
fix: handle empty retrieved contexts
docs: clarify live eval setup
refactor: simplify judge metadata
test: cover mixed metric failures
chore: update dependencies
ci: add release workflow
```

## Release Workflow

Releases are GitOps-driven and published from CI. Maintainers prepare release metadata with `git_ops`, push the release
commit and tag, and let `.github/workflows/release.yml` publish the Hex package using `HEX_API_KEY`.

## Project Conventions

- Public modules live under `Jido.Eval`.
- Core structs use Zoi schemas with `@type`, `@enforce_keys`, `defstruct`, and `schema/0`.
- Public functions have `@doc` and `@spec`.
- Errors are returned as `{:ok, value}` or `{:error, reason}` tuples.
- Built-in LLM judge behavior goes through `req_llm` and preserves auditable metadata.
- Example code lives under `examples/`, not `lib/`.
