defmodule Histogrex do
  @moduledoc """
  High Dynamic Range (HDR) Histogram allows the recording of values across
  a configurable range at a configurable precision.

  Storage requirement is fixed (and depends on how the histogram is configured).
  All functions are fully executed within the calling process (not serialized
  through a single process) as the data is stored within write-optimized ETS
  table. Each recording consists of as single call to `:ets.update_counter`.

  Read operations consiste of a single `:ets.lookup` and are subsequently
  processed on that copy of the data (again, within the calling process).

  The fist step involves creating a registry:

    defmodule MyApp.Stats do
      use Histogrex

      histogrex :load_user, min: 1, max: 10_000_000, precision: 3
      histogrex :db_save_settings, min: 1, max: 10_000, precision: 2
      ...
    end

  And then adding this module as a `worker` to your application's supervisor
  tree:

      worker(MyApp.Stats, [])

  You can then record values and make queries:

      alias MyApp.Stats

      Stats.record!(:load_user, 233)
      Stats.record!(:db_save_settings, 84)

      Stats.mean(:load_user)
      Stats.max(:db_save_settings)
      Stats.total_count(:db_save_settings)
      Stats.value_at_quantile(:load_user, 99.9)
  """
  use Bitwise

  @total_count_index 1

  defstruct [
    :name, :registrar, :bucket_count, :counts_length, :unit_magnitude,
    :sub_bucket_mask, :sub_bucket_count, :sub_bucket_half_count,
    :sub_bucket_half_count_magnitude, :template
  ]

  @type t :: %Histogrex{
    name: atom | binary, registrar: module,
    bucket_count: pos_integer, counts_length: pos_integer,
    unit_magnitude: non_neg_integer, sub_bucket_mask: non_neg_integer,
    sub_bucket_count: non_neg_integer, sub_bucket_half_count: non_neg_integer,
    sub_bucket_half_count_magnitude: non_neg_integer, template: nil | tuple,
  }

  defmodule Iterator do
    @moduledoc false
    defstruct [
      :h, :total_count, :counts,
      bucket_index: 0, sub_bucket_index: -1, count_at_index: 0,
      count_to_index: 0, value_from_index: 0, highest_equivalent_value: 0,
    ]

    @type t :: %Iterator{
      h: struct, total_count: non_neg_integer,
      bucket_index: non_neg_integer, sub_bucket_index: integer,
      count_at_index: non_neg_integer, count_to_index: non_neg_integer,
      value_from_index: non_neg_integer, highest_equivalent_value: non_neg_integer,
    }

    @doc """
    Resets the iterator so that it can be reused. There shouldn't be a need to
    execute this directly.
    """
    @spec reset(t) :: t
    def reset(it) do
      %{it |
        bucket_index: 0, sub_bucket_index: -1, count_at_index: 0,
        count_to_index: 0, value_from_index: 0, highest_equivalent_value: 0
      }
    end

    @doc false
    @spec empty() :: t
    def empty() do
      h = %Histogrex{
        bucket_count: 0, counts_length: 1, sub_bucket_mask: 0, unit_magnitude: 0,
        sub_bucket_half_count: 0, sub_bucket_half_count_magnitude: 0, sub_bucket_count: 0,
      }
      %Iterator{total_count: 0, counts: 0, sub_bucket_index: 0, h: h}
    end
  end


  @doc false
  defmacro __using__(_opts) do
    quote location: :keep do
      use GenServer
      import Histogrex, only: [histogrex: 2, template: 2]
      alias Histogrex.Iterator, as: It

      @before_compile Histogrex

      Module.register_attribute(__MODULE__, :histogrex_names, accumulate: true)
      Module.register_attribute(__MODULE__, :histogrex_registry, accumulate: true)

      @doc false
      def start_link() do
        {:ok, pid} = GenServer.start_link(__MODULE__, :ok)
        GenServer.call(pid, :register_tables)
        {:ok, pid}
      end

      @doc false
      # we can't inline register_tables() in here as we need the @histogrex_registry
      # module to get loaded with values. register_tables is created via the
      # @before_compile hook
      def handle_call(:register_tables, _from, state) do
        register_tables()
        {:reply, :ok, state}
      end

      @doc false
      @spec record!(atom, non_neg_integer) :: :ok | no_return
      def record!(metric, value), do: record_n!(metric, value, 1)

      @doc false
      @spec record_n!(atom, non_neg_integer, non_neg_integer) :: :ok | no_return
      def record_n!(metric, value, n) do
        Histogrex.record!(get_histogrex(metric), value, n)
      end

      @doc false
      @spec record(atom, non_neg_integer) :: :ok | {:error, binary}
      def record(metric, value), do: record_n(metric, value, 1)

      @doc false
      @spec record_n(atom, non_neg_integer, non_neg_integer) :: :ok | {:error, binary}
      def record_n(metric, value, n) do
        Histogrex.record(get_histogrex(metric), value, n)
      end

      @doc false
      @spec record!(atom, atom | binary, non_neg_integer) :: :ok | no_return
      def record!(template, metric, value), do: record_n!(template, metric, value, 1)

      @doc false
      @spec record_n!(atom, atom | binary, non_neg_integer, non_neg_integer) :: :ok | no_return
      def record_n!(template, metric, value, n) do
        Histogrex.record!(get_histogrex(template), metric, value, n)
      end

      @doc false
      @spec record(atom, atom | binary, non_neg_integer) :: :ok | {:error, binary}
      def record(template, metric, value), do: record_n(template, metric, value, 1)

      @doc false
      @spec record_n(atom, atom | binary, non_neg_integer, non_neg_integer) :: :ok | {:error, binary}
      def record_n(template, metric, value, n) do
        Histogrex.record(get_histogrex(template), metric, value, n)
      end

      @doc false
      @spec value_at_quantile(Iterator.t | atom, number) :: non_neg_integer
      def value_at_quantile(%It{} = it, q) do
        Histogrex.value_at_quantile(it, q)
      end

      @doc false
      def value_at_quantile(metric, q) do
        Histogrex.value_at_quantile(get_histogrex(metric), q)
      end

      @doc false
      @spec value_at_quantile(atom, atom | binary, number) :: non_neg_integer
      def value_at_quantile(template, metric, q) do
        Histogrex.value_at_quantile(get_histogrex(template), metric, q)
      end

      @doc false
      @spec total_count(Iterator.t | atom) :: non_neg_integer
      def total_count(%It{} = it), do: Histogrex.total_count(it)

      @doc false
      def total_count(metric), do: Histogrex.total_count(get_histogrex(metric))

      @doc false
      @spec total_count(atom, atom | binary) :: non_neg_integer
      def total_count(template, metric), do: Histogrex.total_count(get_histogrex(template), metric)

      @doc false
      @spec mean(atom) :: non_neg_integer
      def mean(%It{} = it), do: Histogrex.mean(it)

      @doc false
      def mean(metric), do: Histogrex.mean(get_histogrex(metric))

      @doc false
      @spec mean(atom, atom | binary) :: non_neg_integer
      def mean(template, metric), do: Histogrex.mean(get_histogrex(template), metric)

      @doc false
      @spec max(Iterator.t | atom) :: non_neg_integer
      def max(%It{} = it), do: Histogrex.max(it)

      @doc false
      def max(metric), do: Histogrex.max(get_histogrex(metric))

      @doc false
      @spec max(atom, atom | binary) :: non_neg_integer
      def max(template, metric), do: Histogrex.max(get_histogrex(template), metric)

      @doc false
      @spec min(Iterator.t | atom) :: non_neg_integer
      def min(%It{} = it), do: Histogrex.min(it)

      @doc false
      def min(metric), do: Histogrex.min(get_histogrex(metric))

      @doc false
      @spec min(atom, atom | binary) :: non_neg_integer
      def min(template, metric), do: Histogrex.min(get_histogrex(template), metric)

      @doc false
      @spec reset(atom) :: :ok
      def reset(metric), do: Histogrex.reset(get_histogrex(metric))

      @doc false
      @spec reset(atom, atom | binary) :: :ok
      def reset(template, metric), do: Histogrex.reset(get_histogrex(template), metric)

      @doc false
      @spec iterator(atom) :: Iterator.t
      def iterator(metric) do
        Histogrex.iterator(get_histogrex(metric))
      end

      @spec iterator(atom, atom | binary) :: Iterator.t
      def iterator(template, metric) do
        Histogrex.iterator(get_histogrex(template), metric)
      end
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      @spec get_names() :: [atom]
      def get_names(), do: @histogrex_names

      defp register_tables() do
        :ets.new(__MODULE__, [:set, :public, :named_table, write_concurrency: true])
        for h <- @histogrex_registry do
          Histogrex.reset(h)
        end
      end

      def get_histogrex(_), do: {:error, :undefined}
    end
  end

  @doc """
  registers the histogram

  A `min`, `max` and `precision` must be supplied. `min` and `max` represent
  the minimal and maximal expected values. For example, if you're looking to
  measure how long a database call took, you could specify: `min: 1, max: 10_000`
  and provide time in millisecond, thus allowing you to capture values from 1ms
  to 10sec.

  `min` must be greater than 0.
  `max` must be greater than `min`.
  `precision` must be between 1 and 5 (inclusive).

  ## Examples

      histogrex :user_list, min: 1, max: 10000000, precision: 3

  """
  defmacro histogrex(name, opts) do
    quote location: :keep do
      @unquote(name)(Histogrex.new(unquote(name), __MODULE__, unquote(opts)[:min], unquote(opts)[:max], unquote(opts)[:precision] || 3, false))
      @histogrex_names unquote(name)
      @histogrex_registry @unquote(name)()
      def get_histogrex(unquote(name)), do: @unquote(name)()
    end
  end

  defmacro template(name, opts) do
    quote location: :keep do
      @unquote(name)(Histogrex.new(unquote(name), __MODULE__, unquote(opts)[:min], unquote(opts)[:max], unquote(opts)[:precision] || 3, true))
      def get_histogrex(unquote(name)), do: @unquote(name)()
    end
  end

  @doc """
  Creates a new histogrex object. Note that this only creates the configuration
  structure. It does not create the underlying ets table/entries. There should
  be no need to call this direction. Use the `histogrex` macro instead.
  """
  @spec new(binary | atom, module, pos_integer, pos_integer, 1..5, boolean) :: t
  def new(name, registrar, min, max, precision \\ 3, template \\ false) when min > 0 and max > min and precision in (1..5) do
    largest_value_with_single_unit_resolution = 2 * :math.pow(10, precision)
    sub_bucket_count_magnitude = round(Float.ceil(:math.log2(largest_value_with_single_unit_resolution)))

    sub_bucket_half_count_magnitude = case sub_bucket_count_magnitude < 1 do
      true -> 1
      false -> sub_bucket_count_magnitude - 1
    end

    unit_magnitude = case round(Float.floor(:math.log2(min))) do
      n when n < 0 -> 0
      n -> n
    end

    sub_bucket_count = round(:math.pow(2, sub_bucket_half_count_magnitude + 1))
    sub_bucket_half_count = round(sub_bucket_count / 2)
    sub_bucket_mask = bsl(sub_bucket_count - 1, unit_magnitude)

    bucket_count = calculate_bucket_count(bsl(sub_bucket_count, unit_magnitude), max, 1)
    counts_length = round((bucket_count + 1) * (sub_bucket_count / 2))

    template = case template do
      false -> nil
      true -> create_row(name, counts_length)
    end

    %__MODULE__{
      name: name,
      template: template,
      registrar: registrar,
      bucket_count: bucket_count,
      counts_length: counts_length,
      unit_magnitude: unit_magnitude,
      sub_bucket_mask: sub_bucket_mask,
      sub_bucket_count: sub_bucket_count,
      sub_bucket_half_count: sub_bucket_half_count,
      sub_bucket_half_count_magnitude: sub_bucket_half_count_magnitude,
    }
  end

  @doc """
  Same as `record/3` but raises on error
  """
  @spec record!(t, pos_integer, pos_integer) :: :ok | no_return
    def record!(h, value, n) do
    case record(h, value, n) do
      :ok -> :ok
      {:error, message} -> raise message
    end
  end

  @doc """
  Records the `value` `n` times where `n` defaults to 1. Return `:ok` on success
  or `{:error, message}` on failure. A larger than the 'max' specified
  when the histogram was created will cause an error. This is usually not called
  directly, but rather through the `record/3` of your custom registry
  """
  @spec record(t, pos_integer, pos_integer) :: :ok | {:error, binary}
  def record(h, value, n) do
    index = get_value_index(h, value)
    case index < 0 or h.counts_length <= index do
      true -> {:error, "value it outside of range"}
      false ->
        :ets.update_counter(h.registrar, h.name, [{2, n}, {index+3, n}])
        :ok
    end
  end

  @doc """
  Same as `record_template/4` but raises on error
  """
  @spec record!(t, atom | binary, pos_integer, pos_integer) :: :ok | no_return
  def record!(template, metric, value, n) do
    case record(template, metric, value, n) do
      :ok -> :ok
      {:error, message} -> raise message
    end
  end

  @doc """
  Records the `value` `n` times where `n` defaults to 1. Uses the template
  to create the histogram if it doesn't already exist. Return `:ok` on success
  or `{:error, message}` on failure. A larger than the 'max' specified
  when the histogram was created will cause an error. This is usually not called
  directly, but rather through the `record/3` of your custom registry
  """
  @spec record(t, atom | binary, pos_integer, pos_integer) :: :ok | {:error, binary}
  def record(h, metric, value, n) do
    index = get_value_index(h, value)
    case index < 0 or h.counts_length <= index do
      true -> {:error, "value it outside of range"}
      false ->
        :ets.update_counter(h.registrar, metric, [{2, n}, {index+3, n}], h.template)
        :ok
    end
  end

  @doc """
  Gets the value at the requested quantile. The quantile must be greater than 0
  and less than or equal to 100. It can be a float.
  """
  @spec value_at_quantile(t | Iterator.t, float) :: float
  def value_at_quantile(%Histogrex{} = h, q) when q > 0 and q <= 100 do
    do_value_at_quantile(iterator(h), q)
  end

  @doc """
  Gets the value at the requested quantile using the given iterator. When doing
  multiple calculations, it is slightly more efficent to first recreate and then
  re-use an iterator (plus the values will consistently be calculated based on
  the same data). Iterators are automatically reset before each call.
  """
  def value_at_quantile(%Iterator{} = it, q) when q > 0 and q <= 100 do
    do_value_at_quantile(Iterator.reset(it), q)
  end

  @doc """
  Gets the value at the requested quantile for the templated histogram
  """
  @spec value_at_quantile(t, atom, float) :: float
  def value_at_quantile(%Histogrex{} = h, metric, q) when q > 0 and q <= 100 do
    do_value_at_quantile(iterator(h, metric), q)
  end

  defp do_value_at_quantile(it, q) do
    count_at_percetile = round(Float.floor((q / 100 * it.total_count) + 0.5))

    Enum.reduce_while(it, 0, fn it, total ->
      total = total + it.count_at_index
      case total >= count_at_percetile do
        true -> {:halt, highest_equivalent_value(it.h, it.value_from_index)}
        false -> {:cont, total}
      end
    end)
  end

  @doc """
  Returns the mean value
  """
  @spec mean(t | Iterator.t) :: float
  def mean(%Histogrex{} = h), do: do_mean(iterator(h))

  @doc """
  Returns the mean value from the iterator
  """
  def mean(%Iterator{} = it), do: do_mean(Iterator.reset(it))

  @doc false
  def mean({:error, _}), do: 0

  @doc """
  Returns the mean value from a templated histogram
  """
  def mean(%Histogrex{} = h, metric), do: do_mean(iterator(h, metric))

  @doc false
  def mean({:error, _}, _metric), do: 0

  defp do_mean(it) do
    case it.total_count == 0 do
      true -> 0
      false ->
        total = Enum.reduce(it, 0, fn it, total ->
          case it.count_at_index do
            0 -> total
            n -> total + n * median_equivalent_value(it.h, it.value_from_index)
          end
        end)
        total / it.total_count
    end
  end

  @doc """
  Resets the histogram to 0 values. Note that the histogram is a fixed-size, so
  calling this won't free any memory. It is useful for testing.
  """
  @spec reset(t) :: :ok
  def reset(%Histogrex{} = h) do
    :ets.insert(h.registrar, create_row(h.name, h.counts_length))
    :ok
  end

  @doc """
  Resets the histogram to 0 values for the templated historam.
  Note that the histogram is a fixed-size, so calling this won't free any memory.
  """
  @spec reset(t, atom | binary) :: :ok
  def reset(%Histogrex{} = h, metric) do
    :ets.insert(h.registrar, create_row(metric, h.counts_length))
    :ok
  end

  defp create_row(name, count) do
    # +1 for the total_count that we'll store at the start
    List.to_tuple([name |  List.duplicate(0, count + 1)])
  end

  @doc """
  Get the total number of recorded values. This is O(1)
  """
  @spec total_count(t | Iterator.t) :: non_neg_integer
  def total_count(%Histogrex{} = h) do
    elem(get_counts(h), @total_count_index)
  end

  @doc """
  Get the total number of recorded values from an iterator. This is O(1)
  """
  def total_count(%Iterator{} = it) do
    it.total_count
  end

  @doc false
  def total_count({:error, _}), do: 0

  @doc """
  Get the total number of recorded values from an iterator. This is O(1)
  """
  @spec total_count(t, atom | binary) :: non_neg_integer
  def total_count(%Histogrex{} = h, metric) do
    case get_counts(h, metric) do
      nil -> 0
      counts -> elem(counts, @total_count_index)
    end
  end

  @doc false
  def total_count({:error, _}, _metric), do: 0

  @doc """
  Gets the approximate maximum value recorded
  """
  @spec max(t | Iterator.t) :: non_neg_integer
  def max(%Histogrex{} = h), do: do_max(iterator(h))

  @doc """
  Gets the approximate maximum value recorded using the given iterator.
  """
  def max(%Iterator{} = it), do: do_max(Iterator.reset(it))

  @doc false
  def max({:error, _}), do: 0

  @doc """
  Returns the approximate maximum value from a templated histogram
  """
  def max(%Histogrex{} = h, metric), do: do_max(iterator(h, metric))

  @doc false
  def max({:error, _}, _metric), do: 0

  defp do_max(it) do
    max = Enum.reduce(it, 0, fn it, max ->
      case it.count_at_index == 0 do
        true -> max
        false -> it.highest_equivalent_value
      end
    end)
    highest_equivalent_value(it.h, max)
  end

  @doc """
  Gets the approximate minimum value recorded
  """
  @spec min(t | Iterator.t) :: non_neg_integer
  def min(%Histogrex{} = h), do: do_min(iterator(h))

  @doc """
  Gets the approximate minimum value recorded using the given iterator.
  """
  def min(%Iterator{} = it), do: do_min(Iterator.reset(it))

  @doc false
  def min({:error, _}), do: 0

  @doc """
  Returns the approximate minimum value from a templated histogram
  """
  def min(%Histogrex{} = h, metric), do: do_min(iterator(h, metric))

  @doc false
  def min({:error, _}, _metric), do: 0

  defp do_min(it) do
    min = Enum.reduce_while(it, 0, fn it, min ->
      case it.count_at_index != 0 && min == 0 do
        true -> {:halt, it.highest_equivalent_value}
        false -> {:cont, min}
      end
    end)
    lowest_equivalent_value(it.h, min)
  end

  @doc false
  @spec iterator(t | {:error, any}) :: Iterator.t
  def iterator({:error, _}), do: Iterator.empty()

  def iterator(h) do
    counts = get_counts(h)
    %Iterator{h: h, counts: counts, total_count: elem(counts, @total_count_index)}
  end

  @doc false
  @spec iterator(t | {:error, any}, atom | binary) :: Iterator.t
  def iterator({:error, _}, _metric), do: Iterator.empty()

  def iterator(h, metric) do
    case get_counts(h, metric) do
      nil ->  Iterator.empty()
      counts -> %Iterator{h: h, counts: counts, total_count: elem(counts, @total_count_index)}
    end
  end

  defp get_counts(h), do: get_counts(h, h.name)

  defp get_counts(h, metric) do
    case :ets.lookup(h.registrar, metric) do
      [] -> nil
      [counts] -> counts
    end
  end

  defp calculate_bucket_count(smallest_untrackable_value, max, bucket_count) do
    case smallest_untrackable_value < max do
      false -> bucket_count
      true -> calculate_bucket_count(bsl(smallest_untrackable_value, 1), max, bucket_count + 1)
    end
  end

  defp get_value_index(h, value) do
    {bucket, sub} = get_bucket_indexes(h, value)
    get_count_index(h, bucket, sub)
  end

  @doc false
  def get_count_index(h, bucket_index, sub_bucket_index) do
    bucket_base_index = bsl(bucket_index + 1, h.sub_bucket_half_count_magnitude)
    offset_in_bucket = sub_bucket_index - h.sub_bucket_half_count
    bucket_base_index + offset_in_bucket
  end

  @doc false
  def value_from_index(h, bucket_index, sub_bucket_index) do
    bsl(sub_bucket_index, bucket_index + h.unit_magnitude)
  end

  @doc false
  def highest_equivalent_value(h, value) do
    next_non_equivalent_value(h, value) - 1
  end

  def lowest_equivalent_value(h, value) do
    {bucket_index, sub_bucket_index} = get_bucket_indexes(h, value)
    lowest_equivalent_value(h, bucket_index, sub_bucket_index)
  end

  def lowest_equivalent_value(h, bucket_index, sub_bucket_index) do
    value_from_index(h, bucket_index, sub_bucket_index)
  end

  defp next_non_equivalent_value(h, value) do
    {bucket_index, sub_bucket_index} = get_bucket_indexes(h, value)
    lowest_equivalent_value(h, bucket_index, sub_bucket_index) + size_of_equivalent_value_range(h, bucket_index, sub_bucket_index)
  end

  defp median_equivalent_value(h, value) do
    {bucket_index, sub_bucket_index} = get_bucket_indexes(h, value)
    lowest_equivalent_value(h, bucket_index, sub_bucket_index) + bsr(size_of_equivalent_value_range(h, bucket_index, sub_bucket_index), 1)
  end

  defp size_of_equivalent_value_range(h, bucket_index, sub_bucket_index) do
    adjusted_bucket_index = case sub_bucket_index >= h.sub_bucket_count do
      true -> bucket_index + 1
      false -> bucket_index
    end
    bsl(1, h.unit_magnitude + adjusted_bucket_index)
  end

  @doc false
  defp get_bucket_indexes(h, value) do
    ceiling = bit_length(bor(value, h.sub_bucket_mask), 0)
    bucket_index = ceiling - h.unit_magnitude - (h.sub_bucket_half_count_magnitude + 1)

    sub_bucket_index = bsr(value, bucket_index + h.unit_magnitude)
    {bucket_index, sub_bucket_index}
  end

  defp bit_length(value, n) when value >= 32768 do
    bit_length(bsr(value, 16), n + 16)
  end

  defp bit_length(value, n) do
    {value, n} = case value >= 128 do
      true -> {bsr(value, 8), n + 8}
      false -> {value, n}
    end

    {value, n} = case value >= 8 do
      true -> {bsr(value, 4), n + 4}
      false -> {value, n}
    end

    {value, n} = case value >= 2 do
      true -> {bsr(value, 2), n + 2}
      false -> {value, n}
    end

    case value == 1 do
      true -> n + 1
      false -> n
    end
  end
end

defimpl Enumerable, for: Histogrex.Iterator do
  use Bitwise
  @doc """
  Gets the total count of recorded samples. This is an 0(1) operation
  """
  def count(it), do: it.total_count

  @doc false
  def member?(_it, _value), do: {:error, __MODULE__}

  @doc false
  def reduce(_it, {:halt, acc}, _f), do: {:halted, acc}

  @doc false
  def reduce(it, {:suspend, acc}, f), do: {:suspended, acc, &reduce(it, &1, f)}

  @doc false
  def reduce(it, {:cont, acc}, f) do
    case it.count_to_index >= it.total_count do
      true -> {:done, acc}
      false -> do_reduce(it, acc ,f)
    end
  end

  @doc false
  defp do_reduce(it, acc, f) do
    h = it.h
    sub_bucket_index = it.sub_bucket_index + 1
    {it, bucket_index, sub_bucket_index} = case sub_bucket_index >= h.sub_bucket_count do
      true ->
        bucket_index = it.bucket_index + 1
        sub_bucket_index = h.sub_bucket_half_count
        it = %{it | bucket_index: bucket_index, sub_bucket_index: sub_bucket_index}
        {it, bucket_index, sub_bucket_index}
      false ->
        it = %{it | sub_bucket_index: sub_bucket_index}
        {it, it.bucket_index, sub_bucket_index}
    end

    case bucket_index >= h.bucket_count do
      true -> {:done, acc}
      false ->
        count_at_index = count_at_index(it, bucket_index, sub_bucket_index)
        value_from_index = Histogrex.value_from_index(h, bucket_index, sub_bucket_index)
        it = %{it |
          count_at_index: count_at_index,
          value_from_index: value_from_index,
          count_to_index: it.count_to_index + count_at_index,
          highest_equivalent_value: Histogrex.highest_equivalent_value(h, value_from_index),
        }
        reduce(it, f.(it, acc), f)
    end
  end

  defp count_at_index(it, bucket_index, sub_bucket_index) do
    index = Histogrex.get_count_index(it.h, bucket_index, sub_bucket_index)
    # 0 is the name
    # 1 is the total_count
    # the real count buckets start at 2
    elem(it.counts, index + 2)
  end
end
