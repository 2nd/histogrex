defmodule Histogrex.Mixfile do
  use Mix.Project

   @version "0.0.4"

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
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:dialyxir, "~> 0.5", only: [:dev], runtime: false},
    ]
  end
end
