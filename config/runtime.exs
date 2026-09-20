import Config

# Settings depending on the PLACE of the launch, and not on the code.
#
# Everything else lives in `config.exs` and is compiled into the image — that is where it belongs:
# thresholds, budgets, deadlines and prices are decisions, and not circumstances.
# Here there is only what changes when the stack moves: addresses, images, host
# paths, the provider of the model. Formerly this too was compiled in, and a change of address
# required a rebuild of the image.
#
# The rule is one: there is no variable — the value from `config.exs` remains. Therefore
# the file changes nothing on a stand where not a single variable is set, and
# for the same reason there is no `System.fetch_env!` here: an empty environment is the norm, and
# not an accident.
#
# Secrets do NOT get here: the model key and the bot token are read at runtime from
# /run/secrets (see `Sweet.Secret`), because the environment of a container is visible
# through the docker API.

env = fn name ->
  case System.get_env(name) do
    nil -> nil
    "" -> nil
    value -> value
  end
end

# The docker filter: where brain knocks to create the container of the hand. The form
# `host:port`, as in compose.
docker =
  case env.("SWEET_DOCKER") do
    nil ->
      nil

    value ->
      case String.split(value, ":") do
        [host, port] -> {:tcp, host, String.to_integer(port)}
        [host] -> {:tcp, host, 2375}
      end
  end

port = fn name ->
  case env.(name) do
    nil -> nil
    value -> String.to_integer(value)
  end
end

overrides =
  [
    docker: docker,
    # Where the hand meets brain.
    brain_host: env.("SWEET_BRAIN_HOST"),
    listen_port: port.("SWEET_LISTEN_PORT"),
    # The images that brain brings up itself.
    hand_image: env.("SWEET_HAND_IMAGE"),
    embed_image: env.("SWEET_EMBED_IMAGE"),
    # Host paths: they are mounted by the docker daemon of the HOST, therefore they are host ones.
    # On a move to another machine they change, and nothing else.
    workspace_host_path: env.("SWEET_WORKSPACE_HOST_PATH"),
    skills_host_path: env.("SWEET_SKILLS_HOST_PATH"),
    ca_host_path: env.("SWEET_CA_HOST_PATH"),
    # The provider of the model. The request format is common (Anthropic Messages API), therefore
    # a change of provider is the address and the name of the model, and nothing else.
    api_base: env.("SWEET_API_BASE"),
    model: env.("SWEET_MODEL")
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

config :sweet, overrides
