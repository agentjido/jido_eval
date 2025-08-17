# Ragas Public API Reference

This document captures the public API of the Ragas SDK (Python) based on Oracle analysis of the source code. This serves as the reference for porting to Elixir as `jido_eval`.

## Core Public API

### Main Entry Point

```python
from ragas import evaluate

result = evaluate(
    dataset,                    # Dataset | EvaluationDataset
    metrics=None,              # List[Metric] (defaults to 4 common metrics)
    llm=None,                  # BaseRagasLLM | LangchainLLM
    embeddings=None,           # BaseRagasEmbeddings | LangchainEmbeddings  
    experiment_name=None,      # str
    callbacks=None,            # LangChain callbacks
    run_config=None,           # RunConfig
    token_usage_parser=None,   # TokenUsageParser
    raise_exceptions=False,    # bool
    column_map=None,           # Dict[str, str] 
    show_progress=True,        # bool
    batch_size=None           # int
) -> EvaluationResult
```

**Default metrics**: `answer_relevancy`, `context_precision`, `faithfulness`, `context_recall`

### Data Structures

#### Sample Types

```python
# Single interaction evaluation
class SingleTurnSample(BaseModel):
    user_input: Optional[str] = None
    retrieved_contexts: Optional[List[str]] = None  
    reference_contexts: Optional[List[str]] = None
    response: Optional[str] = None
    multi_responses: Optional[List[str]] = None
    reference: Optional[str] = None               # ground truth
    rubrics: Optional[Dict[str, str]] = None

# Multi-turn conversation evaluation  
class MultiTurnSample(BaseModel):
    user_input: List[Union[HumanMessage, AIMessage, ToolMessage]]
    reference: Optional[str] = None
    reference_tool_calls: Optional[List[ToolCall]] = None
    rubrics: Optional[Dict[str, str]] = None
    reference_topics: Optional[List[str]] = None
```

#### Dataset Container

```python
@dataclass
class EvaluationDataset(RagasDataset[SingleTurnSample | MultiTurnSample]):
    samples: List[BaseSample]
    
    # Core methods
    def to_list() -> List[Dict]
    def from_list(cls, data: List[Dict]) -> EvaluationDataset
    def get_sample_type() -> Type[Sample]
    
    # Format conversions
    def to_hf_dataset() -> HFDataset
    def to_pandas() -> DataFrame  
    def to_csv(path), to_jsonl(path)
    def from_jsonl(cls, path) -> EvaluationDataset
```

#### Evaluation Result

```python
@dataclass  
class EvaluationResult:
    scores: List[Dict[str, Any]]           # Per-sample metric scores
    dataset: EvaluationDataset             # Original dataset
    binary_columns: List[str] = []         # Binary metrics list
    cost_cb: Optional[CostCallbackHandler] # Cost tracking
    traces: List[Dict[str, Any]] = []      # Execution traces
    run_id: Optional[UUID] = None
    
    # Aggregated access
    def __getitem__(key: str) -> List[float]  # All scores for metric
    def __repr__() -> str                     # Pretty {metric: avg_score}
    
    # Analysis helpers
    def to_pandas() -> DataFrame
    def total_tokens() -> TokenUsage | List[TokenUsage]
    def total_cost(...) -> float
    def upload() -> str                       # Upload to Ragas cloud
```

### Configuration

```python
@dataclass
class RunConfig:
    timeout: int = 180              # Per-operation timeout
    max_retries: int = 10           # Retry attempts
    max_wait: int = 60             # Max retry backoff
    max_workers: int = 16          # Concurrency limit
    exception_types: Tuple = (Exception,)
    log_tenacity: bool = False     # Retry logging
    seed: int = 42                 # Reproducibility
    
    # Post-init creates: self.rng = np.random.default_rng(seed)
```

## Metrics System

### Base Metric Protocol

```python
@dataclass
class Metric(ABC):
    name: str = ""                          # Auto-derived from class name
    _required_columns: Dict[MetricType, Set[str]]
    
    # Lifecycle
    def init(run_config: RunConfig)
    
    # Scoring (subclasses implement)
    async def _single_turn_ascore(sample, callbacks) -> float
    async def _multi_turn_ascore(sample, callbacks) -> float
```

**Required columns validation**: Each metric declares which columns from `SingleTurnSample`/`MultiTurnSample` it needs. Evaluation validates all selected metrics can run on the provided dataset.

### Metric Categories

1. **RAG Quality**: `faithfulness`, `answer_relevancy`, `context_precision`, `context_recall`
2. **Answer Quality**: `answer_correctness`, `answer_similarity` 
3. **Context Quality**: `context_entity_recall`, `context_utilization`
4. **Custom Evaluation**: `AspectCritic`, `RubricsScore`, `SimpleCriteriaScore`
5. **String Metrics**: `ExactMatch`, `BleuScore`, `RougeScore`
6. **Multi-modal**: `MultiModalFaithfulness`, `MultiModalRelevance`
7. **Agent/Tool**: `ToolCallAccuracy`, `AgentGoalAccuracy`

### Metric Dependencies

- **MetricWithLLM**: Requires LLM for reasoning-based evaluation
- **MetricWithEmbeddings**: Requires embeddings for semantic similarity
- **Mixed**: Some metrics use both (e.g., `AnswerCorrectness`)

## Experiment System

### Experiment Decorator

```python
from ragas import experiment

@experiment(experiment_model=MyResultModel, backend="sqlite")
async def my_eval_experiment(sample: MyInputSample) -> MyResultModel:
    # Custom evaluation logic
    return MyResultModel(...)

# Usage
results = await my_eval_experiment.arun(
    dataset=my_dataset,
    name="experiment-v1", 
    backend="sqlite"
)
```

**Key behaviors**:
- Runs function on every dataset sample concurrently
- Auto-progress tracking, error tolerance
- Persists results via pluggable backend
- Returns `Experiment` (DataTable wrapper)

### Git Versioning

```python
from ragas import version_experiment

commit_hash = version_experiment(
    experiment_name="eval-v2",
    commit_message="Add new eval metrics",
    create_branch=True,
    stage_all=False
)
```

## Caching System

```python
from ragas import cacher, DiskCacheBackend

# Enable caching for expensive LLM calls
with cacher(DiskCacheBackend()):
    result = evaluate(dataset, metrics=[expensive_metric])
```

## Architecture Patterns

### 1. Functional Facade Pattern
- `evaluate()` is the primary entry point hiding internal complexity
- Metric instances are reusable but stateless between evaluations

### 2. Late Binding Dependencies  
- Metrics can be created without LLM/embeddings
- Dependencies resolved at evaluation time with global fallbacks

### 3. Async-First Execution
- All metric scoring is async (`_single_turn_ascore`, `_multi_turn_ascore`)
- Sync wrappers are deprecated 
- Concurrency managed by `Executor` with configurable workers

### 4. Uniform Error Handling
- `{:ok, result}` | `{:error, reason}` pattern (though Python uses exceptions)
- Graceful degradation: failed metrics return NaN unless `raise_exceptions=True`

### 5. Observability Integration
- LangChain callbacks for tracing evaluation execution
- Cost tracking for token usage and pricing
- Analytics events for usage telemetry

### 6. Pluggable Backends
- Caching backends for LLM call memoization
- Experiment storage backends (in-memory, disk, cloud)

## Key Design Decisions

1. **Immutable Datasets**: `EvaluationDataset` is immutable after construction
2. **Homogeneous Samples**: All samples in dataset must be same type (validated)
3. **Column-based Validation**: Metrics declare required dataset columns upfront
4. **Provider Abstraction**: Unified interface for different LLM providers
5. **Batch-aware Execution**: Optional batching for metrics that can process multiple samples efficiently

## Migration Notes for Elixir Port

1. **Pydantic → Typed Structs**: Use `TypedStruct` or `Ecto.Schema` for data validation
2. **LangChain Callbacks → Telemetry**: Map callback hierarchy to Telemetry events
3. **Asyncio → Task.async_stream**: Use Elixir's `Task` module for concurrency
4. **Tenacity → Retry**: Use `retry` hex package for error recovery
5. **NumPy RNG → :rand**: Use Erlang's `:rand` module with seed
6. **Dataclasses → Structs**: Map Python dataclasses to Elixir structs with `@enforce_keys`
