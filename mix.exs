defmodule Sweet.MixProject do
  use Mix.Project

  def project do
    [
      app: :sweet,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  # A release, and not `iex -S mix`. The difference is not in the convenience of the launch, but in what
  # happens when `Sweet.Supervisor` exhausts its stock of restarts.
  #
  # In the dev environment `start_permanent` is false: the application stops, while
  # the BEAM stays alive — the node lies, and there is no one to bring it up, because from
  # the point of view of docker the container is alive. In a release (`MIX_ENV=prod`)
  # `start_permanent` is true: the death of the root supervisor puts out the VM, the container
  # exits, and docker brings it up again by `restart:` (see compose).
  # That is how the chain "let it crash" closes at the last level — at the node.
  #
  # `start_iex` instead of `start`: IEx remains the front end, `docker attach sweet-brain`
  # works as before.
  defp releases do
    [
      sweet: [
        include_executables_for: [:unix],
        # `rel/env.sh.eex` is taken from here — it mutes the distribution. The path is the
        # same as by default, and it is named explicitly: the file lies there not by chance,
        # and to find it by this line is simpler than to guess about the folder.
        rel_templates_path: "rel"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Sweet.Application, []}
    ]
  end

  defp deps do
    [
      # The Docker Engine API on top of a unix socket — Mint can do {:local, path}.
      {:mint, "~> 1.6"},
      # HTTP to the model: a pool on top of the same Mint. We do not take Req — of its
      # batteries we use none, while it drags along Jason and Mime as well.
      {:finch, "~> 0.21"},
      # The listener to which the hands connect.
      {:thousand_island, "~> 1.3"},
      # The memory of conversations. DETS is not suitable for a shared archive: the file limit is 2 GB,
      # and a hard death of the BEAM (`docker rm -f`) repairs it as a whole. CubDB is
      # pure Elixir, an immutable B-tree, and to survive a sudden shutdown
      # is its direct goal.
      {:cubdb, "~> 2.0"}
      # JSON — the built-in module of Elixir 1.18 on top of the Erlang :json,
      # it is faster than Jason. A separate dependency is not needed.
    ]
  end
end
