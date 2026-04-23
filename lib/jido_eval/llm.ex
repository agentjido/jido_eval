defmodule Jido.Eval.LLM do
  @moduledoc """
  Direct ReqLLM judge adapter for Jido Eval.

  The core Ragas-like eval harness uses `LLMDB.model/1` to normalize judge model
  strings to `%LLMDB.Model{}` and calls `ReqLLM` directly. `text/3` and `object/4`
  return rich judge-call metadata. Legacy `generate_text/3` and
  `generate_object/4` remain as compatibility wrappers that return only the
  extracted text or object.
  """

  alias Jido.Eval.RetryPolicy

  @type model_spec :: String.t() | LLMDB.Model.t()
  @type prompt :: String.t() | [map()]
  @type cache_key :: String.t()

  @type judge_call :: %{
          type: :text | :object,
          output: String.t() | map() | term(),
          text: String.t(),
          object: map() | nil,
          raw_response: ReqLLM.Response.t() | nil,
          usage: map() | nil,
          finish_reason: atom() | nil,
          provider_meta: map(),
          model: LLMDB.Model.t(),
          model_spec: String.t(),
          latency_ms: non_neg_integer(),
          cache_hit: boolean()
        }

  @default_retry_policy %RetryPolicy{}

  @doc """
  Calls a judge model for text output and returns rich metadata.
  """
  @spec text(model_spec(), prompt(), keyword()) :: {:ok, judge_call()} | {:error, term()}
  def text(model_spec, prompt, opts \\ []) do
    with {:ok, model} <- resolve_model(model_spec) do
      {retry_policy, cache_opts, req_opts} = extract_options(opts)

      operation = fn ->
        case call_llm_stub(:text, model, prompt, req_opts) do
          :no_stub ->
            started_at = System.monotonic_time(:millisecond)

            with {:ok, response} <- ReqLLM.generate_text(model, prompt, req_opts) do
              {:ok, build_text_call(model, response, elapsed_since(started_at), false)}
            end

          stubbed ->
            normalize_stubbed_result(:text, model, stubbed)
        end
      end

      cache_key = build_cache_key(:text, model, prompt, req_opts)
      with_cache_and_retry(operation, cache_key, cache_opts, retry_policy)
    end
  end

  @doc """
  Calls a judge model for structured object output and returns rich metadata.
  """
  @spec object(model_spec(), prompt(), keyword() | map(), keyword()) ::
          {:ok, judge_call()} | {:error, term()}
  def object(model_spec, prompt, schema, opts \\ []) do
    with {:ok, model} <- resolve_model(model_spec) do
      {retry_policy, cache_opts, req_opts} = extract_options(opts)

      operation = fn ->
        case call_llm_stub(:object, model, prompt, schema, req_opts) do
          :no_stub ->
            started_at = System.monotonic_time(:millisecond)

            with {:ok, response} <- ReqLLM.generate_object(model, prompt, schema, req_opts) do
              {:ok, build_object_call(model, response, elapsed_since(started_at), false)}
            end

          stubbed ->
            normalize_stubbed_result(:object, model, stubbed)
        end
      end

      cache_key = build_cache_key(:object, model, {prompt, schema}, req_opts)
      with_cache_and_retry(operation, cache_key, cache_opts, retry_policy)
    end
  end

  @doc """
  Compatibility wrapper returning only text.
  """
  @spec generate_text(model_spec(), prompt(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate_text(model_spec, prompt, opts \\ []) do
    with {:ok, call} <- text(model_spec, prompt, opts) do
      {:ok, call.text}
    end
  end

  @doc """
  Compatibility wrapper returning only the generated object.
  """
  @spec generate_object(model_spec(), prompt(), keyword() | map(), keyword()) ::
          {:ok, map() | term()} | {:error, term()}
  def generate_object(model_spec, prompt, schema, opts \\ []) do
    with {:ok, call} <- object(model_spec, prompt, schema, opts) do
      {:ok, call.object || call.output}
    end
  end

  @doc """
  Builds a compact summary of a judge call for metric results.
  """
  @spec summarize_call(judge_call()) :: map()
  def summarize_call(call) when is_map(call) do
    %{
      type: call.type,
      model: call.model,
      model_spec: call.model_spec,
      usage: call.usage,
      finish_reason: call.finish_reason,
      provider_meta: call.provider_meta,
      latency_ms: call.latency_ms,
      cache_hit: call.cache_hit,
      output: call.output
    }
  end

  @doc """
  Clears the adapter-level response cache.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    case :ets.whereis(__MODULE__) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(__MODULE__)
    end

    :ok
  end

  defp resolve_model(%LLMDB.Model{} = model), do: {:ok, model}
  defp resolve_model(model_spec) when is_binary(model_spec), do: LLMDB.model(model_spec)

  defp resolve_model(model_spec) do
    {:error,
     ReqLLM.Error.Validation.Error.exception(
       tag: :invalid_model_spec,
       reason: "Invalid model spec: #{inspect(model_spec)}",
       context: []
     )}
  end

  defp extract_options(opts) do
    retry_policy = Keyword.get(opts, :retry_policy, @default_retry_policy)

    cache_opts = %{
      enabled: Keyword.get(opts, :cache, false),
      ttl: Keyword.get(opts, :cache_ttl, 300_000)
    }

    configured_req_opts =
      case Application.get_env(:jido_eval, :judge_opts) do
        opts when is_list(opts) and opts != [] -> opts
        _ -> Application.get_env(:jido_eval, :llm_opts, [])
      end

    req_opts =
      Keyword.merge(
        configured_req_opts,
        Keyword.drop(opts, [:retry_policy, :cache, :cache_ttl])
      )

    {retry_policy, cache_opts, req_opts}
  end

  defp with_cache_and_retry(operation, cache_key, cache_opts, retry_policy) do
    if cache_opts.enabled do
      case get_cached(cache_key) do
        {:ok, result} -> {:ok, mark_cache_hit(result)}
        :miss -> execute_with_retry_and_cache(operation, cache_key, cache_opts, retry_policy)
      end
    else
      execute_with_retry(operation, retry_policy)
    end
  end

  defp execute_with_retry_and_cache(operation, cache_key, cache_opts, retry_policy) do
    case execute_with_retry(operation, retry_policy) do
      {:ok, result} ->
        cache_result(cache_key, result, cache_opts.ttl)
        {:ok, result}

      {:error, _} = error ->
        error
    end
  end

  defp execute_with_retry(operation, retry_policy, attempt \\ 1) do
    case run_operation(operation) do
      {:ok, result} ->
        {:ok, result}

      {:error, error} ->
        if should_retry?(error, attempt, retry_policy) do
          retry_policy
          |> calculate_delay(attempt)
          |> Process.sleep()

          execute_with_retry(operation, retry_policy, attempt + 1)
        else
          {:error, normalize_error(error)}
        end
    end
  end

  defp run_operation(operation) do
    operation.()
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp should_retry?(error, attempt, retry_policy) do
    attempt <= retry_policy.max_retries and classify_error(error) in retry_policy.retryable_errors
  end

  defp classify_error(%ReqLLM.Error.API.Request{status: 429}), do: :rate_limit

  defp classify_error(%ReqLLM.Error.API.Request{status: status})
       when is_integer(status) and status >= 500,
       do: :server_error

  defp classify_error(%ReqLLM.Error.API.Request{reason: reason})
       when reason in [:timeout, :connect_timeout, :checkout_timeout],
       do: :timeout

  defp classify_error(%ReqLLM.Error.API.Request{}), do: :api_error
  defp classify_error({_kind, :timeout}), do: :timeout
  defp classify_error(_), do: :unknown

  defp calculate_delay(retry_policy, attempt) do
    base_delay = retry_policy.base_delay * :math.pow(2, attempt - 1)
    capped_delay = min(base_delay, retry_policy.max_delay)

    if retry_policy.jitter do
      jitter = :rand.uniform() * capped_delay * 0.1
      round(capped_delay + jitter)
    else
      round(capped_delay)
    end
  end

  defp normalize_error(%ReqLLM.Error.API.Request{} = error), do: error
  defp normalize_error(%ReqLLM.Error.API.Response{} = error), do: error
  defp normalize_error(%ReqLLM.Error.Validation.Error{} = error), do: error
  defp normalize_error(%ReqLLM.Error.Invalid.Parameter{} = error), do: error
  defp normalize_error(%ReqLLM.Error.Invalid.Provider{} = error), do: error
  defp normalize_error(%ReqLLM.Error.Invalid.Provider.NotImplemented{} = error), do: error

  defp normalize_error(%{__exception__: true} = exception),
    do: ReqLLM.Error.Unknown.Unknown.exception(error: exception)

  defp normalize_error(other), do: ReqLLM.Error.Unknown.Unknown.exception(error: other)

  defp build_text_call(model, response, latency_ms, cache_hit) do
    text = ReqLLM.Response.text(response) || extract_text(response)

    %{
      type: :text,
      output: text,
      text: text,
      object: nil,
      raw_response: response,
      usage: ReqLLM.Response.usage(response),
      finish_reason: ReqLLM.Response.finish_reason(response),
      provider_meta: Map.get(response, :provider_meta, %{}) || %{},
      model: model,
      model_spec: LLMDB.Model.spec(model),
      latency_ms: latency_ms,
      cache_hit: cache_hit or response_cache_hit?(response)
    }
  end

  defp build_object_call(model, response, latency_ms, cache_hit) do
    object = response |> ReqLLM.Response.object() |> normalize_object()
    text = ReqLLM.Response.text(response) || extract_text(response)
    output = object || decode_object(text)

    %{
      type: :object,
      output: output,
      text: text,
      object: output,
      raw_response: response,
      usage: ReqLLM.Response.usage(response),
      finish_reason: ReqLLM.Response.finish_reason(response),
      provider_meta: Map.get(response, :provider_meta, %{}) || %{},
      model: model,
      model_spec: LLMDB.Model.spec(model),
      latency_ms: latency_ms,
      cache_hit: cache_hit or response_cache_hit?(response)
    }
  end

  defp response_cache_hit?(%{provider_meta: %{response_cache_hit: true}}), do: true
  defp response_cache_hit?(%{provider_meta: %{"response_cache_hit" => true}}), do: true
  defp response_cache_hit?(_response), do: false

  defp elapsed_since(started_at) do
    System.monotonic_time(:millisecond) - started_at
  end

  defp normalize_stubbed_result(type, model, {:ok, value}) do
    {:ok, build_stub_call(type, model, value)}
  end

  defp normalize_stubbed_result(_type, _model, {:error, _} = error), do: error

  defp normalize_stubbed_result(type, model, value) do
    {:ok, build_stub_call(type, model, value)}
  end

  defp build_stub_call(:text, model, value) do
    text = extract_text(value)

    %{
      type: :text,
      output: text,
      text: text,
      object: nil,
      raw_response: nil,
      usage: nil,
      finish_reason: nil,
      provider_meta: %{},
      model: model,
      model_spec: LLMDB.Model.spec(model),
      latency_ms: 0,
      cache_hit: false
    }
  end

  defp build_stub_call(:object, model, value) do
    object = normalize_object(value)

    %{
      type: :object,
      output: object,
      text: if(is_binary(value), do: value, else: ""),
      object: object,
      raw_response: nil,
      usage: nil,
      finish_reason: nil,
      provider_meta: %{},
      model: model,
      model_spec: LLMDB.Model.spec(model),
      latency_ms: 0,
      cache_hit: false
    }
  end

  defp extract_text(text) when is_binary(text), do: text
  defp extract_text(nil), do: ""

  defp extract_text(%{message: %{content: content}}), do: extract_content(content)
  defp extract_text(%{"message" => %{"content" => content}}), do: extract_content(content)

  defp extract_text(%{choices: [%{message: %{content: content}} | _]}),
    do: extract_content(content)

  defp extract_text(%{"choices" => [%{"message" => %{"content" => content}} | _]}),
    do: extract_content(content)

  defp extract_text(%{content: content}), do: extract_content(content)
  defp extract_text(%{"content" => content}), do: extract_content(content)
  defp extract_text(_response), do: ""

  defp extract_content(content) when is_binary(content), do: content
  defp extract_content(nil), do: ""

  defp extract_content(parts) when is_list(parts) do
    parts
    |> Enum.map(&extract_content_part/1)
    |> Enum.join("")
  end

  defp extract_content(content), do: to_string(content)

  defp extract_content_part(%{type: type, text: text})
       when type in [:text, "text"] and is_binary(text), do: text

  defp extract_content_part(%{"type" => type, "text" => text})
       when type in [:text, "text"] and is_binary(text), do: text

  defp extract_content_part(%{text: text}) when is_binary(text), do: text
  defp extract_content_part(%{"text" => text}) when is_binary(text), do: text
  defp extract_content_part(text) when is_binary(text), do: text
  defp extract_content_part(_part), do: ""

  defp decode_object(text) when is_binary(text) do
    case Jason.decode(text, keys: :atoms) do
      {:ok, object} -> normalize_object(object)
      {:error, _} -> text
    end
  end

  defp decode_object(object), do: normalize_object(object)

  defp normalize_object(nil), do: nil

  defp normalize_object(object) when is_map(object) do
    Map.new(object, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), normalize_object(value)}
      {key, value} -> {key, normalize_object(value)}
    end)
  end

  defp normalize_object(list) when is_list(list), do: Enum.map(list, &normalize_object/1)
  defp normalize_object(value), do: value

  defp call_llm_stub(kind, model, prompt, opts) do
    case Application.get_env(:jido_eval, :llm_stub) do
      stub when is_function(stub, 5) -> stub.(kind, model, prompt, nil, opts)
      stub when is_function(stub, 4) -> stub.(kind, model, prompt, opts)
      stub when is_function(stub, 3) -> stub.(model, prompt, opts)
      _ -> :no_stub
    end
  end

  defp call_llm_stub(kind, model, prompt, schema, opts) do
    case Application.get_env(:jido_eval, :llm_stub) do
      stub when is_function(stub, 5) -> stub.(kind, model, prompt, schema, opts)
      stub when is_function(stub, 4) -> stub.(kind, model, prompt, opts)
      stub when is_function(stub, 3) -> stub.(model, prompt, opts)
      _ -> :no_stub
    end
  end

  defp ensure_cache_table do
    unless :ets.whereis(__MODULE__) != :undefined do
      :ets.new(__MODULE__, [:set, :public, :named_table])
    end

    :ok
  end

  defp build_cache_key(kind, model, prompt, opts) do
    key_data = %{
      kind: kind,
      model: LLMDB.Model.spec(model),
      prompt: prompt,
      opts: Enum.sort(opts)
    }

    :crypto.hash(:sha256, :erlang.term_to_binary(key_data))
    |> Base.encode16(case: :lower)
  end

  defp get_cached(cache_key) do
    ensure_cache_table()

    case :ets.lookup(__MODULE__, cache_key) do
      [{^cache_key, result, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, result}
        else
          :ets.delete(__MODULE__, cache_key)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp cache_result(cache_key, result, ttl) do
    ensure_cache_table()
    expires_at = System.monotonic_time(:millisecond) + ttl
    :ets.insert(__MODULE__, {cache_key, result, expires_at})
    :ok
  end

  defp mark_cache_hit(call) when is_map(call), do: %{call | cache_hit: true}
end
