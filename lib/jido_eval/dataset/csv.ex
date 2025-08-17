defmodule Jido.Eval.Dataset.CSV do
  @moduledoc """
  CSV dataset implementation for Jido Eval.

  Reads samples from CSV files with streaming support for
  memory-efficient processing of large datasets.

  The CSV format assumes the first row contains column headers
  that map to sample struct fields. Only supports SingleTurn
  samples due to CSV's flat structure limitations.

  ## Expected CSV Format

  For SingleTurn samples:
  ```csv
  id,user_input,response,reference,retrieved_contexts,reference_contexts,rubrics,tags
  sample_1,"Hello","Hi there!","Hi!","context1;context2","ref1;ref2","accuracy:good","category:greeting"
  ```

  ## Examples

      iex> {:ok, dataset} = Jido.Eval.Dataset.CSV.new("samples.csv")
      iex> Jido.Eval.Dataset.sample_type(dataset)
      :single_turn

  """
  use TypedStruct

  alias Jido.Eval.Dataset
  alias Jido.Eval.Sample.SingleTurn
  alias NimbleCSV.RFC4180, as: CSV

  typedstruct do
    @typedoc "A CSV dataset"

    field(:file_path, String.t(), default: "")
    field(:headers, [String.t()], default: [])
    field(:separator, String.t(), default: ",")
    field(:encoding, :utf8 | :latin1, default: :utf8)
  end

  @doc """
  Creates a new CSV dataset from a file path.

  ## Options

  - `:separator` - CSV separator (default: `","`)
  - `:encoding` - File encoding (default: `:utf8`)

  ## Examples

      iex> {:ok, dataset} = Jido.Eval.Dataset.CSV.new("data.csv")
      iex> dataset.file_path
      "data.csv"

  """
  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(file_path, opts \\ []) do
    separator = Keyword.get(opts, :separator, ",")
    encoding = Keyword.get(opts, :encoding, :utf8)

    if File.exists?(file_path) do
      case read_headers(file_path, separator, encoding) do
        {:ok, headers} ->
          dataset = %__MODULE__{
            file_path: file_path,
            headers: headers,
            separator: separator,
            encoding: encoding
          }

          {:ok, dataset}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "File does not exist: #{file_path}"}
    end
  end

  @doc """
  Writes SingleTurn samples to a CSV file.

  ## Examples

      iex> samples = [%Jido.Eval.Sample.SingleTurn{user_input: "Hello", response: "Hi!"}]
      iex> :ok = Jido.Eval.Dataset.CSV.write("output.csv", samples)

  """
  @spec write(String.t(), [SingleTurn.t()]) :: :ok | {:error, String.t()}
  def write(file_path, samples) when is_list(samples) do
    try do
      if Enum.empty?(samples) do
        {:error, "Cannot write empty sample list"}
      else
        headers = get_standard_headers()
        rows = Enum.map(samples, &sample_to_row(&1, headers))

        csv_data = [headers | rows]
        csv_string = CSV.dump_to_iodata(csv_data)

        File.write!(file_path, csv_string)
        :ok
      end
    rescue
      e -> {:error, "Failed to write CSV file: #{Exception.message(e)}"}
    end
  end

  # Protocol implementations

  defimpl Dataset, for: __MODULE__ do
    def to_stream(%Jido.Eval.Dataset.CSV{
          file_path: file_path,
          headers: headers,
          encoding: _encoding
        }) do
      file_path
      |> File.stream!()
      |> CSV.parse_stream(skip_headers: false)
      # Skip header row
      |> Stream.drop(1)
      |> Stream.map(&Jido.Eval.Dataset.CSV.row_to_sample(&1, headers))
      |> Stream.filter(&match?({:ok, _}, &1))
      |> Stream.map(fn {:ok, sample} -> sample end)
    end

    def sample_type(%Jido.Eval.Dataset.CSV{}) do
      # CSV only supports single-turn samples
      :single_turn
    end

    def count(%Jido.Eval.Dataset.CSV{file_path: file_path}) do
      try do
        file_path
        |> File.stream!()
        |> Enum.count()
        # Subtract header row
        |> Kernel.-(1)
        |> max(0)
      rescue
        _ -> :unknown
      end
    end
  end

  # Private helper functions

  defp read_headers(file_path, _separator, _encoding) do
    try do
      file_path
      |> File.stream!()
      |> CSV.parse_stream(skip_headers: false)
      |> Enum.take(1)
      |> case do
        [headers] -> {:ok, headers}
        [] -> {:error, "Empty CSV file"}
      end
    rescue
      e -> {:error, "Failed to read CSV headers: #{Exception.message(e)}"}
    end
  end

  def row_to_sample(row, headers) do
    try do
      row_map = Enum.zip(headers, row) |> Map.new()
      sample_map = convert_csv_row_to_sample_map(row_map)
      SingleTurn.from_map(sample_map)
    rescue
      e -> {:error, "Failed to convert row to sample: #{Exception.message(e)}"}
    end
  end

  defp convert_csv_row_to_sample_map(row_map) do
    row_map
    |> Map.new(fn {key, value} ->
      atom_key = String.to_atom(key)
      converted_value = convert_csv_value(atom_key, value)
      {atom_key, converted_value}
    end)
    |> Map.reject(fn {_key, value} -> is_nil(value) or value == "" end)
  end

  defp convert_csv_value(key, value)
       when key in [:retrieved_contexts, :reference_contexts, :multi_responses] do
    if value != "" and not is_nil(value) do
      String.split(value, ";")
    else
      nil
    end
  end

  defp convert_csv_value(key, value) when key in [:rubrics, :tags] do
    if value != "" and not is_nil(value) do
      value
      |> String.split(";")
      |> Enum.reduce(%{}, fn pair, acc ->
        case String.split(pair, ":", parts: 2) do
          [k, v] -> Map.put(acc, k, v)
          [k] -> Map.put(acc, k, "true")
          _ -> acc
        end
      end)
    else
      %{}
    end
  end

  defp convert_csv_value(_key, value) do
    if value == "" or is_nil(value) do
      nil
    else
      value
    end
  end

  defp sample_to_row(%SingleTurn{} = sample, headers) do
    sample_map = SingleTurn.to_map(sample)

    Enum.map(headers, fn header ->
      atom_key = String.to_atom(header)
      value = Map.get(sample_map, atom_key)
      convert_sample_value_to_csv(atom_key, value)
    end)
  end

  defp convert_sample_value_to_csv(key, value)
       when key in [:retrieved_contexts, :reference_contexts, :multi_responses] do
    case value do
      list when is_list(list) -> Enum.join(list, ";")
      _ -> ""
    end
  end

  defp convert_sample_value_to_csv(key, value) when key in [:rubrics, :tags] do
    case value do
      map when is_map(map) ->
        map
        |> Enum.map(fn {k, v} -> "#{k}:#{v}" end)
        |> Enum.join(";")

      _ ->
        ""
    end
  end

  defp convert_sample_value_to_csv(_key, value) do
    case value do
      nil -> ""
      val -> to_string(val)
    end
  end

  defp get_standard_headers do
    [
      "id",
      "user_input",
      "retrieved_contexts",
      "reference_contexts",
      "response",
      "multi_responses",
      "reference",
      "rubrics",
      "tags"
    ]
  end
end
