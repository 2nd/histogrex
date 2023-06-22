defmodule Histogrex.Mixfile do
  use Mix.Project

   @version "0.0.9"

  def project do
    [
      app: :histogrex,
      deps: deps(),
      elixir: "~> 1.7",
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
      ],
      docs: [
        source_ref: "v#{@version}", main: "Histogrex",
        canonical: "http://hexdocs.pm/histogrex",
        source_url: "https://github.com/2nd/histogrex",
      ]
    ]
  end

  def application do
    [applications: []]
  end

  defp deps do
    [
      {:ex_doc, "== 0.22.6", only: :dev},
      {:dialyxir, "== 1.0.0", only: [:dev], runtime: false},
      {:earmark, "== 1.4.10", only: :dev},
      {:earmark_parser, "== 1.4.10", only: :dev}
    ]
  end
end
