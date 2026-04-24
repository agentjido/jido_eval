defmodule Jido.Eval.Error do
  @moduledoc """
  Centralized error helpers for Jido Eval.

  Public APIs still return `{:ok, value}` and `{:error, reason}` tuples. This module provides package-specific error
  structs for call sites that need tighter classification, aggregation, or conversion from external errors.
  """

  use Splode,
    error_classes: [
      invalid: Invalid,
      execution: Execution,
      config: Config,
      internal: Internal
    ],
    unknown_error: __MODULE__.Internal.UnknownError

  defmodule Invalid do
    @moduledoc "Invalid input error class for Jido Eval."
    use Splode.ErrorClass, class: :invalid
  end

  defmodule Execution do
    @moduledoc "Runtime execution error class for Jido Eval."
    use Splode.ErrorClass, class: :execution
  end

  defmodule Config do
    @moduledoc "Configuration error class for Jido Eval."
    use Splode.ErrorClass, class: :config
  end

  defmodule Internal do
    @moduledoc "Internal error class for Jido Eval."
    use Splode.ErrorClass, class: :internal

    defmodule UnknownError do
      @moduledoc false
      defexception [:message, :details]

      @type t :: %__MODULE__{
              message: String.t() | nil,
              details: map() | nil
            }
    end
  end

  defmodule InvalidInputError do
    @moduledoc "Error for invalid evaluation input."
    defexception [:message, :field, :value, :details]

    @type t :: %__MODULE__{
            message: String.t() | nil,
            field: atom() | nil,
            value: term(),
            details: map() | nil
          }
  end

  defmodule ExecutionFailureError do
    @moduledoc "Error for evaluation runtime failures."
    defexception [:message, :details]

    @type t :: %__MODULE__{
            message: String.t() | nil,
            details: map() | nil
          }
  end

  defmodule ConfigError do
    @moduledoc "Error for invalid Jido Eval configuration."
    defexception [:message, :field, :value, :details]

    @type t :: %__MODULE__{
            message: String.t() | nil,
            field: atom() | nil,
            value: term(),
            details: map() | nil
          }
  end

  @doc """
  Builds an invalid-input error.
  """
  @spec validation_error(String.t(), map()) :: InvalidInputError.t()
  def validation_error(message, details \\ %{}) when is_map(details) do
    InvalidInputError.exception(Keyword.merge([message: message], Map.to_list(details)))
  end

  @doc """
  Builds a configuration error.
  """
  @spec config_error(String.t(), map()) :: ConfigError.t()
  def config_error(message, details \\ %{}) when is_map(details) do
    ConfigError.exception(Keyword.merge([message: message], Map.to_list(details)))
  end

  @doc """
  Builds an execution failure error.
  """
  @spec execution_error(String.t(), map()) :: ExecutionFailureError.t()
  def execution_error(message, details \\ %{}) when is_map(details) do
    ExecutionFailureError.exception(message: message, details: details)
  end
end
