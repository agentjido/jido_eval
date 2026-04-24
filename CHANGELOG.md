# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Conventional Commits](https://www.conventionalcommits.org/).

## [0.1.0] - Unreleased

### Added

- Initial Ragas-like evaluation harness for single-turn and multi-turn samples.
- Built-in faithfulness and context precision metrics.
- Dataset adapters for in-memory samples, JSONL, and CSV.
- Structured judge calls backed by `req_llm`.
- `llm_db` model spec support.
- Golden and live eval test coverage.

### Changed

- Core structs use Zoi schemas and Zoi-derived struct fields.
- Basic eval judging uses `req_llm` directly instead of `jido_ai`.
