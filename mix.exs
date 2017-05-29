defmodule Histogrex.Mixfile do
  use Mix.Project

   @version "0.0.1"

  def project do
    [
      app: :histogrex,
      deps: deps(),
      elixir: "~> 1.4",
      name: "Histogrex",
      version: @version,
      consolidate_protocols: Mix.env != :test,
      description: "Concurrent High Dynamic Range (HDR) Histogram",
      package: [
        licenses: ["MIT"],
        links: %{
          "GitHub" => "https://github.com/2nd/histogrex"
        },
        maintainers: ["Karl Seguin"],
      ]
    ]
  end

  def application do
    [applications: []]
  end

  defp deps do
    [
      {:dialyxir, "~> 0.5", only: [:dev], runtime: false},
    ]
  end
end
