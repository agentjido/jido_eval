Logger.configure(level: :error)
ExUnit.start(capture_log: true, exclude: [:live_eval])

defmodule Jido.Eval.Test.LiveEnv do
  @moduledoc false

  @provider_env_keys ["OPENAI_API_KEY", "ANTHROPIC_API_KEY"]
  @req_llm_app_keys [:openai_api_key, :anthropic_api_key]

  def load!(required_keys \\ @provider_env_keys) do
    env_path = Path.join(File.cwd!(), ".env")

    unless File.exists?(env_path) do
      raise "Expected .env at #{env_path} for live eval tests"
    end

    previous_system_env = Map.new(@provider_env_keys, &{&1, System.get_env(&1)})
    previous_app_env = Map.new(@req_llm_app_keys, &{&1, Application.get_env(:req_llm, &1)})

    env_path
    |> Dotenvy.source!(side_effect: nil)
    |> Enum.each(fn
      {key, value} when key in @provider_env_keys and is_binary(value) and value != "" ->
        System.put_env(key, value)

      _ ->
        :ok
    end)

    Enum.each(@req_llm_app_keys, &Application.delete_env(:req_llm, &1))

    missing_keys =
      Enum.reject(required_keys, fn key ->
        case System.get_env(key) do
          value when is_binary(value) and value != "" -> true
          _ -> false
        end
      end)

    if missing_keys != [] do
      raise "Missing required .env keys for live eval tests: #{Enum.join(missing_keys, ", ")}"
    end

    %{
      previous_system_env: previous_system_env,
      previous_app_env: previous_app_env
    }
  end

  def restore!(%{previous_system_env: previous_system_env, previous_app_env: previous_app_env}) do
    Enum.each(previous_system_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    Enum.each(previous_app_env, fn
      {key, nil} -> Application.delete_env(:req_llm, key)
      {key, value} -> Application.put_env(:req_llm, key, value)
    end)

    :ok
  end
end

Application.put_env(:req_llm, :openai_api_key, "test-key")

Application.put_env(:jido_eval, :llm_stub, fn
  :text, _model_spec, prompt, _schema, _opts ->
    if String.contains?(prompt, "extract all the individual claims") do
      Process.sleep(100)
      {:ok, "1. #{String.slice(prompt, 0, 40)}"}
    else
      Process.sleep(100)
      {:ok, "YES"}
    end

  :object, _model_spec, prompt, _schema, _opts ->
    Process.sleep(100)

    cond do
      String.contains?(prompt, "extract all individual factual claims") ->
        {:ok, %{statements: [%{text: "stub factual statement"}]}}

      String.contains?(prompt, "whether the statement is supported") ->
        {:ok, %{supported: true, reasoning: "The stub context supports the statement."}}

      String.contains?(prompt, "whether the context is relevant") ->
        {:ok, %{relevant: true, reasoning: "The stub context is relevant."}}

      true ->
        {:ok, %{score: 1.0}}
    end
end)

Application.put_env(:jido_eval, :judge_opts, api_key: "test-key")
Application.put_env(:jido_eval, :llm_opts, api_key: "test-key")
