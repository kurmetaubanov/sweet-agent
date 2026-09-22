# Sweet Agent

An agent on Elixir/OTP. The brain on BEAM, the hands and the memory in separate containers.

```text
host
│
├─ sweet-docker-filter          the only one that sees /var/run/docker.sock
│     ▲ :2375                   what is not in the route table — 403 (exec,
│     │                         attach, commit, push); the contents of containers
│     │                         labelled sweet.protected are closed; the body of
│     │                         create is not checked, but rebuilt from the
│     │                         declared fields
│     │
├─ sweet-brain                  Elixir. The turn, sessions, memory, keys.
│     │                         There is no code written by the model here.
│     │  creates containers via the docker filter
│     ├─────────────────┬───────────────────────┐
│     │                 │                       │
└─ sweet-hand-<id>      sweet-embedder          │
   Python core,         BERT, computes vectors   │
   executes the model's of conversation          │
   code                 paragraphs               │
      ▲                 ▲                       │
      └─────────────────┴── connect to the brain's listener THEMSELVES (port 4000),
                            frame = 4 bytes of length + JSON
      │
      └─ outward — only through sweet-egress-filter: the hand carries a MASK,
         the real key is substituted into the header already on the way out

three networks: sweet_hands (internal, here the brain, the hand and the embedder meet),
          sweet_ctl   (internal, brain ↔ docker filter),
          sweet_world (ordinary, from here the brain reaches the model and Telegram)
```

## What lies where

| Path | What it is |
|---|---|
| `lib/sweet/` | brain: the turn, sessions, memory, skills, bridges |
| `lib/sweet/harness/` | the prompt and the thresholds — what the agent itself edits over time |
| `hand/server.py` | the core of the hand: the cell, jobs, the /proc watchdog |
| `embedder/embedder.py` | the embedder: BERT behind the same frame |
| `docker-filter/` | the Docker API filter |
| `egress-filter/` | substitution of keys on the way out |
| `.env.example` | a sample environment: keys, masks, host paths |
| `deploy.sh` | lay `.env` out into files in `secrets/` |
| `docker-compose.yml` | the stack: brain, hand (build only), two filters |
| `priv/` | memory and the inventory (CubDB), the log |
| `test/` | 77 tests |

The build is a release, not `iex -S mix`: in a release (`start_permanent: true`) the
death of the root supervisor kills the VM, the container exits, and docker raises it
again per `restart: unless-stopped`. That is how "let it crash" closes the loop on the
node. The release has no distribution (`RELEASE_DISTRIBUTION=none`): the hand sits
with the brain on one network, and access to distribution would mean executing code
right in the BEAM.

## Boundaries

| Boundary | By what | Protects from | Does not protect from |
|---|---|---|---|
| Supervision | OTP | crashes and hangs | it is not protection from hostile code |
| The hand's container | cap-drop=ALL, read-only rootfs, mem/cpu/pids limits, internal network | arbitrary code of the model — **the only real boundary** | not an absolute, but a limitation of the radius; the docker filter does not let `no-new-privileges` through, and the tightening is disabled |
| A socket instead of a NIF | TCP, `{:packet, 4}` | a crash and a segfault of Python | resource pressure — limits are needed |
| The docker filter | the route table, parsing the body of `create` | code of the model that reached docker | the route table is alive: a rare legitimate operation will hit a 403 |
| The egress filter | masks instead of keys, an allow-list of hosts and paths | leakage of a key by a compromised hand | unfiltered access: the hand can raise its own container in `sweet_world` and go around |
| The embedder's container | its own memory limit | an OOM in torch dragging the brain down | the code there is ours, isolation has nothing to do with it |

## The turn

    question → assemble context → LLM → is there a tool_use? → execute in the hand
           → result back to the LLM → ... → answer

The turn runs NOT in the session's GenServer, but in a task under `Sweet.Tasks` and
without a link to the session: otherwise the session is busy for the whole turn and
does not even hear "stop". The task sends pieces of text to the session, and the
session owns the hand and the mailbox — the task asks it for them. That is why
`Sweet.cancel/1` works from a neighbouring IEx session.

Seven tools are available to the model, and all of them are executed in the hand:

| Tool | What it does |
|---|---|
| `python` | a cell of the persistent IPython kernel: variables and imports live between calls |
| `elixir` | a script in a fresh VM |
| `bash` | a command in a shell |
| `read_log` | read a job's log (`head`, `tail`, `grep`) |
| `job_list` | see every running job at once: its process, its launch, its hard limit and its deadline |
| `job_send` | answer a job that waits for input |
| `job_signal` | send a signal to one job — the kernel and the rest of the work stay intact |

The difference between them is not the size of the code, but what one pays for a
timeout. Both answer with a handle: a tool call waits for nothing, the result will
come as an event. Formerly `exec` held the turn for as long as the cell was computing
— because of that the turn was divided into "while we compute" and "between calls",
and everything that arrived in the first half waited for the second.

* **the cell** (`python`) — the state lives in the kernel between calls, therefore a
  timeout means its loss: on it the hand dies entirely, and a fresh one takes its
  place;
* **the job** (`bash`, `elixir`) — the command gets a name, a log and a return code,
  and the hand will report the end itself with a `kind: job` frame. The life of the
  container is not tied to one turn of the model: background work survives both the
  end of the cell and the end of the turn.

A job cannot be silent forever, and there are two watchmen. The hand looks into
`/proc`, at what the process is sitting on and where its stdin points, and after five
minutes of silence writes to the model "it seems to be waiting for input". The ceiling
of thirty minutes is held by the session itself — this is pure Elixir, without the
hand and without the network: a process is sometimes alive and silent.

The output of a job does not travel into the context whole. In the event about the end
there is a head of 20 lines, a tail of 40 and 4 KB on top; what is cut out does not
disappear, but is addressed by the job's hash, and is retrieved by the `read_log`
tool. The ceiling is double deliberately: a line is sometimes two hundred kilobytes
(base64, minified json), and a count in lines alone would have let such a line
through. So that the hash can be found later, a line about the call itself is put into
memory — otherwise "the conversation about the log is found, but what to open it with
nobody knows".

The budget of a turn: 400 000 tokens and 500 rounds. The rounds are a crude fuse
against looping on a tool, the tokens are the main limit.

## The memory of the conversation

The whole history does NOT travel to the model. What travels:

1. the last 50 **utterances** verbatim — the working memory;
2. what was found by meaning — up to 8 paragraphs of memory and up to 13 skills, in one list;
3. the question itself.

The count is in utterances, not in paragraphs: a paragraph is the unit of storage and
search, but "the last three paragraphs" may turn out to be the tail of one long answer,
and the question it was answering will not get into the window. A record of a tool call
weighs zero: it is a trace of work, not something said in words.

The full history is nevertheless kept whole in `priv/recall` — one CubDB store for all
sessions — and survives a restart. The memory is shared: we search the whole archive of
conversations, and what is found is signed with the time and the session it was taken
from. The verbatim tail at the same time is only one's own. This is the difference from
compaction (as in prime-agent): there the old is retold by the model and what did not
get into the retelling is lost, here everything lies there and is retrieved by search.

The arrangement was tested by experience on a transcript of a conversation — the
`memory-experiments` repository. All the decisions come from there:

- **a paragraph, not an utterance.** An utterance of two pages contains five topics,
  its vector is an averaged mush.
- **the window.** A paragraph is embedded together with the three previous ones: "What
  is left is to pass the brain's address to the hand" by itself means nothing. We
  search by the vector with the window, we give back the paragraph itself.
- **there is no centering.** It ruled a compressed scale of raw cosines (two random
  texts give 0.85), but the scale was needed only by the threshold. Without a threshold
  the subtraction of the mean does not change the order, but on a small set it
  degenerates: with a single skill the mean equals it itself, and the closeness always
  came out zero.
- **selection by sorting in descending order, without a threshold** — between the
  useful and the garbage there is a threefold gap.
- **the query = the window + the question.** A bare question catches at the places
  where it itself is asked; the window sets the topic and that removes this.

Paragraphs and skills are ranked together, by one cosine and one measure: they have a
common embedder and a common query, and two selections with different rules would
compare the incomparable. The list is one, and it is cut twice: no more than 13 skills
and 8 paragraphs of memory reach the common heap, and from the heap the first 27
records are taken. The second cut does not fire today — 13 + 8 = 21 — and that is
exactly what is said in "what is not done": the numbers here are decisions, not a
calculation.

We search in the process of the asker, not in the process of the memory: formerly the
search was a call to `Sweet.Recall`, and that one answered nobody during the
vectorization of the query — every conversation waited for someone else's search,
although the only thing common here is the table, and `:ets` is read by everyone at
once.

If the embedder has fallen, paragraphs are put away without vectors and are reindexed
later, five attempts with a pause of half a minute. They are not lost — they are simply
not searched until they are computed. `Sweet.Embed` is deliberately not part of the
memory group: the memory survives its absence by itself.

## Skills

A skill is a folder with `SKILL.md`; in the front matter there is a name and one
sentence about what it is useful for. The format deliberately coincides with
prime-agent: skills are transferred between agents without rework.

Skills are of two kinds, and they differ not in content, but in the way they get into
the prompt. The obligatory ones (`/skills/always`) lie in the system part ALWAYS,
outside the ranking: this is a rule, not a find by the meaning of the question. The
rest (`/skills/optional`) are searched in the same way as paragraphs of memory, and
travel to the model only if they came out first.

Why search, and not a list. In Claude Code and prime the descriptions of all skills
hang in the system prompt permanently: twenty skills are several thousand tokens on
EVERY turn, whether they are needed or not. The selection is also the only protection
from a bad skill: the less extra is laid underneath, the fewer occasions to apply
something out of place.

Usually only the description and the path travel into the prompt — the model reads the
body of `SKILL.md` itself, with an ordinary `open()` in the hand, and only when the
skill is really needed. The "with the body" mode is switched on by an option and costs
dearly: the body takes up room on every turn.

The skills folder is mounted into the hand read-only, and deliberately lies outside
`/workspace`: in the working folder the agent is the master, and here it has only
reading. The instructions are not edited by the one who uses them: an agent editing an
instruction on the results of its own failure fits the instruction to the failure, and
not the other way round.

## File exchange

Two folders in the agent's working directory:

    exchange/inbox/     the brain puts here what was sent into the chat
    exchange/outbox/    the brain takes from here and sends into the chat

The folders lie inside `/workspace`, that is, they are visible both to the hand and to
the brain: the hand writes the result there with an ordinary `open(...)`, no special
tool is needed for this. "Put a file into the folder" is simpler to explain to the
model than a call scheme. What has already been sent we remember by a timestamp, and
not by moving it into an archive: the file stays lying where it was put. We take it
after the end of the turn — by that moment everything is written and closed.

## Input

Two: IEx and Telegram. The Telegram bridge comes up only if `TELEGRAM_BOT_TOKEN` is
set.

**A chat is a session** with the permanent name `tg-<chat>`. That is why the memory of
the conversation survives a restart: the session opens its own file and continues from
the place where it stopped. Commands: `/start` and `/help` — a greeting, `/stop` —
break off the current turn together with the executing code, `/kill` — close the
session altogether, `/new` — start a new one, `/resume` — return to a previous one
(with buttons, with the topic of the conversation in the caption; the topic is the
first question of the person).

A message that arrives DURING a turn is not lost and does not start a second turn: the
session mixes the text into the ongoing turn at the nearest boundary, having
interrupted the current cell with a signal for this. The record about the turn is
started by the session itself, and not by the bridge: while the bridge guessed about
the turn, a turn awakened by a job did not get into the guess, and the answer was lost.

The bridge consists of several processes, and this is deliberate.
`Sweet.Telegram.Poller` hangs on long polling — it is almost all the time blocked
waiting for an answer, and to keep the process responsible for sessions in that state
is impossible. `Sweet.Telegram` runs the sessions and does not block for long: the turn
goes through `ask_async`, the answer comes as a message. And nobody goes to the network
except the process per chat (`Sweet.Telegram.Chat`): while one chat uploads a
two-megabyte file, the rest work, because the waiting is its concern, and not a common
one.

While the agent is thinking, "typing…" hangs in the chat — this is `sendChatAction`, a
status and not a message: it does not eat limits and does not litter the history. A
separate process per turn refreshes it: formerly a timer did this, a reference to which
lay in the map of waiting turns, and "typing…" hung until a restart of the brain, as
soon as the record was overwritten by a second question.

Long text goes out as a rich message: an ordinary Telegram message breaks off at 4096
characters and the answer disappears whole, while rich has a limit of 32768 — there is
no need to cut. Code goes as a short `<pre>` of up to fifty lines, a long one — as a
collapsed quote: monospaced and collapsed at the same time is unattainable in Telegram,
a `<pre>` inside a quote is thrown away. The usage goes as a separate message, and not
as a postscript to the answer.

## Why a protocol of one's own, and not Jupyter/ZeroMQ

prime-agent talks to the kernel over Jupyter on top of ZeroMQ — there both ends are
foreign. Here both are ours. And the only living ZMQ binding for Erlang (`erlzmq2`) is
a NIF, that is, libzmq in the address space of the BEAM: exactly the scenario for the
avoidance of which everything is being built.

The direction of the connection at the same time is inverted: it is not the brain that
knocks on the container, but the container on the brain. Thus one does not have to guess
when the container has managed to come up (formerly there were 40 connection attempts
with pauses in the loop), the container does not open ports at all, and the listening
socket is one for all. An idle connection is not death: `read_timeout` is set to
`:infinity`, because while the model is thinking there is silence over the socket for
minutes, and liveness is tracked by a monitor anyway.

## Keys, docker and the way outward

Three decisions, and all three are about the fact that the hand has docker and the
model's code.

**Secrets come as files, not as environment.** The hand reads out the environment of
any container through the Docker API by several routes: `inspect` (there `Config.Env`
is cut out) and `docker top` with `ps_args=wwaxe` (there it is not cut out by
anything). A file in `/run/secrets` cannot be obtained that way: compose mounts it (the
source is `file:`), and mounts get into neither `docker export` nor `docker commit` —
checked by measurement, both give zero bytes. One reading route remains, `docker cp`,
and for labelled containers it is forbidden. `./deploy.sh` lays the keys out from
`.env` — it remains the only place where they are edited by hand. For the same reason
the number "whose chat this is" also comes as a file: by it the bot distinguishes the
owner from a stranger, and to strangers it executes code in a container.

**Docker goes through the filter.** The brain no longer has the socket. The daemon
listens on a unix socket, only the filter sees it, and the brain and the hand go to the
filter over TCP. The socket is closed over the network as well: the filter rejects
networks with it dynamically. The filter holds a route table. What is not in it — 403:
`exec`, `attach`, `commit`, `push`, `events` are absent deliberately (`exec` — execution
in someone else's container, `push` — a channel outward past egress, `events` tells
about the life of the service containers). Everything that gives out the CONTENTS of a
container (`archive`, `logs`, `top`, `stats`, `changes`, `export`) is closed for those
labelled `sweet.protected`: it was exactly through `archive` that `/run/secrets` leaked,
and through `top` the environment. The filter does not check the body of a request to
create a container, but REBUILDS it from the declared fields. While it enumerated the
dangerous ones (`Binds`, `Privileged`, `CapAdd`), `DriverOpts` on a volume,
`VolumeOptions` inside `Mounts` and everything Docker will add tomorrow slipped past it:
the list grew from attacks. Now the list grows from needs, and a miss becomes a loud
breakage with the name of the field in the answer, and not a quiet hole. There is no
intermediate `tecnativa/docker-socket-proxy`: it gave coarse categories, and its
transport twice turned out to be a door past the filter — the daemon's port answered
from a foreign network.

**Outward — only through the egress filter.** The hand carries a MASK, a knowingly
non-working string, and the real key lives only in the filter's container and is
substituted into the header on the way out — and only on an allowed host. The binding
to the host is not a formality: without it the agent would send the mask to its own
address and would get the real key back. The anchor of the check is the address of the
real connection, and not the header. The hand's network is declared `internal`,
therefore removing `HTTP_PROXY` by the model's code gives nothing: there is nowhere to
go past the filter. There is one caveat: with docker the hand can raise its own
container in `sweet_world` and go out past the filter — it has no keys, so this is not
a leak, but unfiltered access.

## What is left until self-improvement

The harness (`Sweet.Harness.Prompt`, `Sweet.Harness.Policy`) is code, not config, and
this is done deliberately: to add a clause "if the task is about SQL — lay the schema
underneath" is cheaper than to fence off a configuration for all cases. The prompt here
is a function of the session's state, the threshold is a function of the context, and
pattern matching expresses this more directly than any json. But to load code written
by the model into the harness is not yet possible:

1. take the harness out into a separate node **not** connected to the brain by
   distributed Erlang: nodes in a cluster trust each other completely, distribution is
   wiring, not a boundary;
2. compile the code proposed by the model in a container, and not in a `:peer` node:
   compilation of Elixir is already execution;
3. remember that a whitelist of calls by AST is a linter, not protection.

Memory texts arrive in the prompt as DATA and never turn into code: arbitrary text that
has got into the Elixir compiler is executed (interpolation, attributes, macros).

## Launch

```bash
# 1. keys: .env is the only place where they are edited by hand. A sample is .env.example
cp .env.example .env             # and fill it in
./deploy.sh                      # will lay .env out into files in secrets/

#    In .env, on the left the name in the file, on the right the variable:
#      SWEET_ANTHROPIC_API_KEY      the model's key (obligatory)
#      SWEET_TELEGRAM_BOT_TOKEN     without it the input is only through IEx
#      SWEET_TG_ALLOWED_USER_ID     whose chat to serve — also a secret
#      SWEET_GITHUB_API_KEY         substituted on github.com
#      SWEET_SERPBASE_API_KEY       web search, substituted on api.serpbase.dev
#    Plus, if needed, SWEET_*_MASK: masks that the hand sees instead of keys.
#    Moving to another machine is SWEET_*_HOST_DIR/_PATH in the environment: host
#    paths are substituted by the host's daemon, and not by the brain (see config/runtime.exs).

# 2. images. The embedder is NOT declared as a service in compose (the brain raises it
#    itself), therefore compose will not build it — the command is separate, and run it
#    from the root
docker build -f embedder/Dockerfile -t sweet-embedder:dev .

# 3. the stack
docker compose build
docker compose up -d
docker attach sweet-brain
```

Further — from IEx. The session is created by `Sweet.start/1`:

```elixir
iex> {:ok, s} = Sweet.start()
iex> Sweet.ask(s, "count how many lines are in the files of /workspace")
iex> Sweet.usage(s)
iex> Sweet.cancel(s)     # break off a long turn together with the executing code
iex> Sweet.stop(s)
```

Compose does not raise the hand (`scale: 0`) — the image is needed only so that it
exists; the brain itself creates and tidies up the hand's containers. A rebuild of the
hand's image is picked up at the next creation of a hand, that is, after a restart of
the brain.

To check — with the same Elixir that it works with, because the agent itself does not
have it: `docker run --rm -e MIX_ENV=test sweet-brain:dev mix test --no-start`
(77 tests).

## Rakes we have already stepped on

Written down so as not to step on them again — all three cost several hours.

**A non-selective `receive` in a GenServer.** The docker client was handing Mint
every message and on `:unknown` went to the next round — that is, was throwing it
away. The code spins inside `init`/`handle_continue`, therefore into the funnel fell
a `$gen_call` from anyone who addressed it at that moment; the caller waited for an
answer forever. Foreign messages must be accumulated and returned to the mailbox, and
not swallowed.

**Two reading modes of one socket.** The handshake was read out manually through
`Socket.recv`, and after `handle_connection` Thousand Island switches the socket into
active mode — a frame at the junction was lost. Now the handshake is a state of the
connection (`:hello → :ready`), the reading mode is one.

**An idle connection is not death.** In Thousand Island `read_timeout` defaults to a
minute, while our pauses between requests are longer: while the model is thinking,
there is silence over the socket. Connections broke, containers exited, the next
request fell. `:infinity` was set, liveness is tracked by a process monitor.

**An answer is not an event.** The waiter took the first frame that came. The very
first event about a background job would have travelled to the model as the result of
its request: it would have received someone else's result, and lost its own. Now the
kind of the frame is stated explicitly (`result` or `job`), and not derived from
"everything that is not stream", and the request number (`rid`) is returned in the
answer — there can be several waiters.

## What is not done

- **compaction is not needed, but the retrieval budget is**: `recall_take: 8`,
  `skills_take: 13` and `context_take: 27` are numbers, and not a calculation; one must
  cut by tokens;
- garbage paragraphs ("done", "777") take up places in the selection;
- the docker filter cuts `SecurityOpt` entirely, without parsing the contents,
  therefore `no-new-privileges` is not set in the hand's container: into this same field
  go `seccomp=unconfined` and `apparmor=unconfined`, and the filter does not know how
  to distinguish one from the other;
- the route table is assembled by the capabilities of the docker CLI, and not by a
  journal of requests: a rare legitimate operation may hit a 403 — cured by a line in
  the table;
- the self-improvement gate is not started: while the harness is not taken out of the
  brain, the model's code is not loaded into it.
