defmodule Jido.Eval.RetryPolicy do
  @moduledoc """
  Configuration for retry behavior in Jido Eval.

  Defines how failed operations should be retried with exponential backoff
  and jitter support.

  ## Examples

      iex> policy = %Jido.Eval.RetryPolicy{}
      iex> policy.max_retries
      3
      
      iex> policy = %Jido.Eval.RetryPolicy{max_retries: 5, base_delay: 2000}
      iex> policy.max_retries
      5
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              max_retries: Zoi.integer() |> Zoi.default(3),
              base_delay: Zoi.integer() |> Zoi.default(1000),
              max_delay: Zoi.integer() |> Zoi.default(60_000),
              jitter: Zoi.boolean() |> Zoi.default(true),
              retryable_errors: Zoi.list(Zoi.atom()) |> Zoi.default([:timeout, :rate_limit, :server_error])
            },
            coerce: true
          )

  @typedoc "Retry policy configuration"
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc """
  Builds a retry policy from a map, validating with Zoi.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ %{}) when is_map(attrs), do: Zoi.parse(@schema, attrs)

  @doc """
  Builds a retry policy from a map or raises on validation errors.
  """
  @spec new!(map()) :: t()
  def new!(attrs \\ %{}) when is_map(attrs) do
    case new(attrs) do
      {:ok, policy} -> policy
      {:error, reason} -> raise ArgumentError, "Invalid #{inspect(__MODULE__)}: #{inspect(reason)}"
    end
  end
end
