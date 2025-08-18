defmodule Jido.Eval.Integration.LiveEvalTest do
  use ExUnit.Case
  alias Jido.Eval.Sample.SingleTurn
  alias Jido.Eval.Dataset.InMemory

  @moduletag :live_eval
  @moduletag timeout: 120_000

  describe "live evaluation with real LLM" do
    test "evaluates faithfulness on single RAG example" do
      # Single sample for reliable testing  
      samples = [
        %SingleTurn{
          id: "sample_001",
          user_input: "What is the capital of France?",
          retrieved_contexts: [
            "France is a country in Western Europe. Its capital and largest city is Paris.",
            "Paris is located in northern France on the River Seine."
          ],
          response: "The capital of France is Paris.",
          reference: "Paris is the capital of France.",
          tags: %{"source" => "geography_qa"}
        }
      ]

      {:ok, dataset} = InMemory.new(samples)

      # Run evaluation with faithfulness only (most reliable metric)
      {:ok, result} = Jido.Eval.evaluate(dataset, 
        metrics: [:faithfulness],
        llm: "openai:gpt-4o-mini",
        reporters: [],
        broadcasters: [],
        processors: [],
        config: %Jido.Eval.Config{middleware: []}
      )

      # Validate result structure matches Ragas pattern
      assert %Jido.Eval.Result{} = result
      assert result.run_id
      assert is_list(result.sample_results)
      assert length(result.sample_results) == 1

      # Check that sample was evaluated
      sample_result = hd(result.sample_results)
      assert is_map(sample_result)
      assert sample_result.sample_id == "sample_001"
      assert is_map(sample_result.scores)
      
      # Validate faithfulness score
      assert Map.has_key?(sample_result.scores, :faithfulness)
      faithfulness_score = sample_result.scores.faithfulness
      assert is_float(faithfulness_score)
      assert faithfulness_score >= 0.0 and faithfulness_score <= 1.0

      # Validate summary statistics
      assert is_map(result.summary_stats)
      assert Map.has_key?(result.summary_stats, :faithfulness)
      
      faithfulness_summary = result.summary_stats.faithfulness
      assert is_float(faithfulness_summary.mean)
      assert is_float(faithfulness_summary.std_dev)
      assert faithfulness_summary.count == 1

      # Log results for manual inspection
      IO.puts("\n=== Live Evaluation Results ===")
      IO.puts("Faithfulness Score: #{faithfulness_score}")
      IO.puts("Faithfulness Mean: #{faithfulness_summary.mean}")
      IO.puts("Run ID: #{result.run_id}")
      IO.puts("✅ Basic live evaluation working!")
    end

    test "evaluates with custom LLM configuration" do
      samples = [
        %SingleTurn{
          id: "sample_004",
          user_input: "What is machine learning?",
          retrieved_contexts: [
            "Machine learning is a subset of artificial intelligence that enables computers to learn from data.",
            "ML algorithms can identify patterns and make predictions without being explicitly programmed."
          ],
          response: "Machine learning is an AI technique where computers learn from data to make predictions and identify patterns automatically.",
          reference: "Machine learning uses data to train algorithms to make predictions.",
          tags: %{"source" => "tech_qa"}
        }
      ]

      {:ok, dataset} = InMemory.new(samples)

      # Test with custom temperature for more deterministic results
      {:ok, result} = Jido.Eval.evaluate(dataset,
        metrics: [:faithfulness],
        llm: {:openai, model: "gpt-4o-mini", temperature: 0.1},
        reporters: [],
        broadcasters: [],
        processors: [],
        config: %Jido.Eval.Config{middleware: []}
      )

      assert %Jido.Eval.Result{} = result
      assert length(result.sample_results) == 1
      
      sample_result = hd(result.sample_results)
      assert Map.has_key?(sample_result.scores, :faithfulness)
      
      faithfulness_score = sample_result.scores.faithfulness
      assert is_float(faithfulness_score)
      assert faithfulness_score >= 0.0 and faithfulness_score <= 1.0

      IO.puts("\n=== Custom LLM Config Results ===")
      IO.puts("Faithfulness Score: #{faithfulness_score}")
      IO.puts("Sample evaluated successfully with custom temperature")
    end

    test "evaluates multiple samples with both metrics" do
      # Multiple samples to test batch processing
      samples = [
        %SingleTurn{
          id: "sample_001",
          user_input: "What is the capital of France?",
          retrieved_contexts: [
            "France is a country in Western Europe. Its capital and largest city is Paris.",
            "Paris is located in northern France on the River Seine."
          ],
          response: "The capital of France is Paris.",
          reference: "Paris is the capital of France.",
          tags: %{"source" => "geography_qa"}
        },
        %SingleTurn{
          id: "sample_002",  
          user_input: "How does photosynthesis work?",
          retrieved_contexts: [
            "Photosynthesis is the process by which plants convert sunlight into energy.",
            "During photosynthesis, plants use chlorophyll to absorb light energy."
          ],
          response: "Photosynthesis converts sunlight into energy using chlorophyll.",
          reference: "Photosynthesis converts sunlight to energy.",
          tags: %{"source" => "biology_qa"}
        }
      ]

      {:ok, dataset} = InMemory.new(samples)

      # Test both metrics together
      {:ok, result} = Jido.Eval.evaluate(dataset,
        metrics: [:faithfulness, :context_precision],
        llm: "openai:gpt-4o-mini",
        reporters: [],
        broadcasters: [],
        processors: [],
        config: %Jido.Eval.Config{middleware: []}
      )

      assert %Jido.Eval.Result{} = result
      assert length(result.sample_results) == 2

      # Validate all samples have both metric scores
      for sample_result <- result.sample_results do
        assert Map.has_key?(sample_result.scores, :faithfulness)
        assert Map.has_key?(sample_result.scores, :context_precision)
        assert sample_result.scores.faithfulness >= 0.0
        assert sample_result.scores.context_precision >= 0.0
      end

      IO.puts("\n=== Multi-Sample Results ===")
      IO.puts("Faithfulness: #{result.summary_stats.faithfulness.mean}")
      IO.puts("Context Precision: #{result.summary_stats.context_precision.mean}")
      IO.puts("✅ Multi-sample evaluation working!")
    end

    test "handles challenging evaluation scenarios" do
      # Create a sample that might challenge the evaluation
      samples = [
        %SingleTurn{
          id: "sample_005",
          user_input: "What is the meaning of life?",
          retrieved_contexts: [
            "This is completely unrelated context about cooking recipes.",
            "Here's how to make pasta: boil water, add salt, cook noodles."
          ],
          response: "The answer is 42, according to Douglas Adams.",
          reference: "The meaning of life is a philosophical question with many different answers.",
          tags: %{"source" => "philosophy_qa"}
        }
      ]

      {:ok, dataset} = InMemory.new(samples)

      # This should still work but might produce low scores
      {:ok, result} = Jido.Eval.evaluate(dataset,
        metrics: [:faithfulness],
        llm: "openai:gpt-4o-mini",
        reporters: [],
        broadcasters: [],
        processors: [],
        config: %Jido.Eval.Config{middleware: []}
      )

      assert %Jido.Eval.Result{} = result
      assert length(result.sample_results) == 1

      sample_result = hd(result.sample_results)
      assert Map.has_key?(sample_result.scores, :faithfulness)

      # Score might be low due to context mismatch, but should still be valid
      faithfulness = sample_result.scores.faithfulness
      assert is_float(faithfulness) and faithfulness >= 0.0 and faithfulness <= 1.0

      IO.puts("\n=== Challenging Scenario Results ===")
      IO.puts("Faithfulness (mismatched context): #{faithfulness}")
      IO.puts("✅ System handled challenging evaluation gracefully")
    end
  end
end
