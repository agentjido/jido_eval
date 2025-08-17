# Jido Eval Implementation Plan
## Ragas SDK → Pure Elixir Port with Pluggable Architecture

This document outlines the step-by-step implementation plan to port the Ragas Python SDK to idiomatic Elixir as `jido_eval`. Each phase builds incrementally toward a fully-featured, enterprise-grade LLM evaluation framework with pluggable components and production observability.

## Overview

**Goal**: Create a pure Elixir LLM evaluation library that mirrors Ragas' developer experience while leveraging Elixir's concurrency, OTP, fault tolerance, and pluggable architecture patterns inspired by ex_eval.

**Architecture**: Simple functional facade with `Jido.Eval.evaluate/2` backed by supervised OTP processes, pluggable components (reporters, stores, broadcasters, processors), and integrated with `jido_ai` for LLM calls.

## Target Public API

```elixir
# Quick evaluation with defaults (simple Ragas-like API)
{:ok, result} = Jido.Eval.evaluate(dataset)

# Custom configuration with pluggable components
{:ok, result} = Jido.Eval.evaluate(dataset, 
  metrics: [:faithfulness, :context_precision],
  llm: "openai:gpt-4o",
  run_config: %Jido.Eval.RunConfig{timeout: 30_000},
  reporters: [{MyApp.JSONReporter, format: :json}],
  stores: [{MyApp.PostgresStore, table: "evaluations"}],
  broadcasters: [{Phoenix.PubSub, topic: "evals"}]
)

# Async evaluation with real-time monitoring
{:ok, run_id} = Jido.Eval.evaluate(dataset, sync: false)
:telemetry.attach([:jido, :eval, :progress], fn event, measurements, metadata, _ ->
  IO.puts("Progress: #{metadata.completed}/#{metadata.total}")
end)

# Composite metrics for consensus scoring
{:ok, result} = Jido.Eval.evaluate(dataset,
  metrics: [{:consensus_faithfulness, strategy: :majority, 
             children: [{:faithfulness, model: "openai:gpt-4o"}, 
                       {:faithfulness, model: "anthropic:claude-3-5-sonnet"}]}]
)

# Access rich results with statistics
IO.inspect(result.summary)  # %{faithfulness: %{avg: 0.892, p95: 0.95, p99: 0.98, pass_rate: 0.8}}
scores = result["faithfulness"]  # Legacy access returns averages
latency = result.metadata.latency  # %{avg_ms: 245, p95_ms: 890}
```

## Phase Breakdown

### Phase 0 – Foundation Bootstrap (Week 0)

#### Step 0.1: Configuration & Component Behaviours
**Coding Plan:**
- `Jido.Eval.Config` runtime struct for pluggable architecture:
  ```elixir
  defmodule Jido.Eval.Config do
    use TypedStruct
    
    typedstruct do
      field :run_id, String.t(), default: nil  # Auto-generated UUID if nil
      field :run_config, Jido.Eval.RunConfig.t(), default: %Jido.Eval.RunConfig{}
      field :reporters, [{module(), keyword()}], default: [{Jido.Eval.Reporter.Console, []}]
      field :stores, [{module(), keyword()}], default: []
      field :broadcasters, [{module(), keyword()}], default: [{Jido.Eval.Broadcaster.Telemetry, prefix: [:jido, :eval]}]
      field :processors, [{module(), :pre | :post, keyword()}], default: []
      field :middleware, [module()], default: [Jido.Eval.Middleware.Tracing]
      field :tags, %{String.t() => String.t()}, default: %{}  # Experiment tracking
      field :notes, String.t(), default: ""
    end
  end
  ```

- Core behaviours with `@optional_callbacks`:
  ```elixir
  defmodule Jido.Eval.Reporter do
    @callback handle_summary(Jido.Eval.Result.t(), keyword()) :: :ok | {:error, term()}
    @callback handle_sample(sample_result :: map(), keyword()) :: :ok | {:error, term()}
    @optional_callbacks handle_sample: 2
  end
  
  defmodule Jido.Eval.Store do
    @callback init(keyword()) :: {:ok, state :: term()} | {:error, term()}
    @callback persist(data :: term(), state :: term()) :: {:ok, state :: term()} | {:error, term()}
    @callback finalize(state :: term()) :: :ok | {:error, term()}
  end
  
  defmodule Jido.Eval.Broadcaster do
    @callback publish(event :: atom(), metadata :: map(), keyword()) :: :ok | {:error, term()}
  end
  
  defmodule Jido.Eval.Processor do
    @callback process(sample :: map(), stage :: :pre | :post, keyword()) :: {:ok, map()} | {:error, term()}
  end
  
  defmodule Jido.Eval.Middleware do
    @callback call(sample :: map(), metric_fn :: function(), keyword()) :: {:ok, float()} | {:error, term()}
  end
  ```

- `Jido.Eval.ComponentRegistry` (ETS-based):
  ```elixir
  defmodule Jido.Eval.ComponentRegistry do
    @table_name :jido_eval_components
    
    def register(type, module) when type in [:reporter, :store, :broadcaster, :processor, :middleware]
    def lookup(type, name)
    def list(type)
  end
  ```

**Testing Approach:**
- Behaviour compilation and validation tests
- Registry functionality with component discovery
- Default component initialization tests

**Acceptance Criteria:**
- All behaviours compile with comprehensive documentation
- Registry supports hot-code reloading
- Default implementations work out of the box

### Phase 1 – Core Data Layer (Week 1)

#### Step 1.1: Sample Data Structures
**Coding Plan:**
- `Jido.Eval.Sample.SingleTurn` using TypedStruct and leveraging `Jido.AI.Message`:
  ```elixir
  defmodule Jido.Eval.Sample.SingleTurn do
    use TypedStruct
    
    typedstruct do
      field :id, String.t() | nil  # Sample tracking
      field :user_input, Jido.AI.Message.t() | String.t() | nil
      field :retrieved_contexts, [String.t()] | nil
      field :reference_contexts, [String.t()] | nil
      field :response, Jido.AI.Message.t() | String.t() | nil
      field :multi_responses, [String.t()] | nil
      field :reference, String.t() | nil
      field :rubrics, %{String.t() => String.t()} | nil
      field :tags, %{String.t() => String.t()}, default: %{}  # Sample-level metadata
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

#### Step 3.1: Enhanced RunConfig
**Coding Plan:**
- `Jido.Eval.RunConfig` TypedStruct with run tracking:
  ```elixir
  defmodule Jido.Eval.RunConfig do
    use TypedStruct
    
    typedstruct do
      field :run_id, String.t(), default: nil  # Auto-generated if nil
      field :timeout, non_neg_integer(), default: 180_000
      field :max_workers, non_neg_integer(), default: 16
      field :seed, non_neg_integer(), default: 42
      field :retry_policy, Jido.Eval.RetryPolicy.t(), default: %Jido.Eval.RetryPolicy{}
      field :enable_caching, boolean(), default: false
      field :telemetry_prefix, [atom()], default: [:jido, :eval]
      field :enable_real_time_events, boolean(), default: true
    end
  end
  ```

**Testing Approach:**
- Configuration validation tests
- Default value verification
- Integration with retry policy

**Acceptance Criteria:**
- Clean separation of execution and retry concerns
- Configuration validates properly
- Sensible defaults for all environments

### Phase 4 – Pluggable Components & Metric System (Week 2-3)

#### Step 4.1: Core Component Implementations
**Coding Plan:**
- **Default Reporters:**
  ```elixir
  defmodule Jido.Eval.Reporter.Console do
    use Jido.Eval.Reporter
    
    def handle_summary(result, _opts) do
      # Pretty table with metric averages and pass rates
    end
  end
  
  defmodule Jido.Eval.Reporter.JSON do
    use Jido.Eval.Reporter
    
    def handle_summary(result, opts) do
      # Write JSON to file or IO device
    end
  end
  ```

- **Default Stores:**
  ```elixir
  defmodule Jido.Eval.Store.InMemory do
    use Jido.Eval.Store
    # No-op for testing
  end
  
  defmodule Jido.Eval.Store.File do
    use Jido.Eval.Store
    # Writes Result JSON + per-sample CSV
  end
  ```

- **Default Broadcasters:**
  ```elixir
  defmodule Jido.Eval.Broadcaster.Telemetry do
    use Jido.Eval.Broadcaster
    
    def publish(event, metadata, opts) do
      prefix = Keyword.get(opts, :prefix, [:jido, :eval])
      :telemetry.execute(prefix ++ [event], %{}, metadata)
    end
  end
  
  defmodule Jido.Eval.Broadcaster.PubSub do
    use Jido.Eval.Broadcaster
    # Phoenix.PubSub integration
  end
  ```

- **Default Processors:**
  ```elixir
  defmodule Jido.Eval.Processor.NormalizeStrings do
    use Jido.Eval.Processor
    
    def process(sample, :pre, _opts) do
      # Trim whitespace, normalize encoding
    end
  end
  ```

- **Default Middleware:**
  ```elixir
  defmodule Jido.Eval.Middleware.Tracing do
    use Jido.Eval.Middleware
    
    def call(sample, metric_fn, opts) do
      # Open telemetry span, execute metric, close span
    end
  end
  ```

**Testing Approach:**
- Component behavior implementation tests
- Integration tests with pipeline composition
- Performance tests for overhead measurement

**Acceptance Criteria:**
- All default components work without configuration
- Components can be swapped via configuration
- Zero performance impact when components disabled

#### Step 4.2: Metric Behaviour & Registry
**Coding Plan:**
- Define `Jido.Eval.Metric` behaviour with simplified interface:
  ```elixir
  @callback required_fields() :: [:question | :response | :retrieved_contexts | :reference | ...]
  @callback score(sample, Jido.Eval.Config.t()) :: {:ok, float()} | {:error, term()}
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
- ETS-based registry with hot-code reload support
- Marker behaviours: `WithLLM`, `WithEmbeddings` for dependency injection

#### Step 4.3: Composite Metrics
**Coding Plan:**
- `Jido.Eval.CompositeMetric` behaviour:
  ```elixir
  @callback child_metrics() :: [{module() | atom(), keyword()}]
  @callback aggregate([{metric_name :: atom(), score :: float()}], keyword()) :: {:ok, float()} | {:error, term()}
  ```
- Built-in composite strategies:
  ```elixir
  defmodule Jido.Eval.CompositeMetric.WeightedAverage do
    use Jido.Eval.CompositeMetric
    
    def child_metrics, do: []  # Configured at runtime
    def aggregate(scores, opts) do
      weights = Keyword.get(opts, :weights, [])
      # Weighted average calculation
    end
  end
  
  defmodule Jido.Eval.CompositeMetric.MajorityVote do
    use Jido.Eval.CompositeMetric
    
    def aggregate(scores, opts) do
      threshold = Keyword.get(opts, :threshold, 0.5)
      # Consensus calculation with agreement metadata
    end
  end
  ```

**Testing Approach:**
- Composite metric behavior validation
- Agreement ratio calculations
- Fault tolerance with partial failures

**Acceptance Criteria:**
- Composite metrics auto-register like regular metrics
- Consensus strategies handle disagreement gracefully
- Metadata includes agreement ratios and individual votes

### Phase 5 – Core Metrics Implementation (Week 3)

#### Step 5.1: Implement Core RAG Metrics
**Coding Plan:**
- Port core RAG metrics from Ragas with telemetry integration:
  - `Jido.Eval.Metric.Faithfulness` - Factual consistency with context
  - `Jido.Eval.Metric.ContextPrecision` - Relevance of retrieved contexts  
  - `Jido.Eval.Metric.ContextRecall` - Coverage of relevant information
  - `Jido.Eval.Metric.ContextEntitiesRecall` - Entity recall in contexts
  - `Jido.Eval.Metric.AnswerRelevancy` - Response relevance to question
  - `Jido.Eval.Metric.NoiseSensitivity` - Impact of irrelevant information
- Convert Python prompt templates to Elixir heredocs
- Emit telemetry events: `[:jido, :eval, :metric, :start|:stop]` with metadata
- Add one composite example: `ConsensusFaithfulness`

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
- Composite metric consensus validation

**Acceptance Criteria:**
- All metrics return scores in [0.0, 1.0] range
- Metrics handle missing optional fields gracefully
- Performance: single sample scored in <5 seconds
- Composite metrics provide agreement metadata

### Phase 6 – Supervision & Execution Engine (Week 3-4)

#### Step 6.1: OTP Supervision Hierarchy with Process Registry
**Coding Plan:**
- Supervision tree per evaluation run:
  ```elixir
  defmodule Jido.Eval.RunSupervisor do
    use DynamicSupervisor
    
    def start_link(config) do
      DynamicSupervisor.start_link(__MODULE__, config, name: via_tuple(config.run_id))
    end
    
    def init(_config) do
      DynamicSupervisor.init(strategy: :one_for_one)
    end
    
    defp via_tuple(run_id), do: {:via, Registry, {Jido.Eval.RunRegistry, run_id}}
  end
  
  # Child processes:
  # ├─ Jido.Eval.Broadcaster.Supervisor  (starts configured broadcasters)
  # ├─ Jido.Eval.Store.Supervisor        (starts configured stores)  
  # └─ Jido.Eval.WorkerSupervisor        (Task.Supervisor for sample workers)
  ```

- Process registry for run tracking:
  ```elixir
  defmodule Jido.Eval.RunRegistry do
    def start_link do
      Registry.start_link(keys: :unique, name: __MODULE__)
    end
    
    def lookup_run(run_id)
    def list_active_runs()
    def get_run_status(run_id)  # %{progress: 0.75, errors: 2}
  end
  ```

#### Step 6.2: Enhanced Worker Process
**Coding Plan:**
- `Jido.Eval.Worker` with full pipeline:
  ```elixir
  defmodule Jido.Eval.Worker do
    def evaluate_sample(sample, metrics, config) do
      with {:ok, processed_sample} <- apply_processors(sample, :pre, config),
           {:ok, scores} <- evaluate_metrics_with_middleware(processed_sample, metrics, config),
           {:ok, final_sample} <- apply_processors(processed_sample, :post, config) do
        
        # Broadcast sample completion
        broadcast_sample_result(config, sample.id, scores)
        
        # Persist to stores
        persist_sample_result(config, final_sample, scores)
        
        {:ok, %{sample_id: sample.id, scores: scores}}
      end
    end
    
    defp evaluate_metrics_with_middleware(sample, metrics, config) do
      # Apply middleware chain to each metric call
      # Emit telemetry spans per metric
    end
  end
  ```

#### Step 6.3: Main Evaluation Function with Async Support
**Coding Plan:**
- `Jido.Eval.evaluate/2` with sync/async modes:
  ```elixir
  @spec evaluate(Dataset.t(), keyword()) :: {:ok, Result.t() | String.t()} | {:error, term()}
  def evaluate(dataset, opts \\ []) do
    config = build_config(opts)
    
    case Keyword.get(opts, :sync, true) do
      true ->
        # Block and return Result struct (original behavior)
        run_evaluation_sync(dataset, config)
      false ->
        # Return run_id for async tracking
        {:ok, run_id} = start_evaluation_async(dataset, config)
        {:ok, run_id}
    end
  end
  ```
- Real-time progress tracking via Registry and telemetry
- Column validation before execution
- Graceful degradation on partial failures

**Testing Approach:**
- Fault tolerance tests (worker crashes, supervisor restarts)
- Concurrency tests with controlled timing
- Registry-based progress tracking tests
- Memory usage tests with large datasets
- Async/sync mode integration tests

**Acceptance Criteria:**
- Evaluation completes with bounded concurrency and fault isolation
- Process registry enables real-time progress querying
- Both sync and async modes work seamlessly
- Individual worker failures don't crash evaluation
- Clean separation of run management and sample processing

### Phase 7 – Result Aggregation & Advanced Observability (Week 4)

#### Step 7.1: Rich Result Structure with Statistics
**Coding Plan:**
- Enhanced `Jido.Eval.Result` struct:
  ```elixir
  defmodule Jido.Eval.Result do
    use TypedStruct
    
    typedstruct do
      field :run_id, String.t()
      field :summary, %{atom() => %{
        avg: float(), stdev: float(), p50: float(), p95: float(), p99: float(),
        pass_rate: float(), count: non_neg_integer()
      }}, default: %{}
      field :per_sample, [%{id: term(), metrics: %{atom() => float()}, errors: [term()], latency_ms: non_neg_integer()}], default: []
      field :errors, [%{metric: atom(), sample_id: term(), reason: term(), timestamp: DateTime.t()}], default: []
      field :latency, %{avg_ms: float(), p95_ms: float(), max_ms: float()}, default: %{}
      field :by_tag, %{String.t() => map()}, default: %{}  # Tag-based breakdowns
      field :metadata, %{
        start_time: DateTime.t(), 
        finish_time: DateTime.t(), 
        duration_ms: non_neg_integer(), 
        samples_total: non_neg_integer(),
        samples_successful: non_neg_integer(),
        config: Jido.Eval.Config.t()
      }, default: %{}
    end
  end
  ```
- Implement protocols:
  - `Access` for `result["metric_name"]` backward compatibility
  - `Enumerable` for streaming per-sample results
  - `Inspect` for pretty printing with summary focus
  - `Jason.Encoder` for JSON export
- Helper functions: `pass_rate/2`, `to_csv/2`, `successful_samples/1`, `failed_samples/1`

#### Step 7.2: Advanced Observability & Monitoring
**Coding Plan:**
- **Telemetry Event Specification:**
  ```elixir
  # Run-level events
  [:jido, :eval, :run, :start]     # %{run_id, samples_total, config}
  [:jido, :eval, :run, :stop]      # %{run_id, duration_ms, result_summary}
  [:jido, :eval, :progress]        # %{run_id, completed, total, errors}
  
  # Sample-level events
  [:jido, :eval, :sample, :start]  # %{run_id, sample_id}
  [:jido, :eval, :sample, :stop]   # %{run_id, sample_id, scores, duration_ms}
  
  # Metric-level events  
  [:jido, :eval, :metric, :start]  # %{run_id, sample_id, metric, model}
  [:jido, :eval, :metric, :stop]   # %{run_id, sample_id, metric, score, duration_ms}
  ```

- **Dashboard Integration Recipe:**
  ```elixir
  # Example telemetry handler for real-time dashboards
  :telemetry.attach_many("jido-eval-dashboard", [
    [:jido, :eval, :progress],
    [:jido, :eval, :metric, :stop]
  ], &MyApp.Dashboard.handle_event/4, %{})
  ```

- **CLI Progress Integration:**
  ```elixir
  defmodule Jido.Eval.CLI.Progress do
    # ExTTY.Progress integration for console progress bars
  end
  ```

**Testing Approach:**
- Telemetry event emission verification
- Statistical calculation accuracy tests
- Real-time progress tracking tests
- Format conversion accuracy tests

**Acceptance Criteria:**
- Comprehensive telemetry events for production monitoring
- Statistical calculations match industry standards
- Real-time progress available via Registry and telemetry
- Rich result structure supports ML experiment tracking

#### Step 7.3: Mix Tasks & CLI Tools
**Coding Plan:**
- `mix jido.eval.run` task:
  ```elixir
  # Command line evaluation
  mix jido.eval.run path/to/dataset.jsonl --metrics faithfulness,context_precision --format json
  ```
- `mix jido.eval.attach` task:
  ```elixir
  # Real-time monitoring of running evaluation
  mix jido.eval.attach run_id
  ```
- Configuration validation and help commands

## Development Standards (All Phases)

### Code Quality Requirements
- **Test Coverage**: ≥90% line coverage enforced in CI
- **Type Safety**: All public functions have `@spec`
- **Documentation**: All public modules/functions have `@doc` with examples
- **Linting**: Credo strict mode with zero high-priority issues
- **Type Checking**: Dialyzer with zero warnings

### Testing Strategy
- **Unit Tests**: ExUnit with async where possible
- **Integration Tests**: Real `jido_ai` integration (stubbed HTTP)
- **Property Tests**: StreamData for data validation
- **Performance Tests**: Tagged `:benchmark` (excluded from CI)
- **Golden Tests**: Known good outputs for metric validation
- **Component Tests**: Pluggable behavior validation

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
# Jido.Eval (Elixir) - Same simplicity
{:ok, result} = Jido.Eval.evaluate(dataset, metrics: [:faithfulness, :context_precision])
```

### Enterprise Extensions (Optional)
```elixir
# Advanced configuration without breaking simple API
{:ok, result} = Jido.Eval.evaluate(dataset,
  metrics: [:faithfulness, {:consensus_accuracy, strategy: :majority}],
  reporters: [{MyApp.SlackReporter, channel: "#ml-ops"}],
  stores: [{MyApp.MLflowStore, experiment: "model-v2"}],
  broadcasters: [{Phoenix.PubSub, topic: "evaluations"}]
)
```

### Elixir Idioms
- Tupled returns: `{:ok, result} | {:error, reason}`
- Keyword options instead of named parameters
- Protocol implementations for data access
- OTP supervision for reliability
- Pluggable behaviors for extensibility

## Integration Points

- **jido_ai**: All LLM calls via `Jido.AI.generate_text/3` with retry at boundary
- **jido_ai**: Reuse `Jido.AI.Message` and `Jido.AI.ContentPart` for conversation data
- **Telemetry**: Comprehensive telemetry events for observability and monitoring
- **Registry**: Process registry for run tracking and distributed coordination
- **Req**: Response caching for cost control and deterministic testing
- **ETS**: Hot-reloadable component and metric registries
- **Phoenix PubSub**: Real-time event broadcasting for dashboards
- **JSON**: Native Jason encoding/decoding with protocol support
- **CSV**: Standard library or external (CSV.ex) for data export

## Success Metrics

### Performance Targets
- **Data Processing**: >1000 samples/sec for pure data conversion and validation
- **LLM-Free Metrics**: >100 samples/sec for statistical/lexical metrics
- **LLM-Based Metrics**: Steady concurrency respecting provider rate limits
- **Memory**: <50MB additional overhead regardless of dataset size (streaming)
- **Latency**: <5s per sample for simple LLM metrics under normal conditions
- **Component Overhead**: <5% performance impact for pluggable architecture

### Quality Targets
- **Reliability**: >99% evaluation completion rate with graceful error handling
- **Accuracy**: Scores within 5% of Ragas reference implementation  
- **Usability**: <3 lines of code for basic evaluation (maintaining Ragas simplicity)
- **Extensibility**: New components implementable with <20 lines of boilerplate
- **Observability**: Full telemetry integration for production monitoring

### Fault Tolerance
- **Isolation**: Individual worker failures don't impact other samples
- **Recovery**: Supervisor restarts preserve evaluation progress
- **Graceful Degradation**: Partial results available even with component failures
- **Hot Reload**: Component updates don't require VM restart

## Risk Mitigation

- **Registry Hot-Code Reload**: Use ETS + `:code.on_load` callback to re-register changed modules
- **Infinite Telemetry Cardinality**: Prefix run_id events under debug flag only; production aggregates by metric
- **Composite Metric Explosion**: Limit nested composites to depth-2 via guard in CompositeMetric.aggregate/2
- **Memory Leaks**: Explicit cleanup of ETS tables and Registry entries on run completion
- **Backpressure**: Built-in flow control prevents overwhelming downstream systems

## Deliverable Checklist

### Core Functionality
☑ Simple `evaluate/2` API maintaining Ragas compatibility  
☑ Full metric implementation with 10+ Ragas metrics ported  
☑ Dataset protocol with JSONL, CSV, and in-memory adapters  
☑ Comprehensive error handling and validation  

### Enterprise Features  
☑ Pluggable component architecture (reporters, stores, broadcasters, processors, middleware)  
☑ Composite metrics with consensus and weighted aggregation strategies  
☑ Real-time evaluation monitoring via telemetry and PubSub  
☑ Process registry for run tracking and distributed coordination  
☑ Built-in statistics computation (percentiles, pass rates, latency)  

### Production Readiness
☑ OTP supervision with fault isolation and recovery  
☑ Hot-code reload support for all components  
☑ Comprehensive telemetry events for monitoring  
☑ Performance benchmarks and memory profiling  
☑ Mix tasks for CLI evaluation and monitoring  

### Documentation & Examples
☑ Behaviour specs documented with doctests  
☑ Component implementation cookbook  
☑ Telemetry integration guide for DevOps teams  
☑ Dashboard integration examples  
☑ Migration guide from basic to advanced features  

## End State Vision

After Phase 7, `jido_eval` provides:

1. **Familiar API**: Ragas users can adopt with zero learning curve
2. **Enterprise Architecture**: Pluggable, observable, fault-tolerant components
3. **Elixir Native**: Full leverage of OTP, concurrency, hot-code reload
4. **Production Ready**: Comprehensive monitoring, error handling, and scalability
5. **Extensible**: Clear patterns for custom metrics, reporters, and data sources
6. **Cost Conscious**: Built-in caching, retry policies, and resource management

The implementation enables LLM evaluation workflows that start simple (3-line API) but scale to enterprise requirements with comprehensive observability, fault tolerance, and extensibility—combining Ragas' developer experience with Elixir's production strengths.
