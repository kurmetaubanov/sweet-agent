defmodule Sweet.Secret do
  @moduledoc """
  Reading the secrets from `/run/secrets`, and not from the environment.

  Why not from the environment. The hand has the docker API (through docker-filter), and it
  gives out the environment of a container through several routes: `inspect` (there
  `Config.Env` is cut out) and `docker top` with `ps_args=wwaxe` (there it is not cut out
  by anything). That is, one GET printed the model key and the telegram token in full.
  The label `sweet.protected` did not save from this: it closes `docker cp` and the removal
  of a container, and not the reading of metadata.

  A file in `/run/secrets` cannot be obtained that way. Compose mounts it (the source
  `file:` in docker-compose.yml), and mountings get neither into `docker
  export` nor into `docker commit` — checked by measurement, both give zero bytes.
  The only route to the contents, `archive` (`docker cp`), is forbidden for
  protected containers in docker-filter.

  The value is cached in `:persistent_term`: `token/0` is called on every request
  to Telegram, while the secret does not change during the life of the container.
  """

  require Logger

  @dir "/run/secrets"

  @doc """
  The value of the secret `name` or `nil`.

  First the file `/run/secrets/<name>`, then the environment variable `env` —
  a fallback for an old .env, so that the stack does not fall silently on a rollout.
  """
  @spec get(String.t(), String.t()) :: String.t() | nil
  def get(name, env) do
    case :persistent_term.get({__MODULE__, name}, :miss) do
      :miss ->
        value = read(name, env)
        # We cache nil too: otherwise every call would hit the disk in vain.
        :persistent_term.put({__MODULE__, name}, value)
        value

      value ->
        value
    end
  end

  defp read(name, env) do
    path = Path.join(@dir, name)

    case File.read(path) do
      {:ok, content} ->
        case String.trim(content) do
          "" -> from_env(name, env, path)
          value -> value
        end

      {:error, :enoent} ->
        from_env(name, env, path)

      {:error, reason} ->
        Logger.warning("#{path} read failed (#{inspect(reason)})")
        from_env(name, env, path)
    end
  end

  defp from_env(name, env, path) do
    case System.get_env(env) do
      nil ->
        nil

      "" ->
        nil

      value ->
        Logger.warning(
          "the secret #{name} was taken from #{env}, and not from #{path}: the environment of a container " <>
            "is visible through the docker API, move the value into secrets"
        )

        value
    end
  end
end
