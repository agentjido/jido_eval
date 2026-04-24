defmodule JidoEval.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/agentjido/jido_eval"
  @description "Ragas-like and agentic evaluation harness for LLM systems in the Jido ecosystem."

  def project do
    [
      app: :jido_eval,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: @description,
      name: "Jido Eval",
      source_url: @source_url,
      homepage_url: @source_url,
      source_ref: "v#{@version}",
      package: package(),
      docs: docs(),
      test_coverage: [
        tool: ExCoveralls,
        summary: [threshold: 90],
        export: "cov"
      ],
      dialyzer: [
        plt_add_apps: [:mix],
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt"
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.github": :test,
        "coveralls.html": :test,
        "coveralls.post": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {JidoEval.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Core
      {:req_llm, "~> 1.10"},
      {:llm_db, "~> 2026.4"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.4"},
      {:uniq, "~> 0.6"},
      {:zoi, "~> 0.18"},
      {:splode, "~> 0.3.1"},
      {:nimble_csv, "~> 1.2"},

      # Testing
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22.0", only: [:dev, :test], runtime: false},
      {:dotenvy, "~> 1.1"},
      {:ex_check, "~> 0.12", only: [:dev, :test]},
      {:ex_doc, "~> 0.37-rc", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18.5", only: [:dev, :test], runtime: false},
      {:expublish, "~> 2.5", only: [:dev], runtime: false},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.5", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.5", only: [:dev, :test]},
      {:mimic, "~> 2.0", only: [:dev, :test]},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false},
      {:plug, "~> 1.18", only: :test},
      {:quokka, "~> 2.10", only: [:dev, :test], runtime: false},
      {:sobelow, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      install_hooks: ["git_hooks.install"],
      docs: "docs --formatter html",
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --min-priority higher",
        "dialyzer --format dialyxir",
        "doctor --raise"
      ]
    ]
  end

  defp package do
    [
      description: @description,
      licenses: ["Apache-2.0"],
      maintainers: ["Mike Hostetler"],
      links: %{
        "Changelog" => "https://hexdocs.pm/jido_eval/changelog.html",
        "Discord" => "https://jido.run/discord",
        "Documentation" => "https://hexdocs.pm/jido_eval",
        "GitHub" => @source_url,
        "Website" => "https://jido.run"
      },
      files:
        ~w(config examples lib mix.exs LICENSE README.md CHANGELOG.md CONTRIBUTING.md AGENTS.md usage-rules.md coveralls.json .formatter.exs .credo.exs .doctor.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        {"README.md", title: "Overview", filename: "readme"},
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "usage-rules.md",
        {"examples/README.md", title: "Examples", filename: "examples"}
      ],
      groups_for_extras: [
        Guides: ~r/examples\/.+\.md/
      ],
      groups_for_modules: [
        "Top-Level API": [Jido.Eval],
        Configuration: [Jido.Eval.Config, Jido.Eval.RunConfig, Jido.Eval.RetryPolicy],
        Datasets: [
          Jido.Eval.Dataset,
          Jido.Eval.Dataset.CSV,
          Jido.Eval.Dataset.InMemory,
          Jido.Eval.Dataset.JSONL
        ],
        Samples: [Jido.Eval.Sample.SingleTurn, Jido.Eval.Sample.MultiTurn],
        Metrics: [
          Jido.Eval.Metric,
          Jido.Eval.Metrics,
          Jido.Eval.Metrics.ContextPrecision,
          Jido.Eval.Metrics.Faithfulness,
          Jido.Eval.Metrics.Utils
        ],
        Execution: [Jido.Eval.Engine, Jido.Eval.Engine.Run, Jido.Eval.Engine.Sample],
        Components: [
          Jido.Eval.Broadcaster,
          Jido.Eval.Middleware,
          Jido.Eval.Processor,
          Jido.Eval.Reporter,
          Jido.Eval.Store,
          Jido.Eval.ComponentRegistry
        ],
        Integrations: [Jido.Eval.LLM],
        Errors: [Jido.Eval.Error]
      ]
    ]
  end
end
