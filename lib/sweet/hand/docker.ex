defmodule Sweet.Hand.Docker do
  @moduledoc """
  The only place that knows about docker.

  Right now it speaks directly into the unix socket of the host daemon — this is the development
  stage. WHILE THIS IS SO, code written by the model is NOT loaded into the harness:
  brain with access to the socket equals root on the host.

  The transition to docker-filter is a change of one line in the config
  (`{:tcp, "sweet-docker-filter", 2375}`), the logic below does not change: both
  are one and the same Docker Engine API.
  """

  @api "/v1.43"

  @doc """
  Create the container of the hand. Returns the id.

  `opts` allows assembling not a hand, but another supervised container of the same
  design — for instance the embedder: the same protocol, the same connection to the
  listener, only the image, the limits and the variables differ.
  """
  def create(name, opts \\ []) do
    cfg = Application.get_all_env(:sweet)

    body = %{
      "Image" => Keyword.get(opts, :image, cfg[:hand_image]),
      "Hostname" => name,
      "Labels" => %{"sweet" => "hand"},
      "WorkingDir" => cfg[:workspace_guest_path],
      # The hand connects to brain itself — it opens no ports and does not wait
      # for anyone to knock at it.
      "Env" =>
        [
          "SWEET_BRAIN_HOST=#{cfg[:brain_host]}",
          "SWEET_BRAIN_PORT=#{cfg[:listen_port]}",
          "PYTHONUNBUFFERED=1"
        ] ++ Keyword.get(opts, :env, hand_env(name)),
      "HostConfig" => %{
        "Binds" =>
          Keyword.get(opts, :binds, [
            "#{cfg[:workspace_host_path]}:#{cfg[:workspace_guest_path]}:rw",
            # Skills — READ ONLY. They are not edited by the one who
            # uses them: an agent rewriting an instruction on the results of
            # its own failure would fit the instruction to the failure. The prohibition
            # is held by the kernel, and not by an agreement in the prompt.
            "#{cfg[:skills_host_path]}:#{cfg[:skills_root]}:ro"
          ]),
        # Named volumes go SEPARATELY from Binds. In the Binds column a volume looks
        # like `name:/path` — an entry without a leading slash, and docker-filter,
        # which expects a host path there, rejects it as "the source is not
        # allowed". In Mounts the type is named explicitly, and the filter lets the volume through in the usual way.
        "Mounts" => Keyword.get(opts, :mounts, [ca_mount()]),
        "NetworkMode" => cfg[:hand_network],
        # Limiting the blast radius: without privileges, without elevation of rights,
        # the rootfs read-only (we write into /workspace and tmpfs).
        "CapDrop" => ["ALL"],
        # SecurityOpt is deliberately NOT here. "no-new-privileges" stood here, but
        # docker-filter cuts this column as a whole, without parsing the contents: in it
        # also go the opposite in meaning seccomp=unconfined/apparmor=unconfined.
        # The tightening fell under the general prohibition. The loss is small — there is nothing
        # to elevate rights in a container with no capabilities, no privileges and a read-only rootfs
        # with; it can be returned by teaching the filter to tell one from the other.
        "ReadonlyRootfs" => true,
        # A gigabyte, and not 256 MB: the rootfs is read-only, therefore the home directory
        # of the hand is moved into /tmp — the matplotlib cache is written there, temporary
        # files of the browser and the rest that needs $HOME. Chromium does not fit
        # in 256 MB.
        "Tmpfs" => %{"/tmp" => "rw,size=1g"},
        # Limits on the CHILD. Without them the OOM-killer of the host may pick the BEAM.
        "Memory" => Keyword.get(opts, :memory, cfg[:hand_memory_bytes]),
        "NanoCpus" => Keyword.get(opts, :nano_cpus, cfg[:hand_nano_cpus]),
        "PidsLimit" => cfg[:hand_pids_limit],
        "AutoRemove" => false
      }
    }

    case request("POST", "#{@api}/containers/create?name=#{name}", body) do
      {:ok, 201, %{"Id" => id}} -> {:ok, id}
      {:ok, status, body} -> {:error, {:create_failed, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The environment of the hand. Besides the identification variables there are two things here:
  #
  #   * the address of the egress filter. The network of the hand is declared internal, it has no direct route
  #     outward at all — the filter stands with one leg in this network, with the other
  #     in the internet. Removing the variables will not help the code of the model: there is simply
  #     nowhere to go past the filter;
  #   * MASKS instead of keys. The real values live only in the container of the
  #     filter and are substituted into the header already on the way out, on the allowed
  #     host. Therefore the hand (and it executes the code of the model) has nothing to leak.
  # The docker address for the hand. It is taken from the same config as the connection of
  # brain — there must not be two sources of truth here.
  defp docker_host_name do
    {:tcp, host, _port} = Application.get_env(:sweet, :docker)
    host
  end

  defp docker_host_port do
    {:tcp, _host, port} = Application.get_env(:sweet, :docker)
    port
  end

  defp hand_env(name) do
    cfg = Application.get_all_env(:sweet)
    proxy = "http://#{cfg[:egress_host]}:#{cfg[:egress_port]}"
    ca = cfg[:ca_guest_path]

    [
      "SWEET_HAND_TRANSPORT=connect",
      "SWEET_HAND_ID=#{name}",
      # The watchdog of jobs in the hand decides by this number when silence stops
      # be work. The number itself is POLICY and lives in config, while here it
      # is translated into seconds: that is how much the hand counts.
      "SWEET_JOB_QUIET_ALERT_S=#{div(cfg[:job_quiet_alert_ms], 1000)}",
      "HTTP_PROXY=#{proxy}",
      "HTTPS_PROXY=#{proxy}",
      "http_proxy=#{proxy}",
      "https_proxy=#{proxy}",
      # brain and docker-filter are neighbours on the internal network, there is no reason to drive them through
      # a proxy. For the filter this is not a convenience, but a necessity: the docker
      # CLI is written in Go, and net/http takes HTTP_PROXY for a tcp:// daemon too —
      # without the exception every command would go off into egress and fall.
      "NO_PROXY=#{cfg[:brain_host]},#{docker_host_name()},localhost,127.0.0.1",
      "no_proxy=#{cfg[:brain_host]},#{docker_host_name()},localhost,127.0.0.1",
      # Docker is given to the hand, that is, to the code of the model: a deliberate decision. What is possible is
      # decided by docker-filter, and not by the prompt: the service containers of the stack are closed
      # by the label sweet.protected, exec is forbidden to everyone, create is inspected by the body.
      "DOCKER_HOST=tcp://#{docker_host_name()}:#{docker_host_port()}",
      # The filter terminates TLS with its own certificate. Without trusting it any
      # https from the hand will run into a certificate verification error.
      "REQUESTS_CA_BUNDLE=#{ca}",
      "SSL_CERT_FILE=#{ca}",
      "CURL_CA_BUNDLE=#{ca}",
      "GIT_SSL_CAINFO=#{ca}",
      # pip trusts ONLY its own certifi and does not know about SSL_CERT_FILE: without
      # this line any pip install ran into CERTIFICATE_VERIFY_FAILED,
      # although the prompt promises the installation of packages. Checked — it fell.
      "PIP_CERT=#{ca}",
      "GITHUB_TOKEN=#{System.get_env("GITHUB_API_KEY_MASK", "")}",
      # The web search key is also a MASK. The real one will be substituted by the egress filter on
      # api.serpbase.dev; in the hand, which executes the code of the model, it is not there.
      "SERPBASE_API_KEY=#{System.get_env("SERPBASE_API_KEY_MASK", "")}",
      # Installation of packages on top. The rootfs is read-only, there is no root — an ordinary
      # pip runs into both prohibitions at once. We move the user directory into
      # the working folder: it is written, survives the death of the hand and is shared by all
      # sessions, therefore what was installed once will not have to be installed again.
      # PIP_USER makes --user the default behaviour, and python picks up
      # PYTHONUSERBASE itself — there is no need to write PYTHONPATH.
      "PYTHONUSERBASE=#{Path.join(cfg[:workspace_guest_path], ".python")}",
      "PIP_USER=1",
      "PIP_DISABLE_PIP_VERSION_CHECK=1"
    ]
  end

  # The CA certificate of the filter arrives at the hand as a shared folder of the host, read-only.
  # The path must be in DOCKER_FILTER_ALLOWED_BINDS, otherwise the filter will not let it through.
  defp ca_mount do
    cfg = Application.get_all_env(:sweet)

    %{
      "Type" => "bind",
      "Source" => cfg[:ca_host_path],
      "Target" => Path.dirname(cfg[:ca_guest_path]),
      "ReadOnly" => true
    }
  end

  def start(id) do
    case request("POST", "#{@api}/containers/#{id}/start", nil) do
      {:ok, status, _} when status in [204, 304] -> :ok
      {:ok, status, body} -> {:error, {:start_failed, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # There is nothing to remove: the container was not created at all (the bringing up broke earlier).
  # Formerly this same line went off to docker as `DELETE /containers/?force=true` —
  # a request without a name, the answer to which was thrown away anyway.
  def remove(nil), do: :ok

  def remove(id) do
    request("DELETE", "#{@api}/containers/#{id}?force=true&v=true", nil)
    :ok
  end

  def logs(id) do
    request("GET", "#{@api}/containers/#{id}/logs?stdout=true&stderr=true&tail=200", nil)
  end

  # What the daemon thinks about itself. SystemTime in the answer is the clock of the DAEMON, and
  # the daemon works on the host: from inside a container this is the only way to see the zone of the
  # host — brain has its own (UTC). The filter lets this route through as it is
  # (see docker-filter/proxy.py, the route "info").
  # The timeout is a parameter, and not the usual thirty seconds: the zone of the host is asked for
  # on every turn (see Sweet.HostTime), and a turn must not stand on the daemon. No answer in
  # a couple of seconds — the host time is simply unknown.
  def info(timeout_ms) do
    request("GET", "#{@api}/info", nil, timeout_ms)
  end

  # --- Transport ---

  defp request(method, path, body, timeout_ms \\ 30_000) do
    payload = if body, do: JSON.encode!(body), else: ""
    headers = [{"content-type", "application/json"}, {"host", "docker"}]

    case connect() do
      {:ok, conn} -> talk(conn, method, path, headers, payload, timeout_ms)
      {:error, reason} -> {:error, reason}
    end
  end

  # What you opened — close, whatever the outcome. Formerly `with` went into an error past
  # `close/1`, and the socket remained open until the death of the caller. This held
  # for a short time — the caller is a short-lived task — and that is why it did not catch the
  # eye; but the one who opened must clean up after themselves, and not the garbage collector.
  defp talk(conn, method, path, headers, payload, timeout_ms) do
    result =
      with {:ok, conn, ref} <- Mint.HTTP.request(conn, method, path, headers, payload),
           {:ok, _conn, status, resp} <- recv(conn, ref, nil, "", [], timeout_ms) do
        {:ok, status, decode(resp)}
      else
        {:error, reason} -> {:error, reason}
        {:error, _conn, reason} -> {:error, reason}
        {:error, _conn, reason, _responses} -> {:error, reason}
      end

    Mint.HTTP.close(conn)
    result
  end

  defp connect do
    case Application.fetch_env!(:sweet, :docker) do
      {:unix, path} -> Mint.HTTP1.connect(:http, {:local, path}, 0, hostname: "docker")
      {:tcp, host, port} -> Mint.HTTP1.connect(:http, host, port)
    end
  end

  # We wait for the answer of docker WITHOUT eating foreign messages.
  #
  # Here there was a non-selective `receive` that gave every message
  # to Mint, and on `:unknown` simply went to the next loop — that is,
  # threw it away. While this code spins inside a GenServer (and it spins:
  # the container is created from `init`/`handle_continue`), into such a funnel
  # falls a `$gen_call` from anyone who addressed us at that moment.
  # After that the caller waits for an answer forever.
  #
  # Therefore we accumulate foreign messages and return them to our mailbox when the request is finished:
  # the order is preserved, the messages are handled in the usual way.
  defp recv(conn, ref, status, acc, stashed, timeout_ms) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            {status, acc, done?} = fold(responses, ref, status, acc)

            if done? do
              restore(stashed)
              {:ok, conn, status, acc}
            else
              recv(conn, ref, status, acc, stashed, timeout_ms)
            end

          {:error, _conn, reason, _} ->
            restore(stashed)
            {:error, reason}

          :unknown ->
            recv(conn, ref, status, acc, [message | stashed], timeout_ms)
        end
    after
      timeout_ms ->
        restore(stashed)
        {:error, :docker_timeout}
    end
  end

  defp restore(stashed), do: stashed |> Enum.reverse() |> Enum.each(&send(self(), &1))

  defp fold(responses, ref, status, acc) do
    Enum.reduce(responses, {status, acc, false}, fn
      {:status, ^ref, s}, {_, a, d} -> {s, a, d}
      {:data, ^ref, chunk}, {s, a, d} -> {s, a <> chunk, d}
      {:done, ^ref}, {s, a, _} -> {s, a, true}
      _, acc -> acc
    end)
  end

  defp decode(""), do: %{}

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end
end
