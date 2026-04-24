defmodule Jido.Eval.Sample.MultiTurn do
  @moduledoc """
  Multi-turn evaluation sample data structure.

  Represents a conversation flow between users and AI systems,
  including conversation history, context, and evaluation criteria.

  ## Fields

  - `id`: Unique identifier for the sample
  - `conversation`: List of messages representing the conversation flow
  - `retrieved_contexts`: RAG-retrieved context strings
  - `reference_contexts`: Ground truth context strings
  - `reference`: Expected conversation outcome or final response
  - `rubrics`: Evaluation criteria as key-value pairs
  - `tags`: Sample-level metadata for categorization

  ## Examples

      iex> sample = %Jido.Eval.Sample.MultiTurn{
      ...>   id: "conv_001",
      ...>   conversation: [
      ...>     %{role: :user, content: "Hello"},
      ...>     %{role: :assistant, content: "Hi! How can I help?"},
      ...>     %{role: :user, content: "What's the weather?"}
      ...>   ],
      ...>   tags: %{"category" => "weather", "turns" => "3"}
      ...> }
      iex> length(sample.conversation)
      3

  """
  @type message :: %{role: atom() | String.t(), content: term()}

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string() |> Zoi.nullable() |> Zoi.default(nil),
              conversation: Zoi.list(Zoi.any()) |> Zoi.default([]),
              retrieved_contexts: Zoi.list(Zoi.string()) |> Zoi.nullable() |> Zoi.default(nil),
              reference_contexts: Zoi.list(Zoi.string()) |> Zoi.nullable() |> Zoi.default(nil),
              reference: Zoi.string() |> Zoi.nullable() |> Zoi.default(nil),
              rubrics: Zoi.map(Zoi.string(), Zoi.string()) |> Zoi.nullable() |> Zoi.default(nil),
              tags: Zoi.map(Zoi.string(), Zoi.string()) |> Zoi.default(%{})
            },
            coerce: true
          )

  @typedoc "A multi-turn evaluation sample"
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc """
  Creates a new multi-turn sample with validation.

  ## Examples

      iex> {:ok, sample} = Jido.Eval.Sample.MultiTurn.new(%{
      ...>   conversation: [
      ...>     %{role: :user, content: "Hello"}
      ...>   ]
      ...> })
      iex> length(sample.conversation)
      1

  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    case Zoi.parse(@schema, attrs) do
      {:ok, sample} ->
        case validate(sample) do
          :ok -> {:ok, sample}
          {:error, reason} -> {:error, reason}
        end

      {:error, [%Zoi.Error{path: [:conversation], code: :invalid_type} | _]} ->
        {:error, "Conversation must be a list"}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Creates a multi-turn sample or raises on validation errors.
  """
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, sample} -> sample
      {:error, reason} -> raise ArgumentError, "Invalid #{inspect(__MODULE__)}: #{inspect(reason)}"
    end
  end

  @doc """
  Validates a multi-turn sample.

  Returns `:ok` if valid, or `{:error, reason}` if invalid.
  """
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{} = sample) do
    cond do
      not is_list(sample.conversation) ->
        {:error, "Conversation must be a list"}

      Enum.empty?(sample.conversation) ->
        {:error, "Conversation cannot be empty"}

      not all_valid_messages?(sample.conversation) ->
        {:error, "All conversation items must be valid messages"}

      true ->
        :ok
    end
  end

  @doc """
  Adds a message to the conversation.

  ## Examples

      iex> sample = %Jido.Eval.Sample.MultiTurn{conversation: []}
      iex> message = %{role: :user, content: "Hello"}
      iex> updated = Jido.Eval.Sample.MultiTurn.add_message(sample, message)
      iex> length(updated.conversation)
      1

  """
  @spec add_message(t(), message()) :: t()
  def add_message(%__MODULE__{} = sample, %{role: _role, content: _content} = message) do
    %{sample | conversation: sample.conversation ++ [message]}
  end

  @doc """
  Adds a string message to the conversation with specified role.

  ## Examples

      iex> sample = %Jido.Eval.Sample.MultiTurn{conversation: []}
      iex> updated = Jido.Eval.Sample.MultiTurn.add_message(sample, "Hello", :user)
      iex> [message] = updated.conversation
      iex> message.content
      "Hello"

  """
  @spec add_message(t(), String.t(), atom() | String.t()) :: t()
  def add_message(%__MODULE__{} = sample, content, role) when is_binary(content) do
    message = %{role: role, content: content}
    add_message(sample, message)
  end

  @doc """
  Gets the last message in the conversation.

  ## Examples

      iex> sample = %Jido.Eval.Sample.MultiTurn{
      ...>   conversation: [
      ...>     %{role: :user, content: "Hello"},
      ...>     %{role: :assistant, content: "Hi!"}
      ...>   ]
      ...> }
      iex> last_message = Jido.Eval.Sample.MultiTurn.last_message(sample)
      iex> last_message.content
      "Hi!"

  """
  @spec last_message(t()) :: message() | nil
  def last_message(%__MODULE__{conversation: []}), do: nil
  def last_message(%__MODULE__{conversation: conversation}), do: List.last(conversation)

  @doc """
  Gets messages by role from the conversation.

  ## Examples

      iex> sample = %Jido.Eval.Sample.MultiTurn{
      ...>   conversation: [
      ...>     %{role: :user, content: "Hello"},
      ...>     %{role: :assistant, content: "Hi!"},
      ...>     %{role: :user, content: "How are you?"}
      ...>   ]
      ...> }
      iex> user_messages = Jido.Eval.Sample.MultiTurn.messages_by_role(sample, :user)
      iex> length(user_messages)
      2

  """
  @spec messages_by_role(t(), atom() | String.t()) :: [message()]
  def messages_by_role(%__MODULE__{} = sample, role) do
    Enum.filter(sample.conversation, &(&1.role == role))
  end

  @doc """
  Counts the number of turns (messages) in the conversation.

  ## Examples

      iex> sample = %Jido.Eval.Sample.MultiTurn{
      ...>   conversation: [
      ...>     %{role: :user, content: "Hello"},
      ...>     %{role: :assistant, content: "Hi!"}
      ...>   ]
      ...> }
      iex> Jido.Eval.Sample.MultiTurn.turn_count(sample)
      2

  """
  @spec turn_count(t()) :: non_neg_integer()
  def turn_count(%__MODULE__{conversation: conversation}), do: length(conversation)

  @doc """
  Converts a sample to a map for serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = sample) do
    sample
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> convert_conversation_to_maps()
  end

  @doc """
  Creates a sample from a map, with type conversion.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    converted_map =
      map
      |> convert_conversation_from_maps()
      |> ensure_string_keys()

    new(converted_map)
  end

  # Private helper functions

  defp all_valid_messages?(messages) do
    Enum.all?(messages, &match?(%{role: _role, content: _content}, &1))
  end

  defp convert_conversation_to_maps(map) do
    case Map.get(map, :conversation) do
      messages when is_list(messages) ->
        Map.put(map, :conversation, messages)

      other ->
        Map.put(map, :conversation, other)
    end
  end

  defp convert_conversation_from_maps(map) do
    case Map.get(map, :conversation) || Map.get(map, "conversation") do
      messages when is_list(messages) ->
        converted_messages =
          Enum.map(messages, fn
            %{role: _role, content: _content} = message ->
              message

            message_map when is_map(message_map) ->
              # Convert string keys to atom keys
              converted_map =
                Map.new(message_map, fn
                  {key, value} when is_binary(key) ->
                    case key do
                      "role" -> {:role, String.to_existing_atom(value)}
                      "content" -> {:content, value}
                      "name" -> {:name, value}
                      "tool_call_id" -> {:tool_call_id, value}
                      "tool_calls" -> {:tool_calls, value}
                      "metadata" -> {:metadata, value}
                      _ -> {String.to_atom(key), value}
                    end

                  {key, value} when is_atom(key) ->
                    {key, value}
                end)

              converted_map

            other ->
              other
          end)

        # Handle both string and atom keys for conversation
        map
        |> Map.put(:conversation, converted_messages)
        |> Map.delete("conversation")

      other ->
        Map.put(map, :conversation, other || [])
    end
  end

  defp ensure_string_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {key, value}
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
    end)
  rescue
    ArgumentError -> map
  end
end
