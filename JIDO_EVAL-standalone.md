# Jido Eval Implementation Plan
## Ragas SDK → Pure Elixir Port

This document outlines the step-by-step implementation plan to port the Ragas Python SDK to idiomatic Elixir as `jido_eval`. Each phase builds incrementally toward a fully-featured LLM evaluation framework.

## Overview

**Goal**: Create a pure Elixir LLM evaluation library that mirrors Ragas' developer experience while leveraging Elixir's concurrency, OTP, and functional programming strengths.

**Architecture**: Functional facade with `Jido.Eval.evaluate/2` backed by OTP processes, integrated with `jido_ai` for LLM calls.

## Target Public API

```elixir
# Quick evaluation with defaults
{:ok, result} = Jido.Eval.evaluate(dataset)

# Custom configuration
{:ok, result} = Jido.Eval.evaluate(dataset, 
  metrics: [:faithfulness, :context_precision],
  llm: "openai:gpt-4o",
  run_config: %Jido.Eval.RunConfig{timeout: 30_000}
)

# Access results
IO.inspect(result)  # %{faithfulness: 0.892, context_precision: 0.817}
scores = result["faithfulness"]  # [0.9, 0.85, 0.91, ...]
```

## Phase Breakdown

### Phase 1 – Core Data Layer (Week 1)

#### Step 1.1: Sample Data Structures
**Coding Plan:**
- `Jido.Eval.Sample.SingleTurn` using TypedStruct and leveraging `Jido.AI.Message`:
  ```elixir
  defmodule Jido.Eval.Sample.SingleTurn do
    use TypedStruct
    
    typedstruct do
      field :user_input, Jido.AI.Message.t() | String.t() | nil
      field :retrieved_contexts, [String.t()] | nil
      field :reference_contexts, [String.t()] | nil
      field :response, Jido.AI.Message.t() | String.t() | nil
      field :multi_responses, [String.t()] | nil
      field :reference, String.t() | nil
      field :rubrics, %{String.t() => String.t()} | nil
    end
  end
  ```
- `Jido.Eval.Sample.MultiTurn` using `[Jido.AI.Message.t()]` for conversation flows
- **Leverage existing** `Jido.AI.Message` instead of creating custom message hierarchy
- Helper functions to convert between string and Message formats
- Validation functions using pattern matching and guards

**Testing Approach:**
- Property-based tests with StreamData for sample creation
- Round-trip serialization tests (struct → map → struct)
- Invalid data rejection tests

**Acceptance Criteria:**
- All sample types compile with Dialyzer
- 95% branch coverage on data validation
- Clear error messages for invalid samples

#### Step 1.2: Dataset Protocol & Adapters
**Coding Plan:**
- `Jido.Eval.Dataset` protocol for pluggable data sources:
  ```elixir
  defprotocol Jido.Eval.Dataset do
    @doc "Convert dataset to stream of samples"
    def to_stream(dataset)
    @doc "Get sample type for validation"  
    def sample_type(dataset)
    @doc "Get sample count for progress tracking"
    def count(dataset)
  end
  ```
- Default implementations:
  - `Jido.Eval.Dataset.InMemory` - List-based dataset
  - `Jido.Eval.Dataset.JSONL` - Streaming JSONL reader
  - `Jido.Eval.Dataset.CSV` - CSV file adapter
- Future extensibility for Ecto, Ash, etc.

**Testing Approach:**
- Protocol implementation tests for each adapter
- Round-trip tests for format conversions
- Streaming performance tests with large datasets
- Error handling for malformed data

**Acceptance Criteria:**
- All adapters implement the protocol correctly
- Streaming preserves memory usage (<50MB for any dataset size)
- Format conversions preserve data integrity
- Performance: >1000 samples/sec for pure data conversion

### Phase 2 – Jido AI Integration (Week 1-2)

#### Step 2.1: LLM Integration with Retry Policy
**Coding Plan:**
- `Jido.Eval.LLM` module wrapping `Jido.AI.generate_text/3`
- `Jido.Eval.RetryPolicy` using NimbleOptions-validated config:
  ```elixir
  defmodule Jido.Eval.RetryPolicy do
    use TypedStruct
    
    typedstruct do
      field :max_retries, non_neg_integer(), default: 3
      field :base_delay, non_neg_integer(), default: 1000
      field :max_delay, non_neg_integer(), default: 60_000
      field :jitter, boolean(), default: true
      field :retryable_errors, [atom()], default: [:timeout, :rate_limit]
    end
  end
  ```
- Integrate retry policy at LLM boundary, not within metrics
- Support structured generation for metrics requiring JSON
- Response caching with Req steps for dev/test determinism

**Testing Approach:**
- Use `Req.Test` to stub HTTP calls with retry scenarios
- Test error propagation and normalization
- Verify integration with different `jido_ai` providers
- Test caching behavior and cache invalidation

**Acceptance Criteria:**
- All LLM calls go through single abstraction with retry
- Provider switching requires only model spec change
- Retries happen at network boundary, not metric level
- Caching works transparently in test/dev environments

### Phase 3 – Execution Configuration (Week 2)

#### Step 3.1: RunConfig
**Coding Plan:**
- `Jido.Eval.RunConfig` TypedStruct for execution parameters:
  ```elixir
  defmodule Jido.Eval.RunConfig do
    use TypedStruct
    
    typedstruct do
      field :timeout, non_neg_integer(), default: 180_000
      field :max_workers, non_neg_integer(), default: 16
      field :seed, non_neg_integer(), default: 42
      field :retry_policy, Jido.Eval.RetryPolicy.t(), default: %Jido.Eval.RetryPolicy{}
      field :enable_caching, boolean(), default: false
      field :telemetry_prefix, [atom()], default: [:jido, :eval]
    end
  end
  ```
- Remove retry logic from RunConfig (moved to LLM boundary)
- Add observability and caching configuration

**Testing Approach:**
- Configuration validation tests
- Default value verification
- Integration with retry policy

**Acceptance Criteria:**
- Clean separation of execution and retry concerns
- Configuration validates properly
- Sensible defaults for all environments

### Phase 4 – Metric System (Week 2-3)

#### Step 4.1: Metric Behaviour
**Coding Plan:**
- Define `Jido.Eval.Metric` behaviour:
  ```elixir
  @callback required_columns() :: %{atom() => MapSet.t(String.t())}
  @callback init(RunConfig.t()) :: :ok | {:error, term()}
  @callback score(Sample.t(), map(), [term()]) :: {:ok, float()} | {:error, term()}
  ```
- Marker behaviours: `WithLLM`, `WithEmbeddings`
- `use Jido.Eval.Metric` macro for auto-registration

**Testing Approach:**
- Test behaviour implementation validation
- Registry functionality tests
- Mock metric implementations for testing

**Acceptance Criteria:**
- Metrics auto-register when modules loaded
- Clear error messages for incomplete implementations
- Registry supports name-based lookup

#### Step 4.2: Metric Registry
**Coding Plan:**
- `Jido.Eval.Metric.Registry` using `:persistent_term`
- Auto-registration via `use` macro
- Name conflict detection and resolution
- Default metric discovery with `list_metrics/0`

**Testing Approach:**
- Test registration during module compilation
- Duplicate name handling
- Registry persistence across process restarts

**Acceptance Criteria:**
- `Registry.find/1` returns implementing module
- No silent name conflicts
- Fast lookup performance (sub-microsecond)

### Phase 4 – Metric System (Week 2-3)

#### Step 4.1: Metric Behaviour & Registry
**Coding Plan:**
- Define `Jido.Eval.Metric` behaviour with simplified interface:
  ```elixir
  @callback required_fields() :: [:question | :response | :retrieved_contexts | :reference | ...]
  @callback score(sample, RunConfig.t()) :: {:ok, float()} | {:error, term()}
  ```
- `use Jido.Eval.Metric` macro for auto-registration:
  ```elixir
  defmacro __using__(opts) do
    quote do
      @behaviour Jido.Eval.Metric
      @metric_name unquote(opts[:name]) || __MODULE__ |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()
      @after_compile Jido.Eval.Metric
      def name, do: @metric_name
    end
  end
  ```
- ETS-based registry (not `:persistent_term`) for hot-code reload safety
- Marker behaviours: `WithLLM`, `WithEmbeddings` for dependency injection

**Testing Approach:**
- Test behaviour implementation validation
- Registry functionality tests with hot reloads
- Mock metric implementations for testing
- ETS table cleanup between tests

**Acceptance Criteria:**
- Metrics auto-register via ETS during compilation
- Hot-code reloads work without VM restart
- Clear error messages for incomplete implementations
- Registry supports fast name-based lookup

### Phase 5 – Core Metrics Implementation (Week 3)

#### Step 5.1: Implement Core RAG Metrics
**Coding Plan:**
- Port core RAG metrics from Ragas:
  - `Jido.Eval.Metric.Faithfulness` - Factual consistency with context
  - `Jido.Eval.Metric.ContextPrecision` - Relevance of retrieved contexts  
  - `Jido.Eval.Metric.ContextRecall` - Coverage of relevant information
  - `Jido.Eval.Metric.ContextEntitiesRecall` - Entity recall in contexts
  - `Jido.Eval.Metric.AnswerRelevancy` - Response relevance to question
  - `Jido.Eval.Metric.NoiseSensitivity` - Impact of irrelevant information
- Convert Python prompt templates to Elixir heredocs
- Implement required column declarations
- Add LLM/embedding dependencies as needed

#### Step 5.2: Implement Agent/Tool Metrics  
**Coding Plan:**
- Port agent evaluation metrics:
  - `Jido.Eval.Metric.TopicAdherence` - Staying on intended topic
  - `Jido.Eval.Metric.ToolCallAccuracy` - Correctness of tool calls
  - `Jido.Eval.Metric.AgentGoalAccuracy` - Goal achievement assessment

#### Step 5.3: Implement Comparison Metrics
**Coding Plan:**
- Port semantic comparison metrics:
  - `Jido.Eval.Metric.FactualCorrectness` - Factual accuracy assessment
  - `Jido.Eval.Metric.SemanticSimilarity` - Semantic similarity scoring
  - `Jido.Eval.Metric.AspectCritic` - Aspect-specific evaluation
  - `Jido.Eval.Metric.SimpleCriteria` - Simple criteria scoring
  - `Jido.Eval.Metric.RubricsScoring` - Rubric-based evaluation

**Testing Approach:**
- Golden dataset tests with expected score ranges
- Stub LLM responses for deterministic scoring
- Property-based tests for score bounds (0.0-1.0)

**Acceptance Criteria:**
- All metrics return scores in [0.0, 1.0] range
- Metrics handle missing optional fields gracefully
- Performance: single sample scored in <5 seconds

### Phase 6 – Evaluation Engine (Week 3-4)

#### Step 6.1: Task.Supervisor-Based Execution Engine
**Coding Plan:**
- `Jido.Eval.Exec` using `Task.Supervisor.async_stream_nolink/4`:
  ```elixir
  defmodule Jido.Eval.Exec do
    require Logger
    
    @spec run(Jido.Eval.Dataset.t(), [module()], RunConfig.t(), keyword()) :: Enumerable.t()
    def run(dataset, metric_modules, %RunConfig{} = cfg, opts \\ []) do
      {:ok, sup} = Task.Supervisor.start_link(name: __MODULE__.Supervisor)
      
      dataset
      |> Jido.Eval.Dataset.to_stream()
      |> Task.Supervisor.async_stream_nolink(
        __MODULE__.Supervisor,
        &evaluate_sample(&1, metric_modules, cfg),
        max_concurrency: cfg.max_workers,
        ordered: false,
        timeout: cfg.timeout
      )
    end
    
    defp evaluate_sample(sample, metrics, cfg) do
      # Emit telemetry events, evaluate metrics, handle errors
    end
  end
  ```
- Built-in backpressure and fault isolation
- Progress tracking via stream enumeration
- Telemetry events: `[:jido, :eval, :run, :start|:stop]`, `[:jido, :eval, :metric, :stop]`

**Testing Approach:**
- Fault tolerance tests (task crashes)
- Concurrency tests with controlled timing
- Error injection and recovery tests
- Performance benchmarks vs sequential execution
- Memory usage tests with large datasets
- Telemetry event emission verification

**Acceptance Criteria:**
- Evaluation completes with bounded concurrency
- Individual task failures don't crash evaluation
- Built-in backpressure prevents memory issues
- Results surface as they complete (ordered: false)
- Clean telemetry integration for observability

#### Step 6.3: Main Evaluation Function
**Coding Plan:**
- `Jido.Eval.evaluate/2` with options:
  ```elixir
  @spec evaluate(Dataset.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def evaluate(dataset, opts \\ []) do
    # metrics, llm, embeddings, run_config, etc.
  end
  ```
- Column validation before execution
- Metric dependency injection (LLM/embeddings)
- Result aggregation and error handling

**Testing Approach:**
- Integration tests with real metrics
- Error path testing (missing columns, etc.)
- Large dataset stress tests

**Acceptance Criteria:**
- API matches Ragas evaluate() signature
- Comprehensive error messages
- Graceful degradation on partial failures

### Phase 7 – Result Reporting (Week 4)

#### Step 7.1: Rich Result Structure
**Coding Plan:**
- `Jido.Eval.Result` struct with comprehensive data:
  ```elixir
  defmodule Jido.Eval.Result do
    use TypedStruct
    
    typedstruct do
      field :summary, %{atom() => %{avg: float(), stdev: float(), p95: float()}}, default: %{}
      field :per_sample, [%{id: term(), metrics: %{atom() => float()}, errors: [term()]}], default: []
      field :errors, [%{metric: atom(), sample_id: term(), reason: term()}], default: []
      field :metadata, %{start_time: DateTime.t(), duration_ms: non_neg_integer(), samples_total: non_neg_integer()}, default: %{}
    end
  end
  ```
- Implement protocols:
  - `Access` for `result["metric_name"]` backward compatibility
  - `Enumerable` for streaming per-sample results
  - `Inspect` for pretty printing with summary focus
  - `Jason.Encoder` for JSON export
- Helper functions: `avg/2`, `to_csv/2`, `successful_samples/1`, `failed_samples/1`

**Testing Approach:**
- Protocol implementation tests
- Statistical calculation accuracy tests
- Format conversion accuracy tests
- Pretty printing visual verification

**Acceptance Criteria:**
- Result displays summary by default: `%{faithfulness: %{avg: 0.91, stdev: 0.05, p95: 0.98}}`
- Access protocol supports legacy `result["faithfulness"]` returning avg
- CSV export includes per-sample and error data
- JSON serialization preserves all information

## Development Standards (All Phases)

### Code Quality Requirements
- **Test Coverage**: ≥90% line coverage enforced in CI
- **Type Safety**: All public functions have `@spec`
- **Documentation**: All public modules/functions have `@doc`
- **Linting**: Credo strict mode with zero high-priority issues
- **Type Checking**: Dialyzer with zero warnings

### Testing Strategy
- **Unit Tests**: ExUnit with async where possible
- **Integration Tests**: Real `jido_ai` integration (stubbed HTTP)
- **Property Tests**: StreamData for data validation
- **Performance Tests**: Tagged `:benchmark` (excluded from CI)
- **Golden Tests**: Known good outputs for metric validation

### Development Workflow
- Each step = separate Git branch
- PR template includes testing checklist
- Feature flags for incomplete functionality
- Parallel development where dependencies allow

## API Design Goals

### Familiarity with Ragas
```python
# Ragas (Python)
result = evaluate(dataset, metrics=[faithfulness, context_precision])
```

```elixir
# Jido.Eval (Elixir)
{:ok, result} = Jido.Eval.evaluate(dataset, metrics: [:faithfulness, :context_precision])
```

### Elixir Idioms
- Tupled returns: `{:ok, result} | {:error, reason}`
- Keyword options instead of named parameters
- Protocol implementations for data access
- OTP supervision for reliability

### Integration Points
- **jido_ai**: All LLM calls via `Jido.AI.generate_text/3` with retry at boundary
- **jido_ai**: Reuse `Jido.AI.Message` and `Jido.AI.ContentPart` for conversation data
- **Telemetry**: Standard telemetry events for observability and monitoring
- **Req**: Response caching for cost control and deterministic testing
- **ETS**: Hot-reloadable metric registry
- **JSON**: Native Jason encoding/decoding
- **CSV**: Standard library or external (CSV.ex)

## Success Metrics

### Performance Targets
- **Data Processing**: >1000 samples/sec for pure data conversion and validation
- **LLM-Free Metrics**: >100 samples/sec for statistical/lexical metrics
- **LLM-Based Metrics**: Steady concurrency respecting provider rate limits
- **Memory**: <50MB additional overhead regardless of dataset size (streaming)
- **Latency**: <5s per sample for simple LLM metrics under normal conditions

### Quality Targets
- **Reliability**: >99% evaluation completion rate with graceful error handling
- **Accuracy**: Scores within 5% of Ragas reference implementation  
- **Usability**: <10 lines of code for basic evaluation
- **Observability**: Full telemetry integration for monitoring and debugging

## End State Vision

After Phase 7, `jido_eval` provides:

1. **Familiar API**: Ragas users can adapt quickly
2. **Elixir Native**: Leverages OTP, concurrency, fault tolerance
3. **Well Integrated**: Seamless use with `jido_ai` and broader Jido ecosystem
4. **Core Complete**: Full evaluation workflow with four essential metrics
5. **Extensible**: Clear patterns for custom metrics

The implementation enables LLM evaluation workflows that are both familiar to Python developers and natural for Elixir applications.
