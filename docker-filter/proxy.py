#!/usr/bin/env python3
"""Docker API filter: the only door from the agent to the docker daemon.

Topology:
    agent → [this filter :2375] → /var/run/docker.sock

The intermediate tecnativa docker-socket-proxy is NOT here ANY MORE, and that is not
a simplification for the sake of beauty. It gave a coarse list of categories (EXEC=0, SYSTEM=0),
but the route table below is strictly thinner — exec, commit, attach, events, push
are forbidden by name. The layer became a duplicate, and the transport to it twice
turned out to be a hole: first tecnativa stood in a separate network, where the hand could
put its own container; then it was given a common netns with the filter — and its
0.0.0.0:2375 opened on the filter's IP in ALL of its networks, including the hand's network.
This was checked by indirect signs ("the name does not resolve", "zero networks"),
and both times the conclusion was wrong: the port answered.

The reason was not a particular network, but a redundant network hop inside the trusted
zone. Now the filter reads the socket itself: the daemon has no TCP port at all, so
there is nowhere to reach it past the filter — from no network, and under no
future change of topology.

Why: docker_guard.py matches the TEXT of a Bash command and is bypassed by assembling a flag from
a variable (V=$(printf -- '-v'); docker run $V host:ctr ...) — by the time the shell
expands everything, and the hook has already checked. This filter looks at the EXPANDED body
of POST /containers/create (docker CLI has already assembled the final JSON), so a bypass
by assembling a string is impossible here: the bind will appear in HostConfig.Binds as is.

Threat model: the agent is COMPROMISED (prompt-injection). Hence fail-closed:
- the request did not render unambiguously → 403, NOT a pass;
- the route is not in the table → 403, NOT a pass;
- the body does not read in full / does not parse → 403;
- the socket is visible only to the filter, and the daemon has no TCP port at all;
- the bind source is expanded through symlinks before the whitelist check;
- the network of the container being created: service networks are forbidden, and so are those where the socket is.

THE MAIN PROPERTY: RENDER, NOT COMPARE
-----------------------------------------
The previous version of the filter matched the parsed path with regexes, and sent UPSTREAM
the original string of the client (raw_path_qs). The filter and the daemon parsed it differently,
and that was enough to walk past all the checks at once:

    GET /containers/sweet-egress/%2e/archive?path=/run/secrets/github_api_key

The filter saw three segments (`sweet-egress`, `%2e`, `archive`), they did not fit
the pattern `<ref>/<verb>` — and the request went into passthrough untouched.
The daemon, however, folded `%2e` back into `.`, cleaned the path and executed
`/containers/sweet-egress/archive`, giving away the real key. The same also removed
the cutting of Config.Env, and the ban on exec. The class is well known — parser differential,
and it is not cured by enumerating encodings: after `%2e` will come `%252e`, `;` parameters,
unicode equivalents, double slashes.

That is why here the filter does NOT compare strings, but RENDERS the request into canonical
form and sends upstream EXACTLY IT — the path assembled from the recognized segments,
and the query reassembled from the allowed keys. The daemon receives what the decision was made
on, byte for byte, and cannot interpret it otherwise: there is nothing left to interpret.
The coincidence of what was checked with what was executed is a property of the construction, not of care.

The same technique closes the second family of bypasses: the body is re-issued by our
HTTP client, so discrepancies of Content-Length/Transfer-Encoding do not reach
the daemon.

What is allowed — see ROUTES. The list of routes is LIVE: it is assembled by the capabilities of
the docker CLI, not by a journal of real requests, so a rare operation may
run into a 403. That is cured by a line in the table, and not by a return to passthrough.

The second layer: docker is given to the hand, so the service containers of the stack (label
sweet.protected) are closed to the verbs that break them or read them out. The list is
in the `protected` column of the table: "deny" (403), "env" (give inspect without
Config.Env), "ok" (does not touch secrets).
"""
import json
import os
import re
from urllib.parse import quote, unquote, urlencode

from aiohttp import web, ClientSession, ClientTimeout, UnixConnector

# Daemon. By default — a unix socket, and this is fundamental: it has NO TCP port,
# so the daemon cannot be reached past the filter from anywhere.
#
# Formerly a tecnativa docker-socket-proxy over TCP stood here. It was a second layer
# with a coarse list of categories (EXEC=0, SYSTEM=0), but our route table
# is strictly thinner — exec, commit, attach, events, push are forbidden by name. That
# is, the layer became a duplicate, but the transport to it twice turned out to be a hole:
# first tecnativa stood in a separate network, where the hand could put its own
# container; then we gave it a common netns with the filter — and its 0.0.0.0:2375
# opened on the filter's IP in ALL of its networks, including the hand's network. Both times
# what was cured was not the cause, but the next consequence.
#
# The cause is a redundant network hop inside the trusted zone. It is no longer there: the filter
# talks to the socket itself. There is nothing to close, because there is nothing to open.
DOCKER_SOCKET = os.environ.get("DOCKER_SOCKET", "/var/run/docker.sock")
# HTTP requests formally need a valid host; with the unix transport it does not go
# onto the network. UPSTREAM_URL is kept as an emergency detour over TCP.
UPSTREAM = os.environ.get("UPSTREAM_URL", "http://docker")


def _self_id() -> str:
    """Id of our own container (docker puts it in /etc/hostname).

    Needed so as not to mistake ourselves for a foreign socket: the filter stands in the network of
    the agent AND mounts the socket — without this the check below would forbid putting
    containers into the only network for the sake of which everything works.
    """
    try:
        with open("/etc/hostname") as fh:
            return fh.read().strip()
    except OSError:
        return ""


SELF_ID = _self_id()


def _session(timeout: ClientTimeout) -> ClientSession:
    """A session to the daemon: a unix socket, if there is one, otherwise TCP by UPSTREAM_URL."""
    if os.path.exists(DOCKER_SOCKET):
        return ClientSession(timeout=timeout, connector=UnixConnector(path=DOCKER_SOCKET))
    return ClientSession(timeout=timeout)  # noqa: emergency TCP, see UPSTREAM_URL


# The body limit ONLY for /containers/create. Real create bodies are kilobytes;
# more = suspicious (oversized-body bypass) → we reject. It does NOT apply to
# build/load/other (their bodies are the build context, can be large; we do not parse them).
MAX_CREATE_BODY = int(os.environ.get("MAX_CREATE_BODY", str(1 * 1024 * 1024)))  # 1 MiB

# The API version with which we present ourselves to the daemon, if the client did not name its own.
DEFAULT_API_VERSION = os.environ.get("DOCKER_FILTER_API_VERSION", "1.43")
_VERSION_RE = re.compile(r"^v\d+\.\d+$")


def _norm(p: str) -> str | None:
    """Normalizes a host source path of a bind-mount. None if the path is suspicious.

    We reject everything that is not absolute or contains '..' BEFORE normalization — so that
    the whitelist cannot be bypassed through /allowed/../../etc.
    """
    if not p or not p.startswith("/") or ".." in p.split("/"):
        return None
    return os.path.normpath(p)


def check_bind_source(raw: str) -> str | None:
    """The reason for refusal for a bind-mount source, or None.

    The whitelist is set by the CURATOR in .env, and it is not reconsidered here: what
    is allowed is allowed, including docker.sock and the data folders of foreign stacks.
    Only one thing is cured here — the way of checking.

    The hole was that the whitelist was compared with a STRING, while docker
    expands symlinks already on the host: the link `working_folder/sl → secrets`
    passed the string check, but what got mounted was the target. Expansion (realpath) closes this,
    but requires that the filter SEES the path — and it does not see everything.

    Hence the division, and it is not arbitrary:

    * the source is EXACTLY EQUAL to a whitelist entry — there is nothing to expand. This is exactly
      the object the curator named; it cannot be substituted, because what would have to be
      substituted is the entry itself. We let it through, even if the path is not visible
      to the filter (that is how docker.sock and data folders outside /home/maha/projects work).
    * the source is a SUBPATH inside the entry. It is here that a symlink leads outside,
      so we expand and require that the result stays inside. If we do not
      see the path — we refuse: we do not let through what cannot be checked.
    """
    src = _norm(raw)
    if src is None or not _is_allowed(src):
        return f"bind source not allowed: {raw}"

    if src in ALLOWED_BINDS:
        return None

    real = _resolve(src)
    if real is None:
        return (f"bind source not visible to filter: {raw} — mount into the filter "
                f"a read-only root inside which it lies")
    if not _is_allowed(real):
        return f"bind source resolves outside whitelist: {raw}"
    return None


def _resolve(p: str) -> str | None:
    """The real path with expanded symlinks, or None if the path is not visible.

    Only one who sees the same file system can expand, therefore
    the roots inside which subpaths are mounted are mounted into the filter read-only
    (see docker-compose.yml).
    """
    try:
        real = os.path.realpath(p)
    except OSError:
        return None
    if not os.path.exists(real):
        return None
    return real


def _is_allowed(src: str) -> bool:
    """True if src equals one of ALLOWED_BINDS or is a subfolder of it.

    allowed + "/" excludes a false prefix match (/data will not let /data2 through).
    """
    for allowed in ALLOWED_BINDS:
        if src == allowed or src.startswith(allowed + "/"):
            return True
    return False


def _load_list(var: str) -> set[str]:
    """A list of values from env through ':' or ','. Empty = nothing is allowed."""
    return {i.strip() for i in re.split(r"[:,]", os.environ.get(var, "")) if i.strip()}


def _load_allowed() -> set[str]:
    """Allowed bind-mount sources from env (empty = nothing is allowed).

    DOCKER_FILTER_ALLOWED_BINDS — paths through ':' or ','. The default is strict behaviour.
    """
    raw = os.environ.get("DOCKER_FILTER_ALLOWED_BINDS", "")
    out: set[str] = set()
    for item in re.split(r"[:,]", raw):
        item = item.strip()
        if not item:
            continue
        n = _norm(item)
        if n:
            out.add(n)
    return out


ALLOWED_BINDS = _load_allowed()

# Subpaths inside an allowed root are checked by expanding the symlink, and for
# that the filter must SEE the root. Exact whitelist entries are not included here:
# they need no expansion, which is why docker.sock and the data folders of foreign stacks
# do not appear in this list and work without mounting.
#
# We report at start, and not at the first refusal: the hand of sweet did not come up precisely
# because the needed root was not mounted, and it was possible to understand this only
# by the 403 at the moment the hand started.
_INVISIBLE = sorted(b for b in ALLOWED_BINDS if not os.path.exists(b))
if _INVISIBLE:
    print(
        "docker-filter: these roots are not visible to the filter, so a bind of SUBPATHS inside "
        "them will be rejected (the roots themselves, named exactly, work): "
        + ", ".join(_INVISIBLE)
        + " — if the subpaths are needed, mount the root here read-only by the same path",
        flush=True,
    )

# --- Networks: FORBIDDEN ones, the rest is possible --------------------------
#
# Here deliberately a black list, and not a white one — the only place in the filter
# where that is so. The reason is in the purpose: the agent helps to DEVELOP, it brings up
# its own stands of several containers and links them with its own networks. A white
# list broke this: creating a network is possible, but putting a container into it is not,
# that is, a dummy network. Strictness that hinders work and protects
# nothing is bad strictness.
#
# Exactly two things must be forbidden, and both are nameable:
#   * the control network (brain ↔ filter) — the hand has no business there;
#   * the outward network (the egress leg into the internet) — having got in there, a container
#     would go past the substitution of keys and past the filtering of traffic.
#
# The real protection is held not by this list, but by the rule in inspect_network: into a network
# where a container with docker.sock stands, one cannot get in regardless of names. It is
# dynamic and covers by itself what will appear tomorrow — while the list closes
# what does not contain the socket and therefore is not caught by the rule.
DENIED_NETWORKS = _load_list("DOCKER_FILTER_DENIED_NETWORKS")

# --- Protection of the service containers of the stack ----------------------
#
# Docker is given to the hand, that is, to the code of the model. So the infrastructure of the
# stack itself (brain, the egress filter, the filter itself and tecnativa) must be protected not
# by agreement, but here.
#
# We identify by LABEL, and not by name: the container name is a string in the request, and
# comparing it with the expected one would mean trusting the client. The label is put in
# by compose and is read from the daemon.
# --- privileged profile (VPN gateway) ---------------------------------------
#
# CapAdd/Devices are shut tight while these variables are empty. Filled —
# they allow exactly what is listed.
#
# ATTENTION, THESE THREE LINES HAVE ALREADY BEEN LOST TWICE when neighbouring blocks were edited:
# the names are used in render_create and inspect_connect, but an undefined name
# in Python is visible only when execution reaches it. The syntax is valid,
# the import with an empty environment passes, and it falls over on the first create with CapAdd.
# selftest.py caught this — keep running it as mandatory before rollout.
ALLOWED_CAPS = {c.upper().removeprefix("CAP_") for c in _load_list("DOCKER_FILTER_ALLOWED_CAPS")}
ALLOWED_DEVICES = {d for d in (_norm(x) for x in _load_list("DOCKER_FILTER_ALLOWED_DEVICES")) if d}
PRIV_NETWORKS = _load_list("DOCKER_FILTER_PRIV_NETWORKS")

# All HostConfig fields that choose a namespace. The list is ONE and is used
# by both gates below: "host" is cut in render_create, "container:<ref>" —
# in handle(), where there is a daemon, to look at the target.
#
# Formerly the parsing of container: was written only for NetworkMode, while the host modes
# were enumerated by a separate tuple on the spot. Because of this PidMode=container:
# slipped through: the field is in the schema, "host" does not equal it, and the private check knew
# nothing about it. The price of an error in PidMode is higher than in NetworkMode — userns-remap
# is off, root in the container is uid 0 of the host, and through /proc/1/root one reads
# the file system of the target together with /run/secrets. One list for both gates
# removes the very class of the miss: a new field is added here, and both parsings
# pick it up at once.
NAMESPACE_FIELDS = ("PidMode", "NetworkMode", "UsernsMode", "IpcMode",
                    "CgroupnsMode", "UTSMode")

PROTECTED_LABEL = os.environ.get("DOCKER_FILTER_PROTECTED_LABEL", "sweet.protected")

# --- The route table ------------------------------------------------------
#
# (methods, pattern, policy). The pattern is a tuple of segments AFTER the version; "*"
# means one arbitrary segment (a reference to an object). What is not here is a 403.
#
# protected: what to do if the referencing segment points at sweet.protected:
#   "deny" — 403;
#   "env"  — give the answer, cutting out Config.Env;
#   "ok"   — the route does not touch secrets (lists, help).
# q: allowed query keys. Everything else is discarded at render —
#    that is exactly how ps_args disappears, even if someone needs top itself.
# body: "create" — inspect the body further; "netattach" — take the reference to the
#    container out of the body and check it; None — we do not parse the body.
REF = "*"

ROUTES: list[tuple[frozenset[str], tuple[str, ...], dict]] = [
# --- help. The docker CLI pulls them on almost every command ---
    (frozenset({"GET", "HEAD"}), ("_ping",), {"protected": "ok", "q": frozenset(), "body": "none"}),
    (frozenset({"GET"}), ("version",), {"protected": "ok", "q": frozenset(), "body": "none"}),
    (frozenset({"GET"}), ("info",), {"protected": "ok", "q": frozenset(), "body": "none"}),

# --- containers: reading ---
    (frozenset({"GET"}), ("containers", "json"),
     {"protected": "ok", "q": frozenset({"all", "limit", "size", "filters"}), "body": "none"}),
    (frozenset({"GET"}), ("containers", REF, "json"),
     {"protected": "env", "q": frozenset({"size"}), "body": "none"}),
# Below — everything that gives out the CONTENTS of a container. For protected ones 403: it was
# through archive that /run/secrets leaked, and through top the environment.
    (frozenset({"GET"}), ("containers", REF, "logs"),
     {"protected": "deny",
      "q": frozenset({"stdout", "stderr", "tail", "since", "until", "timestamps", "follow"}), "body": "none"}),
    (frozenset({"GET"}), ("containers", REF, "top"),
     {"protected": "deny", "q": frozenset(), "body": "none"}),  # ps_args is not passed to anyone
    (frozenset({"GET"}), ("containers", REF, "stats"),
     {"protected": "deny", "q": frozenset({"stream", "one-shot"}), "body": "none"}),
    (frozenset({"GET"}), ("containers", REF, "changes"),
     {"protected": "deny", "q": frozenset(), "body": "none"}),
    (frozenset({"GET"}), ("containers", REF, "export"),
     {"protected": "deny", "q": frozenset(), "body": "none"}),
    (frozenset({"GET", "HEAD"}), ("containers", REF, "archive"),
     {"protected": "deny", "q": frozenset({"path"}), "body": "none"}),

# --- containers: change ---
    (frozenset({"POST"}), ("containers", "create"),
     {"protected": "ok", "q": frozenset({"name", "platform"}), "body": "create"}),
    (frozenset({"POST"}), ("containers", REF, "start"),
     {"protected": "deny", "q": frozenset({"detachKeys"}), "body": "none"}),
    (frozenset({"POST"}), ("containers", REF, "stop"),
     {"protected": "deny", "q": frozenset({"t", "signal"}), "body": "none"}),
    (frozenset({"POST"}), ("containers", REF, "restart"),
     {"protected": "deny", "q": frozenset({"t", "signal"}), "body": "none"}),
    (frozenset({"POST"}), ("containers", REF, "kill"),
     {"protected": "deny", "q": frozenset({"signal"}), "body": "none"}),
    (frozenset({"POST"}), ("containers", REF, "pause"),
     {"protected": "deny", "q": frozenset(), "body": "none"}),
    (frozenset({"POST"}), ("containers", REF, "unpause"),
     {"protected": "deny", "q": frozenset(), "body": "none"}),
    (frozenset({"POST"}), ("containers", REF, "rename"),
     {"protected": "deny", "q": frozenset({"name"}), "body": "none"}),
    (frozenset({"POST"}), ("containers", REF, "update"),
     {"protected": "deny", "q": frozenset(), "body": "opaque"}),
    (frozenset({"POST"}), ("containers", REF, "resize"),
     {"protected": "deny", "q": frozenset({"h", "w"}), "body": "none"}),
    (frozenset({"POST"}), ("containers", REF, "wait"),
     {"protected": "deny", "q": frozenset({"condition"}), "body": "none"}),
    (frozenset({"PUT"}), ("containers", REF, "archive"),
     {"protected": "deny", "q": frozenset({"path", "noOverwriteDirNonDir", "copyUIDGID"}), "body": "opaque"}),
    (frozenset({"DELETE"}), ("containers", REF),
     {"protected": "deny", "q": frozenset({"force", "v", "link"}), "body": "none"}),
    (frozenset({"POST"}), ("containers", "prune"),
     {"protected": "ok", "q": frozenset({"filters"}), "body": "none"}),

# --- images ---
    (frozenset({"GET"}), ("images", "json"),
     {"protected": "ok", "q": frozenset({"all", "filters", "digests", "shared-size"}), "body": "none"}),
    (frozenset({"POST"}), ("images", "create"),
     {"protected": "ok",
      "q": frozenset({"fromImage", "fromSrc", "repo", "tag", "message", "platform", "changes"}), "body": "opaque"}),
    (frozenset({"GET"}), ("images", REF, "json"), {"protected": "ok", "q": frozenset(), "body": "none"}),
    (frozenset({"GET"}), ("images", REF, "history"), {"protected": "ok", "q": frozenset(), "body": "none"}),
    (frozenset({"POST"}), ("images", REF, "tag"),
     {"protected": "ok", "q": frozenset({"repo", "tag"}), "body": "none"}),
    (frozenset({"DELETE"}), ("images", REF),
     {"protected": "ok", "q": frozenset({"force", "noprune"}), "body": "none"}),
    (frozenset({"POST"}), ("images", "prune"), {"protected": "ok", "q": frozenset({"filters"}), "body": "none"}),
    (frozenset({"POST"}), ("build",),
     {"protected": "ok",
      "q": frozenset({
          "t", "dockerfile", "q", "nocache", "cachefrom", "pull", "rm", "forcerm",
          "memory", "memswap", "cpushares", "cpusetcpus", "cpuperiod", "cpuquota",
          "buildargs", "shmsize", "squash", "labels", "networkmode", "platform",
          "target", "outputs", "version", "extrahosts", "buildid",
      }), "body": "opaque"}),
    (frozenset({"POST"}), ("build", "prune"), {"protected": "ok", "q": frozenset({"filters", "all"}), "body": "none"}),

    # --- networks ---
    (frozenset({"GET"}), ("networks",), {"protected": "ok", "q": frozenset({"filters"}), "body": "none"}),
    (frozenset({"GET"}), ("networks", REF), {"protected": "ok", "q": frozenset({"verbose", "scope"}), "body": "none"}),
    (frozenset({"POST"}), ("networks", "create"), {"protected": "ok", "q": frozenset(), "body": "opaque"}),
    (frozenset({"POST"}), ("networks", REF, "connect"),
     {"protected": "ok", "q": frozenset(), "body": "netattach"}),
    (frozenset({"POST"}), ("networks", REF, "disconnect"),
     {"protected": "ok", "q": frozenset(), "body": "netattach"}),
    (frozenset({"DELETE"}), ("networks", REF), {"protected": "ok", "q": frozenset(), "body": "none"}),
    (frozenset({"POST"}), ("networks", "prune"), {"protected": "ok", "q": frozenset({"filters"}), "body": "none"}),

    # --- volumes ---
    (frozenset({"GET"}), ("volumes",), {"protected": "ok", "q": frozenset({"filters"}), "body": "none"}),
    (frozenset({"POST"}), ("volumes", "create"), {"protected": "ok", "q": frozenset(), "body": "volume"}),
    (frozenset({"GET"}), ("volumes", REF), {"protected": "ok", "q": frozenset(), "body": "none"}),
    (frozenset({"DELETE"}), ("volumes", REF), {"protected": "ok", "q": frozenset({"force"}), "body": "none"}),
    (frozenset({"POST"}), ("volumes", "prune"), {"protected": "ok", "q": frozenset({"filters"}), "body": "none"}),
]

# The body policy is mandatory for EVERY route, and this is the main property of the table.
#
# Path and query were moved to "unknown is a refusal", while the body stayed on the old
# principle: it was inspected where someone thought about it, and went upstream untouched
# wherever nobody thought about it. That is how DriverOpts in volumes/create got through — a volume with
# o=bind,device=/etc is an ordinary bind to any path of the host, past the whole whitelist.
#
# That is why "not specified" no longer means "let through": the filter does NOT START until
# every line has an explicit decision. Now one can only forget loudly.
#
#   none      — there must be no body; if one arrived — 403;
#   create    — inspection of HostConfig (binds, privileges, networks);
#   volume    — inspection of the driver and DriverOpts;
#   netattach — the reference to a container lies in the body;
#   opaque    — we CONSCIOUSLY do not parse the body (stream: build-context, tar, layers).
#               The word in the table means "I saw this and decided", not "I forgot".
BODY_POLICIES = {"none", "create", "volume", "netattach", "opaque"}

for _methods, _pattern, _policy in ROUTES:
    if _policy.get("body") not in BODY_POLICIES:
        raise RuntimeError(
            f"route {sorted(_methods)} /{'/'.join(_pattern)} without a body policy: "
            f"name one of {sorted(BODY_POLICIES)}"
        )

# Routes that are deliberately absent from the table, so that this does not look like an omission:
#
#   containers/<ref>/exec, exec/<id>/*  — execution inside a foreign container.
#       Forbidden to everyone and always, even in one's own: tecnativa cuts it anyway
#       (EXEC=0), but an unclear refusal comes from there.
#   commit                              — makes an image from the file system of a
#       container, that is, a detour to its contents.
#   containers/<ref>/attach, /ws        — the same exec in other words.
#   images/<name>/push                  — a channel outward past the egress filter:
#       the daemon goes to the registry itself, the masking of keys does not concern it.
#   /events, /system/df, /session       — not needed by the hand, and /events also
#       tells about the life of the service containers.


class Deny(Exception):
    """The request did not render unambiguously or is not allowed. Always 403."""


def _deny(reason: str) -> web.Response:
# The error format of the Docker API, so that the client/agent gets a clear message.
    return web.json_response(
        {"message": f"blocked by docker-filter: {reason}"}, status=403
    )


def render_path(raw_path: str) -> tuple[str, list[str]]:
    """A raw path → (API version, segments). Everything ambiguous — Deny.

    We decode EXACTLY ONCE and segment by segment. Double encoding (%252e) after
    one disclosure gives the literal "%2e" — it is not equal to "." and simply will not match
    any pattern, that is, it will run into a 403, and will not unfold further.

    We reject the segments ".", ".." and the empty one, and do NOT fold them: in the docker API
    they do not occur, and the only one who needs them is the one who wants to diverge from
    our parsing. Folding would leave the question "whose normalization
    is more correct", the refusal removes it.
    """
    if "?" in raw_path:
        raw_path = raw_path.split("?", 1)[0]
    if not raw_path.startswith("/"):
        raise Deny("path is not absolute")

    parts = raw_path.split("/")[1:]
# A trailing slash is tolerated (the docker CLI sometimes sends it), an internal one is not:
# `/containers//json` the daemon will fold, while we would read it as a different route.
    if parts and parts[-1] == "":
        parts.pop()

    segs: list[str] = []
    for raw in parts:
# unquote_plus is not suitable: a '+' in a container name is a '+', not a space.
        seg = unquote(raw)
        if seg in (".", "..", ""):
            raise Deny(f"path segment {raw!r} is not allowed")
        if "/" in seg:
# %2f inside a segment is an attempt to forge the segment boundary.
            raise Deny("encoded slash in path segment")
        if "\x00" in seg or "\n" in seg or "\r" in seg:
            raise Deny("control character in path segment")
        segs.append(seg)

    if not segs:
        raise Deny("empty path")

    version = DEFAULT_API_VERSION
    if _VERSION_RE.match(segs[0]):
        version = segs[0][1:]
        segs = segs[1:]
        if not segs:
            raise Deny("empty path after version")
    return version, segs


def match_route(method: str, segs: list[str]) -> tuple[dict, str | None, int | None]:
    """Looks for a route in the table. Returns (policy, reference, its place in the path).

    The reference is the segment standing in the place of "*". It is by it that sweet.protected
    is checked, and it is also what handle() replaces with an immutable Id before forwarding — therefore
    one needs to know not only the value, but also the position.
    Not found — Deny: we NEVER let an unknown route through, otherwise we would be back
    to passthrough, because of which the hole existed.
    """
    method_mismatch = False
    for methods, pattern, policy in ROUTES:
        if len(pattern) != len(segs):
            continue
        ref = None
        ref_at = None
        for i, (want, got) in enumerate(zip(pattern, segs)):
            if want == REF:
                ref, ref_at = got, i
            elif want != got:
                break
        else:
            if method not in methods:
                # The path matched, the method did not. We do NOT refuse at once: further on in
                # the table there may lie a literal pattern with this method.
                # `POST /networks/create` would otherwise be intercepted by the pattern
                # ("networks", REF) with GET, and create/prune would be unavailable.
                method_mismatch = True
                continue
            return policy, ref, ref_at
    if method_mismatch:
        raise Deny(f"method {method} is not allowed on /{'/'.join(segs)}")
    raise Deny(f"route not allowed: {method} /{'/'.join(segs)}")


def render_query(query, allowed: frozenset[str]) -> str:
    """Rebuilds the query from the ALLOWED keys. The rest are silently discarded.

    Silently — deliberately: `docker ps` sends service fields that we do not know about,
    and there is no reason to fall over them. But ps_args will not reach the daemon, even if
    someone opens the top route: the key is not in the list — the key is not in the request.
    """
    pairs = [(k, v) for k, v in query.items() if k in allowed]
    return urlencode(pairs)


def build_url(version: str, segs: list[str], qs: str) -> str:
    """The canonical string UPSTREAM — from the recognized parts, not from the client's.

    It is here that the main property of the filter arises: the daemon receives exactly what
    the decision was made on. It has nothing to expand — in this string there are neither
    percent sequences of path separators, nor dot segments.
    """
    path = "/v" + version + "".join("/" + quote(s, safe="") for s in segs)
    return UPSTREAM + path + ("?" + qs if qs else "")


async def inspect_container(sess: ClientSession, ref: str) -> tuple[str | None, bool]:
    """(an immutable Id, whether it is protected). A resolution error → (None, True), fail-closed.

    The two answers are taken from ONE query not to save a request, but so that nothing
    could cut in between them. The decision was made by the referencing string, and it was with that
    same string that the request went upstream; and the reference is a name, and `rename` in the route
    table is open. So a window existed: one container was checked,
    the daemon executed over another one that had managed to take this name. A classic TOCTOU,
    a relative of substituting an id for a network name — there the spelling and the
    object diverged, here the moments in time diverge.

    Therefore what is given outward is the Id: it is not renamed. Then handle()
    substitutes it into the path instead of the client's reference, and upstream goes a request
    naming exactly the object on which the decision was made.

    We ask the daemon, and do not parse the string: ref may be a name, a short
    or a full id, and all three must lead to one answer.
    """
    url = UPSTREAM + "/v" + DEFAULT_API_VERSION + "/containers/" + quote(ref, safe="") + "/json"
    try:
        async with sess.get(url) as up:
            if up.status == 404:
                # There is no container — there is nothing to protect, let the daemon answer 404.
                # We do not substitute an Id: there is nothing to substitute, the client's reference will go.
                return None, False
            if up.status != 200:
                return None, True
            data = json.loads(await up.read())
    except Exception:
        return None, True
    if not isinstance(data, dict):
        return None, True
    labels = ((data.get("Config") or {}).get("Labels")) or {}
    if not isinstance(labels, dict):
        return None, True
    cid = data.get("Id")
    protected = str(labels.get(PROTECTED_LABEL, "")).lower() in ("1", "true", "yes")
    return (cid if isinstance(cid, str) and cid else None), protected


async def inspect_network(sess: ClientSession, ref: str) -> tuple[str, str | None]:
    """(network name, name of the container with the socket in it or None). We ask the daemon.

    One function for both questions not to save a request, but because both
    answers lie in ONE json and both cannot be obtained from the string:

    * THE NAME. DENIED_NETWORKS are names, while the daemon accepts both a name and an id and a
      short id prefix. While the decision was made by comparing the string with
      the name, substituting an id got through: `NetworkMode: <id sweet_world>`
      gave a 201, the container got an address in sweet_world and went into the internet past
      egress. The hole rested on the fact that in `connect` the name was resolved, while in
      `create` it was not; two checks of the same thing, made differently.
    * THE SOCKET. Into a network where a FOREIGN container with /var/run/docker.sock stands, one's own
      cannot be put: a neighbour may hand out the docker API over TCP, as tecnativa did.
      A rule instead of a list — it covers both neighbouring stacks and what
      will appear tomorrow, because it looks at a fact, and not at a name.

    We exclude ourselves from the socket check, and this is not an indulgence: the filter mounts the
    socket AS A FILE and does not give it outward, it is the one that checks. Without this
    exclusion the rule would forbid exactly the network for the sake of which it exists —
    at the first rollout the hand stopped being created that way.

    We did not parse it — an exception, and the caller answers with a refusal (fail-closed).
    """
    url = UPSTREAM + "/v" + DEFAULT_API_VERSION + "/networks/" + quote(ref, safe="")
    async with sess.get(url) as up:
        if up.status != 200:
            raise RuntimeError(f"networks/{ref} -> {up.status}")
        data = json.loads(await up.read())
    if not isinstance(data, dict):
        raise RuntimeError("network inspect is not an object")
    name = data.get("Name")
    if not isinstance(name, str):
        raise RuntimeError("network has no Name")

    for cid in (data.get("Containers") or {}):
        if SELF_ID and cid.startswith(SELF_ID):
            continue
        curl = UPSTREAM + "/v" + DEFAULT_API_VERSION + "/containers/" + quote(cid, safe="") + "/json"
        async with sess.get(curl) as up:
            if up.status != 200:
                # We could not find out — we consider it dangerous: fail-closed.
                raise RuntimeError(f"containers/{cid} -> {up.status}")
            info = json.loads(await up.read())
        for m in (info.get("Mounts") or []):
            if isinstance(m, dict) and m.get("Source") == "/var/run/docker.sock":
                return name, (info.get("Name") or cid).lstrip("/")
    return name, None


async def check_network(sess: ClientSession, ref: str) -> str | None:
    """The reason for refusal for the network one asks into, or None. One for create and connect.

    Formerly this was decided in two places differently, and they diverged silently.
    """
    name, owner = await inspect_network(sess, ref)
    if name in DENIED_NETWORKS:
        return f"network {ref!r} is {name!r} — denied"
    if owner:
        return (f"network {name!r} hosts the docker socket ({owner}) "
                f"— joining it would bypass this filter")
    return None


def _strip_env(data: dict) -> dict:
    """Remove Config.Env from an inspect answer.

    Only for protected containers: in brain and egress real keys used to lie there.
    Today they have moved to /run/secrets, but we still do not give out the environment:
    masks, addresses and the composition of the stack remain there. The other fields
    (networks, volumes, state) are needed by the hand and carry no secrets.
    """
    cfg = data.get("Config")
    if isinstance(cfg, dict) and "Env" in cfg:
        cfg = dict(cfg)
        cfg["Env"] = None
        data = dict(data)
        data["Config"] = cfg
    return data


# --- The schema of the body of containers/create ----------------------------
#
# Here is the same principle as with the path and the query, brought to the body: NOT to look for
# the bad in the client's JSON, but to ASSEMBLE upstream our own from the declared fields.
#
# While the filter enumerated the dangerous (Binds, Privileged, CapAdd, Mounts with
# Type=bind), DriverOpts on a volume, VolumeOptions inside Mounts,
# Type=image and everything Docker will add tomorrow slipped past it. Every such find required
# a new line of prohibition — that is, the list grew from attacks.
#
# The schema grows from NEEDS: a line is added when a legitimate operation ran into
# a refusal. And the side of the error changes: formerly a miss became a quiet hole,
# now — a loud breakage with the name of the field in the answer.
#
# The lists are assembled by actual usage on this host (38 containers:
# compose stacks, the VPN gateway, the hands of sweet), and not by the documentation of Docker.
CONFIG_KEYS = frozenset({
    "Hostname", "Domainname", "User", "Image", "Cmd", "Entrypoint", "Env",
    "Labels", "WorkingDir", "Tty", "OpenStdin", "StdinOnce", "AttachStdin",
    "AttachStdout", "AttachStderr", "ExposedPorts", "Volumes", "Healthcheck",
    "StopSignal", "StopTimeout", "ArgsEscaped", "NetworkDisabled", "Shell",
    "MacAddress", "HostConfig", "NetworkingConfig",
})

HOSTCONFIG_KEYS = frozenset({
    # mounts and the network — with a check of the values below
    "Binds", "Mounts", "NetworkMode", "PortBindings", "PublishAllPorts",
    # resources and the mode of operation
    "Memory", "MemorySwap", "MemoryReservation", "NanoCpus", "CpuShares",
    "CpuQuota", "CpuPeriod", "CpusetCpus", "PidsLimit", "ShmSize", "Tmpfs",
    "Ulimits", "OomKillDisable", "BlkioWeight", "StorageOpt", "Isolation",
    "RestartPolicy", "AutoRemove", "LogConfig", "Init", "ConsoleSize", "Runtime",
    # security: harmless in themselves, the values are checked separately
    "CapAdd", "CapDrop", "Devices", "DeviceRequests", "GroupAdd", "Sysctls",
    "ReadonlyRootfs", "MaskedPaths", "ReadonlyPaths",
    "IpcMode", "CgroupnsMode", "PidMode", "UsernsMode", "UTSMode",
    # names and the network
    "ExtraHosts", "Dns", "DnsSearch", "DnsOptions", "Annotations",
})
# What is NOT in the list — and this is the main point: Privileged, SecurityOpt, VolumesFrom,
# CgroupParent. Formerly they were forbidden by name, now they are simply not in the schema.

MOUNT_KEYS = frozenset({"Type", "Source", "Target", "ReadOnly", "Consistency", "BindOptions"})
BIND_OPTION_KEYS = frozenset({"Propagation", "NonRecursive", "CreateMountpoint"})
# VolumeOptions and TmpfsOptions do NOT enter the schema: through
# VolumeOptions.DriverConfig.Options{type=none,o=bind,device=/} a volume becomes
# a bind to any path of the host — past the whitelist, past the expansion of symlinks.
MOUNT_TYPES = frozenset({"bind", "volume", "tmpfs"})

def render_create(body: bytes) -> tuple[bytes | None, str | None]:
    """(the body upstream, the reason for refusal). Assembles the JSON anew by the schema.

    What goes upstream is OUR object, and not the client's: fields that are not in the schema
    do not reach the daemon in principle. This is the same property as with the path — the daemon
    receives what we built, and cannot interpret it otherwise.
    """
    if len(body) > MAX_CREATE_BODY:
        return None, "create body too large"
    try:
        cfg = json.loads(body)
    except Exception:
        return None, "create body is not valid JSON"
    if not isinstance(cfg, dict):
        return None, "create body is not an object"

    extra = set(cfg) - CONFIG_KEYS
    if extra:
        return None, f"create: fields not in the schema: {sorted(extra)}"

    out = {k: v for k, v in cfg.items() if k not in ("HostConfig", "NetworkingConfig")}

    hc = cfg.get("HostConfig") or {}
    if not isinstance(hc, dict):
        return None, "HostConfig is not an object"
    extra = set(hc) - HOSTCONFIG_KEYS
    if extra:
        return None, f"HostConfig: fields not in the schema: {sorted(extra)}"

    # --- values that the schema lets through, but the meaning does not ---
# All host-namespaces are closed. NetworkMode=host was discussed separately: it
# gives away the network stack of the machine — the operator's localhost, their local network,
# ports, abstract unix sockets. For an export product this is "finding oneself
    # on the machine of the one who launched us", and not "go out into the internet".
    #
    # PidMode=host is the most dangerous of all: userns-remap on the daemon is off, so root in
    # the container is uid 0 of the host, and through /proc/<pid>/environ and
    # /proc/<pid>/root one reads the environment and the FILE SYSTEM of any container.
    # That is, a direct extraction of foreign keys past the filter and past the labels.
    for field in NAMESPACE_FIELDS:
        val = hc.get(field)
        if isinstance(val, str) and (val == "host" or val.startswith("host")):
            return None, f"HostConfig.{field}=host is not allowed"

    # Networks are NOT checked here, and this is not an omission. The name of a network cannot be
    # learned from the string: the daemon accepts both a name and an id and an id prefix,
    # while DENIED_NETWORKS are names. Comparing the string with the list of names was exactly
    # the hole (see inspect_network). The decision about the network is made by handle(), where there is a daemon.

    binds = hc.get("Binds")
    if binds:
        if not isinstance(binds, list):
            return None, "HostConfig.Binds has unexpected shape"
        for b in binds:
            if not isinstance(b, str):
                return None, "HostConfig.Binds entry is not a string"
            parts = b.split(":")
            if len(parts) < 2:
                return None, "HostConfig.Binds entry malformed"
            reason = check_bind_source(parts[0])
            if reason:
                return None, reason

    mounts = hc.get("Mounts")
    if mounts:
        if not isinstance(mounts, list):
            return None, "HostConfig.Mounts has unexpected shape"
        for m in mounts:
            if not isinstance(m, dict):
                return None, "Mounts[] entry is not an object"
            extra = set(m) - MOUNT_KEYS
            if extra:
                return None, f"Mounts[]: fields not in the schema: {sorted(extra)}"
            mtype = m.get("Type")
            if mtype not in MOUNT_TYPES:
                return None, f"Mounts[].Type is not allowed: {mtype!r}"
            if mtype == "bind":
                reason = check_bind_source(m.get("Source", ""))
                if reason:
                    return None, "Mounts[] " + reason
            bo = m.get("BindOptions")
            if bo:
                if not isinstance(bo, dict):
                    return None, "Mounts[].BindOptions has unexpected shape"
                extra = set(bo) - BIND_OPTION_KEYS
                if extra:
                    return None, f"Mounts[].BindOptions: fields not in the schema: {sorted(extra)}"

    sysctls = hc.get("Sysctls")
    if sysctls:
        if not isinstance(sysctls, dict):
            return None, "HostConfig.Sysctls has unexpected shape"
        extra_s = set(sysctls.items()) - {("net.ipv4.ip_forward", "0")}
        if extra_s:
            return None, f"HostConfig.Sysctls is not allowed: {sorted(extra_s)}"

    caps = hc.get("CapAdd")
    if caps:
        if not isinstance(caps, list) or not all(isinstance(c, str) for c in caps):
            return None, "HostConfig.CapAdd has unexpected shape"
        extra_c = {c.upper().removeprefix("CAP_") for c in caps} - ALLOWED_CAPS
        if extra_c:
            return None, f"HostConfig.CapAdd is not allowed: {sorted(extra_c)}"

    devices = hc.get("Devices")
    if devices:
        if not isinstance(devices, list):
            return None, "HostConfig.Devices has unexpected shape"
        for d in devices:
            if not isinstance(d, dict):
                return None, "HostConfig.Devices entry has unexpected shape"
            src = _norm(d.get("PathOnHost", ""))
            if src is None or src not in ALLOWED_DEVICES:
                return None, f"HostConfig.Devices is not allowed: {d.get('PathOnHost')}"
            if _norm(d.get("PathInContainer", "")) != src:
                return None, f"HostConfig.Devices path remap is not allowed: {d.get('PathInContainer')}"

    nc = cfg.get("NetworkingConfig") or {}
    if not isinstance(nc, dict):
        return None, "NetworkingConfig is not an object"
    extra = set(nc) - {"EndpointsConfig"}
    if extra:
        return None, f"NetworkingConfig: fields not in the schema: {sorted(extra)}"
    # The networks themselves — in handle(): the keys of EndpointsConfig are also sometimes ids, and not names.

    if hc:
        out["HostConfig"] = hc
    if nc:
        out["NetworkingConfig"] = nc
    return json.dumps(out).encode(), None

def inspect_volume(body: bytes) -> str | None:
    """The reason for refusal for POST /volumes/create, or None.

    A named volume is safe in itself and therefore is let through into the create
    of a container without talk. But the local driver has DriverOpts, and the combination

        {"type": "none", "o": "bind", "device": "/etc"}

    makes an ordinary bind to any path of the host out of a "volume". Then it is mounted
    as Mounts[].Type=volume — that is, past the whitelist, past the expansion of symlinks,
    past everything that is built around Binds. The body of this route was not looked at
    at all, and the hole was exactly here.

    Therefore: the driver only local (or empty), DriverOpts — empty. We do not
    enumerate the dangerous keys: o/device/type are only those known today, while any
    driver option may turn out to be a way outward.
    """
    if len(body) > MAX_CREATE_BODY:
        return "volume create body too large"
    try:
        cfg = json.loads(body or b"{}")
    except Exception:
        return "volume create body is not valid JSON"
    if not isinstance(cfg, dict):
        return "volume create body is not an object"

    driver = cfg.get("Driver")
    if driver not in (None, "", "local"):
        return f"volume driver is not allowed: {driver!r}"

    opts = cfg.get("DriverOpts")
    if opts:
        if not isinstance(opts, dict):
            return "volume DriverOpts has unexpected shape"
        return f"volume DriverOpts is not allowed: {sorted(opts)}"
    return None


def inspect_netattach(body: bytes) -> tuple[str | None, str | None]:
    """(the reason for refusal, the reference to the container) for networks/<id>/connect|disconnect.

    The reference lies in the BODY, and not in the path, so it cannot be checked otherwise:
    disconnecting egress from the hand's network means removing the masking of keys.
    """
    try:
        cfg = json.loads(body or b"{}")
    except Exception:
        return "network attach body is not valid JSON", None
    if not isinstance(cfg, dict):
        return "network attach body is not an object", None
    ref = cfg.get("Container")
    if not isinstance(ref, str) or not ref:
        return "network attach without Container reference", None
    return None, ref


def _fwd_headers(request: web.Request) -> dict:
# Host/Content-Length/Transfer-Encoding will be set anew by our client —
# this is what closes the discrepancies of framing (the second family of smuggling).
    skip = {"host", "content-length", "transfer-encoding", "connection"}
    return {k: v for k, v in request.headers.items() if k.lower() not in skip}


def _resp_headers(up) -> dict:
    skip = {"content-length", "transfer-encoding", "connection"}
    return {k: v for k, v in up.headers.items() if k.lower() not in skip}


async def handle(request: web.Request) -> web.StreamResponse:
    timeout = ClientTimeout(total=3600)  # long builds

    # 1. RENDER. Everything that did not parse unambiguously — a 403 right here.
    try:
        version, segs = render_path(request.rel_url.raw_path)
        policy, ref, ref_at = match_route(request.method, segs)
    except Deny as exc:
        return _deny(str(exc))

    qs = render_query(request.rel_url.query, policy["q"])
    body_kind = policy.get("body")
    # The address upstream is NOT assembled here. It used to be assembled, lived as a variable for a hundred
    # lines through all the checks — and was overwritten by a variable of the same name inside the
    # parsing of container:<ref>: upstream went POST /containers/<target>/json with a create
    # body, and a legitimate sidecar got a 404. Now the string appears at the moment of
    # sending, from the parts that by then are already checked; there is nothing to overwrite,
    # because there is nothing to store.

    # 2. The body. We read it in full only where it is small and needed for the decision.
    body: bytes | None = None
    if body_kind == "none":
        # A body on a route where it should not be is either a client error or
        # an attempt to pass upward what we do not parse. Both are a 403.
        cl = request.content_length
        te = request.headers.get("Transfer-Encoding", "").lower()
        if (cl is not None and cl > 0) or "chunked" in te:
            return _deny(f"body is not allowed on /{'/'.join(segs)}")
    if body_kind in ("create", "volume", "netattach"):
        body = await request.read()
        if len(body) > MAX_CREATE_BODY:
            return _deny(f"{body_kind} body too large")

    # 3. The policy of protected containers. The reference is taken from the path, and for
    # networks/<id>/connect|disconnect — from the body: that is where it lives.
    action = policy["protected"]
    if body_kind == "netattach":
        reason, ref = inspect_netattach(body)
        if reason:
            return _deny(reason)
        # Disconnecting egress from the hand's network = removing the masking of keys.
        action = "deny"
        # Rehooking a container into a forbidden network after the fact is the same bypass
        # as creating it there at once, therefore the check is ONE and the same.
        if segs[-1] == "connect":
            try:
                async with _session(timeout) as sess:
                    reason = await check_network(sess, segs[1])
            except Exception as exc:
                return _deny(f"network check failed: {exc}")
            if reason:
                return _deny(reason)

    protected = False
    if ref is not None and action != "ok":
        # One trip to the daemon per request: from there comes both the label (whether to refuse, whether to
        # cut Config.Env) and the immutable Id.
        try:
            async with _session(timeout) as sess:
                cid, protected = await inspect_container(sess, ref)
        except Exception as exc:
            return _deny(f"protection check failed: {exc}")
        if protected and action == "deny":
            return _deny(f"/{'/'.join(segs)} on protected container {ref} is not allowed")
        # Upstream will go the Id, and not the name we were asked by. A container name
        # is renamed, and `rename` in the table is open: between our check
        # and the execution at the daemon another container manages to take it. The Id is not
        # renamed, therefore the checked object and the executed one are one and
        # the same by construction, and not because nobody managed in time.
        if cid:
            if body_kind == "netattach":
                # In connect/disconnect the reference lives in the BODY, and not in the path.
                cfg = json.loads(body)
                cfg["Container"] = cid
                body = json.dumps(cfg).encode()
            elif ref_at is not None and segs[0] == "containers":
                # Only containers: networks and volumes are not renamed, while for
                # images the substitution of an Id would change the meaning (deleting a tag is not
                # the same as deleting an image).
                segs = segs[:ref_at] + [cid] + segs[ref_at + 1:]

    if body_kind == "volume":
        reason = inspect_volume(body)
        if reason is not None:
            return _deny(reason)

    if body_kind == "create":
        # Upstream will go the REASSEMBLED body, and not the client's: fields outside the schema
        # do not reach the daemon. The same property as with the path and the query.
        rendered, reason = render_create(body)
        if reason is not None:
            return _deny(reason)
        body = rendered
        # container:<ref> — "to climb into the namespace of that container over there". Not only
        # NetworkMode can do that: PidMode, IpcMode, UsernsMode, CgroupnsMode and
        # UTSMode accept exactly the same syntax. Therefore the parsing here is ONE
        # for all the fields from NAMESPACE_FIELDS, and not written for the network mode.
        #
        # We do not cut indiscriminately: climbing into the namespace of one's OWN container is legitimate
        # debugging (a sidecar, capture traffic, look at processes). Only a FOREIGN
        # service target is dangerous, and this is decided by the target itself — by the label and by
        # its networks. For NetworkMode the price of the miss is "finding oneself in sweet_world, that
        # is, in the internet past egress", for PidMode — "reading /proc/1/root
        # of the target as root", and we closed the first, but not the second.
        hc_raw = (json.loads(body).get("HostConfig") or {})
        targets = {}
        for field in NAMESPACE_FIELDS:
            val = hc_raw.get(field)
            if isinstance(val, str) and val.startswith("container:"):
                target = val.split(":", 1)[1]
                if not target:
                    return _deny(f"HostConfig.{field}=container: without reference")
                targets.setdefault(target, []).append(field)
        for target, fields in targets.items():
            try:
                async with _session(timeout) as sess:
                    target_url = (UPSTREAM + "/v" + DEFAULT_API_VERSION
                                  + "/containers/" + quote(target, safe="") + "/json")
                    async with sess.get(target_url) as up:
                        if up.status != 200:
                            return _deny(
                                f"{fields[0]}=container:{target} — target not found")
                        info = json.loads(await up.read())
                    _, prot = await inspect_container(sess, target)
            except Exception as exc:
                return _deny(f"container namespace check failed: {exc}")
            nets = set((info.get("NetworkSettings") or {}).get("Networks") or {})
            bad = nets & DENIED_NETWORKS
            if prot or bad:
                why = "protected" if prot else f"stands in a forbidden network {sorted(bad)}"
                return _deny(
                    f"{'/'.join(fields)}=container:{target} — target {why}")

        # The networks the container asks into: both NetworkMode and the keys of EndpointsConfig —
        # are asked of the daemon by name. Here exactly, and not in render_create:
        # there is only a string there, and a string says nothing about a network. The reference
        # may be a name, an id or an id prefix — all three lead into one network, and
        # one must decide by it, and not by the spelling.
        try:
            cfg = json.loads(body)
            wanted = set((cfg.get("NetworkingConfig") or {}).get("EndpointsConfig") or {})
            nm = (cfg.get("HostConfig") or {}).get("NetworkMode")
            # container:<ref> is not a network, but a neighbour's namespace; it was parsed by the
            # gate above. Asking /networks about such a string is pointless:
            # the daemon will answer 404, and a legitimate sidecar would get a refusal.
            if (isinstance(nm, str) and not nm.startswith("container:")
                    and nm not in ("", "default", "none", "bridge", "host")):
                wanted.add(nm)
            if wanted:
                async with _session(timeout) as sess:
                    for net in sorted(wanted):
                        reason = await check_network(sess, net)
                        if reason:
                            return _deny(reason)
        except web.HTTPException:
            raise
        except Exception as exc:
            return _deny(f"network check failed: {exc}")

    # 4. The inspect answer of a protected one — without Config.Env. There is no reason to refuse entirely:
    # it is useful for the hand to see the networks and the state of the stack.
    if action == "env" and protected:
        try:
            async with _session(timeout) as sess:
                async with sess.get(build_url(version, segs, qs),
                                    headers=_fwd_headers(request)) as up:
                    raw = await up.read()
                if up.status != 200:
                    return web.Response(status=up.status, body=raw)
                try:
                    data = json.loads(raw)
                except Exception:
                    # We did not parse it — we do not give it out: the environment could be there.
                    return _deny("inspect response is not valid JSON")
                if not isinstance(data, dict):
                    return _deny("inspect response is not an object")
                return web.json_response(_strip_env(data))
        except Exception as exc:
            return _deny(f"upstream error on inspect: {exc}")

    # 5. Forwarding. Upstream goes the address ASSEMBLED BY US from the checked parts,
    # and not the client's string — and it is assembled here, at the place of sending.
    if body is not None:
        try:
            async with _session(timeout) as sess:
                async with sess.request(
                    request.method, build_url(version, segs, qs), data=body, headers=_fwd_headers(request),
                    allow_redirects=False,
                ) as up:
                    raw = await up.read()
                    return web.Response(status=up.status, body=raw, headers=_resp_headers(up))
        except Exception as exc:
            return web.json_response(
                {"message": f"docker-filter upstream error: {exc}"}, status=502
            )

    # The body was not parsed (build-context, tar for archive, logs): we stream.
    # IMPORTANT: we pass data through ONLY if there really is a body. Otherwise aiohttp on
    # data=request.content would hang Transfer-Encoding: chunked even on an empty
    # body, while the Docker API rejects a non-empty body on bodyless requests (start/stop/
    # kill/pause/wait — "non-empty request body was removed in v1.24").
    cl = request.content_length
    te = request.headers.get("Transfer-Encoding", "").lower()
    has_body = (cl is not None and cl > 0) or ("chunked" in te)
    data = request.content if has_body else None
    try:
        async with _session(timeout) as sess:
            async with sess.request(
                request.method, build_url(version, segs, qs), data=data, headers=_fwd_headers(request),
                allow_redirects=False,
            ) as up:
                resp = web.StreamResponse(status=up.status, headers=_resp_headers(up))
                await resp.prepare(request)
                async for chunk in up.content.iter_any():
                    await resp.write(chunk)
                await resp.write_eof()
                return resp
    except Exception as exc:
        return web.json_response(
            {"message": f"docker-filter upstream error: {exc}"}, status=502
        )


def make_app() -> web.Application:
    # There is no global limit: it would press on the build-context. The limit is applied
    # pointwise to the bodies that we parse (MAX_CREATE_BODY).
    app = web.Application(client_max_size=0)
    app.router.add_route("*", "/{tail:.*}", handle)
    return app


if __name__ == "__main__":
    # The port from env: tecnativa now lives in OUR network namespace and occupies
    # 2375 on loopback, therefore the filter listens on the neighbouring port.
    port = int(os.environ.get("LISTEN_PORT", "2375"))
    web.run_app(make_app(), host="0.0.0.0", port=port, access_log=None)
