defmodule Histogrex.Tests do
  use ExUnit.Case
  alias Histogrex

  # yes, sharing global state, but makes tests much faster. :deal_with_it:
  setup_all do
     for i <- (0..999_999) do
       FakeRegistry.record!(:user_load, i)
     end
     :ok
  end

  setup ctx do
    case ctx[:clear] do
      nil -> nil
      :http_ms ->
        FakeRegistry.reset(:http_ms, "users")
        FakeRegistry.reset(:http_ms, :about)
      key -> FakeRegistry.reset(key)
    end
    :ok
  end

  test "gets all registered metric names" do
    assert FakeRegistry.get_names() == [:high_sig, :user_load]
  end

  test "value at quantile" do
    for {q, v} <- [{50, 500223}, {75, 750079}, {90, 900095}, {95, 950271}, {99, 990207}, {99.9, 999423}, {99.99, 999935}] do
      assert FakeRegistry.value_at_quantile(:user_load, q) == v
    end
  end

  test "total count" do
    assert FakeRegistry.total_count(:user_load) == 1_000_000
  end

  test "max" do
    assert FakeRegistry.max(:user_load) == 1000447
  end

  test "min" do
    assert FakeRegistry.min(:user_load) == 0
  end

  test "mean" do
    assert FakeRegistry.mean(:user_load) == 500000.013312
  end

  test "lookups via iterator" do
    it = FakeRegistry.iterator(:user_load)
    assert FakeRegistry.min(it) == 0
    assert FakeRegistry.max(it) == 1000447
    assert FakeRegistry.mean(it) == 500000.013312
    assert FakeRegistry.total_count(it) == 1_000_000
    assert FakeRegistry.value_at_quantile(it, 75) == 750079
  end

  @tag clear: :http_ms
  test "records against template" do
    FakeRegistry.record!(:http_ms, "users", 20)
    FakeRegistry.record!(:http_ms, "users", 30)
    FakeRegistry.record!(:http_ms, :about, 100)
    FakeRegistry.record!(:http_ms, :about, 101)
    FakeRegistry.record!(:http_ms, :about, 102)

    assert FakeRegistry.total_count(:http_ms, "users") == 2
    assert FakeRegistry.total_count(:http_ms, :about) == 3

    assert FakeRegistry.value_at_quantile(:http_ms, "users", 50) == 21
    assert FakeRegistry.value_at_quantile(:http_ms, :about, 99.999) == 103

    assert FakeRegistry.min(:http_ms, "users") == 20
    assert FakeRegistry.min(:http_ms, :about) == 100

    assert FakeRegistry.max(:http_ms, "users") == 31
    assert FakeRegistry.max(:http_ms, :about) == 103

    assert FakeRegistry.mean(:http_ms, "users") == 26.0
    assert FakeRegistry.mean(:http_ms, :about) ==  101.66666666666667
  end

  @tag clear: :http_ms
  test "iterate against template value" do
    FakeRegistry.record!(:http_ms, :about, 100)
    FakeRegistry.record!(:http_ms, :about, 101)
    FakeRegistry.record!(:http_ms, :about, 102)

    it = FakeRegistry.iterator(:http_ms, :about)

    assert FakeRegistry.total_count(it) == 3
    assert FakeRegistry.value_at_quantile(it, 99.999) == 103
    assert FakeRegistry.min(it) == 100
    assert FakeRegistry.max(it) == 103
    assert FakeRegistry.mean(it) ==  101.66666666666667
  end

  @tag clear: :high_sig
  test "empty mean" do
    assert FakeRegistry.mean(:high_sig) == 0
  end

  @tag clear: :high_sig
  test "test high significant figure" do
    for value <- [459876, 669187, 711612, 816326, 931423, 1033197, 1131895, 2477317, 3964974, 12718782] do
      FakeRegistry.record!(:high_sig, value)
    end
    assert FakeRegistry.value_at_quantile(:high_sig, 50) == 1048575
  end

  @tag clear: :high_sig
  test "min not zero" do
    for value <- [459876, 669187, 711612] do
      FakeRegistry.record!(:high_sig, value)
    end
    # same as what the Go library gives at least
    assert FakeRegistry.min(:high_sig) == 262144
  end
end
