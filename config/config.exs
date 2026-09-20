import Config

config :sweet,
  # The Docker Engine API — through docker-filter. brain no longer has a socket: the filter
  # reads the body of every request to create a container and cuts what could break out
  # onto the host (foreign folders, privileged, cap-add, host-namespaces).
  docker: {:tcp, "sweet-docker-filter", 2375},

  # The egress filter: the only door outward for the hand. The network of the hand itself is internal,
  # therefore the variables below say only WHERE to go — the network forbids going past it.
  egress_host: "sweet-egress",
  egress_port: 8080,

  # The CA certificate of the egress filter: it terminates TLS itself, and without trusting
  # it not a single https works in the hand. A shared folder of the host, read-only for the hand.
  # The path is a HOST one: the bind is allowed by the docker daemon of the host, and not by brain.
  ca_host_path: "/home/maha/projects/sweet-agent/certs",
  ca_guest_path: "/certs/mitmproxy-ca-cert.pem",

  # The image of the hand and the network in which the hand meets brain.
  hand_image: "sweet-hand:dev",
  # The network of the hand. The name deliberately does not coincide with the networks of previous launches (the project
  # was then called kea, and its networks still lie on the host). Docker does not re-apply
  # parameters to an already existing network — it silently takes it as it is, therefore
  # a coincidence of names would reduce the isolation to nothing, and it would be possible to notice this
  # only by hand.
  hand_network: "sweet_hands",

  # The listener to which the hands connect, and the address of brain from their side.
  listen_port: 4000,
  brain_host: "sweet-brain",
  hand_connect_timeout_ms: 60_000,

  # The working folder of the agent. The path is a HOST one: the bind is allowed by the docker daemon of the host,
  # and not by brain. Inside the hand it is visible as /workspace.
  workspace_host_path: "/home/maha/projects/kurmet-agent-space",
  workspace_guest_path: "/workspace",

  # Limits of the hand. They hang on the child, and not on brain — otherwise the OOM-killer
  # would pick the BEAM, and not the guilty Python.
  hand_memory_bytes: 2 * 1024 * 1024 * 1024,
  hand_nano_cpus: 2_000_000_000,
  hand_pids_limit: 256,

  # How long we wait for an answer from the hand before killing the container and bringing up a fresh one.
  hand_exec_timeout_ms: 120_000,

  # The watchdog of a background job. Background work has no turn that waits for it, and
  # there is nobody to notice that it has stopped: "it asks for input" and "it has been silent for two days"
  # look the same — like silence in the log.
  #
  # The first number — how much silence counts as waiting, and not work. Minutes, and
  # not seconds: the legitimate silence of a build and of a snapshot lasts for minutes, and
  # to declare it a hang means to send the model a false alarm every time.
  # The HAND looks by it (in /proc: what the process stands on and which pipe
  # its stdin points at), therefore the number goes off to it as an environment variable — see
  # Sweet.Hand.Docker.hand_env/1. An edit does not require rebuilding the image.
  job_quiet_alert_ms: 300_000,

  # The second — the ceiling of a job, and it is purely Elixir: "this job has been running for thirty
  # minutes" the session knows itself, without the hand and without the network (see Sweet.Session). The watchdog of the
  # hand does not reach here: it looks at the process, while a process is sometimes alive and
  # silent, waiting for nothing.
  job_hard_limit_ms: 1_800_000,

  # How much output of a job is shown in the event about it: the head, the tail and
  # a byte ceiling on top. The limit is deliberately double — a line is sometimes two hundred
  # kilobytes (base64, minified json, a dump of an array), and a count
  # in lines only would miss such a one entirely.
  #
  # What is cut out does NOT disappear: the log lies at the hand as a whole and is addressed by the hash of the
  # job, and is obtained by the read_log tool. Therefore here one can cut
  # boldly — this is not a loss, but an address instead of contents.
  tool_output_head_lines: 20,
  tool_output_tail_lines: 40,
  tool_output_bytes: 4096,

  # The budget of one turn. Tokens are the main limit, turns are a coarse
  # fuse against looping on a tool.
  token_budget: 400_000,
  turn_limit: 500,

  # The embedder: BERT in its own container with its own memory limit. Inside brain
  # its OOM would kill the container as a whole, that is, the agent.
  embed_image: "sweet-embedder:dev",
  embed_cache_volume: "sweet_models",
  embed_memory_bytes: 3 * 1024 * 1024 * 1024,
  embed_nano_cpus: 2_000_000_000,
  # Otherwise torch will take as many threads as there are cores and suffocate the schedulers of the BEAM.
  embed_threads: 2,
  embed_model: "intfloat/multilingual-e5-small",
  # The first call waits for the loading of the weights, hence the reserve.
  embed_timeout_ms: 180_000,

  # Skills. The folder is HOST one by origin, but both brain and the hand see it by
  # one path — /skills. It lies OUTSIDE /workspace deliberately: in /workspace the agent is the master, while
  # here it has only reading, and to keep this mixed up means to invite
  # confusion.
  #
  # The path is a READING one, and not a mount point, and these are two different things. What is mounted
  # is the whole folder — by both sides into the same /skills. Otherwise the line
  # "name: description — path", which the model reads with the eyes of the hand, leads a level
  # deeper than the file lies: the hand opens /skills/git-push/SKILL.md, while the folder
  # is mounted into /skills/optional, and there lies optional/git-push/SKILL.md.
  skills_root: "/skills",
  skills_host_path: "/home/maha/projects/sweet-agent/skills",
  # Inside the root there are two folders: the found ones and the mandatory ones. Named explicitly, and not
  # assembled by recursion over the root: the root is a warehouse, and not a skill, and a neighbouring
  # folder would get into the search from there as a skill. The folder may be absent — then there are
  # no skills of this kind.
  skills_optional_dir: "optional",
  skills_always_dir: "always",
  # How a skill travels into the model. false — as the line "name: description — path", the body of
  # SKILL.md the model reads itself, if it takes it up; true — as the body as a whole. Both
  # options are false by default: the body costs room in the context on EVERY turn, while
  # it is needed in one turn out of twenty. There are two keys, and not one, because
  # the price is different.
  skills_body: false,
  skills_always_body: true,
  # How much of what is found travels into the prompt. One figure for everything: skills and paragraphs of
  # memory are ranked together, by one and the same cosine, and the first N
  # are taken from the common list. There are no thresholds — we compare the candidates with
  # each other, and not with an invented number.
  context_take: 27,

  # How many skills reach the common queue with the memory. The selection is one for all,
  # but skills must not enter it as a whole library: there are only
  # `context_take` places, and twenty descriptions would displace the conversation from there.
  skills_take: 13,

  # The memory of a conversation: a window of paragraphs when counting a vector. The window is one and the same
  # both on writing and on a query — that is how it was checked by experience.
  recall_dir: "priv/recall",
  # The inventory of sessions — with its own store next to the memory.
  sessions_dir: "priv/sessions",
  recall_window: 3,
  # How many REPLICAS go into the model verbatim and into the memory query. Not paragraphs:
  # a paragraph is a unit of storage, a replica is a unit of conversation. A tool call
  # is not counted as a replica at all — it weighs zero (see Sweet.Recall.weight/1):
  # it is a trace of the work, and not something said in words.
  recall_tail_messages: 50,
  recall_take: 8,
  # If the embedder has fallen, paragraphs are stored without vectors and are re-indexed
  # later. The attempts are not endless: a lying embedder would otherwise spin the loop forever.
  recall_reindex_attempts: 5,
  recall_reindex_delay_ms: 30_000,

  # An addition to the result of a tool: the same paragraph about the go-ahead for edits
  # that stands in the system prompt, and in the same wording. The point is chosen by
  # the meaning — the model decides whether to edit a file or not exactly where it reads
  # the result. :off — do not append (the default), :turn — once per turn,
  # :each — to every step.
  reminder_edits: :off,

  # Whether to show the person the reasoning of the model — what it thinks as it takes
  # up the tools. By default no: with a reasoning model this is the longest
  # part of the answer, and in the chat it buries under itself both the code and the answer.
  # We do not stop collecting the blocks in any case (their composition is written to the log),
  # the switch mutes ONLY the showing.
  show_thinking: false,

  # How often to append the output of the code to an already sent message. More often —
  # we will run into the Telegram limit on edits and get a 429.
  telegram_edit_interval_ms: 2_500,

  # LLM. The request/answer format is the Anthropic Messages API; DeepSeek keeps a
  # compatible gateway, therefore a change of provider = a change of api_base and model.
  api_base: "https://api.deepseek.com/anthropic",
  model: "deepseek-flash",

  # Retries without frills: we count the attempts, wait between them, give up.
  # DeepSeek prices per million tokens, the deepseek-flash tariff. The provider does NOT
  # give its own cost in the answer (checked by a request: in usage only
  # tokens), therefore we count ourselves.
  #
  # There is no separate price for writing to the cache — it goes by the cache-miss tariff.
  # Peak hours by UTC: 01:00–04:00 and 06:00–10:00 on WEEKDAYS, the rest of the time
  # (including weekends entirely) is twice cheaper.
  price_peak_hours_utc: [1, 2, 3, 6, 7, 8, 9],
  price_peak: %{cache_hit: 0.006, cache_miss: 0.3, output: 1.2},
  price_off_peak: %{cache_hit: 0.003, cache_miss: 0.15, output: 0.6},

  # The log to a file: it survives the recreation of the container, unlike docker logs.
  log_path: "priv/log/sweet.log",
  log_max_bytes: 10 * 1024 * 1024,
  log_max_files: 5,

  api_attempts: 3,
  api_retry_delay_ms: 1_000,
  # How long to wait for the NEXT piece of the stream, and not for the answer as a whole. The provider sends
  # a ping even while the model is thinking, therefore a minute and a half of silence is not a
  # long answer, but a dead connection: we break it off and go into a retry.
  api_idle_timeout_ms: 90_000,
  api_heartbeat_ms: 30_000,
  api_notice_after_ms: 60_000,
  # The ceiling of generation per call. For deepseek-flash the limit is 384k, so the
  # restriction here is ours, and not the provider's. It used to be 8k — the model ran into it
  # in the middle of long code: stop=max_tokens, the stub went nowhere, while
  # the person got "(empty answer)".
  max_tokens: 32_000

# The key is taken from the environment at runtime (Sweet.LLM), it does not get into the config.

