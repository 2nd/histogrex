# High Dynamic Range (HDR) Histogram for Elixir

Get percentile values from stream of input. Each histogram has a configurable
min, max and precision value which control both the accuracy and memory
requirements.

Learn more about [HDR Histograms](http://hdrhistogram.org/).

Writes (which ought to substantially outnumber reads) are in constant time
regardless of the configuration. Querying a histogram for a specific percentile,
or other metric (max value, min value) is slightly slower as the range and/or
precision grows. However, the implementation relies on write-optimized ETS
tables and thus operations are not serialized (beyond the locks used by ETS).

A histogram with a range of 1..1_000_000 and a precision of 3 takes roughly
16000 bytes.

## Usage

The fist step involves creating a registry:

```
defmodule MyApp.Stats do
  use Histogrex

  histogrex :load_user, min: 1, max: 10_000_000, precision: 3
  histogrex :db_save_settings, min: 1, max: 10_000, precision: 2
  ...
end
```

And then adding this module as a `worker` to your application's supervisor
tree:

```
worker(MyApp.Stats, [])
```


Values can then be recorded via the `record!` or `record` functions:

```
alias MyApp.Stats

Stats.record!(:load_user, 233)
Stats.record!(:db_save_settings, 84)
```

`min`, `max`, `total_count` and `value_at_quantile` are used to query the
histogram:

```
alias MyApp.Stats
Stats.mean(:load_user)
Stats.max(:db_save_settings)
Stats.total_count(:db_save_settings)
Stats.value_at_quantile(:load_user, 99.9)
```

It would be reasonable to have a GenServer dump these statistics to some log
ingestor every X seconds (10? 60?). This would be the only reader (though
concurrent reads are fully supported).

## Implementation

The core histogram implementation is taken from [the Go version](https://github.com/codahale/hdrhistogram).

In order to maintain high write throughput, data access is not serialized through
a single process. Instead, write-optimized (via the `write_concurrency: true` option)
ETS tables are used. Functions are fully executed by the calling process. A write consists of as single `:ets.update_counter` call. A read consists of a single `:ets.lookup`.

It is possible to use multiple registries, though I suspect this will have no impact
unless thousands or metrics with high load are used. Benchmark it.

You can get the memory requirements of a registry by calling:

```
:ets.info(MyApp.Stats)[:memory]
```

There's a bit of additional overhead for each histogram, but that will give you
the bulk of it.
