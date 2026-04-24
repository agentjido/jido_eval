alias Jido.Eval
alias Jido.Eval.Dataset.InMemory
alias Jido.Eval.Sample.SingleTurn

samples = [
  %SingleTurn{
    id: "capital-france",
    user_input: "What is the capital of France?",
    retrieved_contexts: ["France's capital is Paris.", "Paris is located in northern France."],
    response: "Paris is the capital of France.",
    tags: %{"category" => "geography"}
  }
]

{:ok, dataset} = InMemory.new(samples)

{:ok, result} =
  Eval.evaluate(dataset,
    metrics: [:faithfulness],
    judge_model: "openai:gpt-4o",
    judge_opts: [temperature: 0.0]
  )

IO.inspect(result.summary_stats, label: "summary_stats")
