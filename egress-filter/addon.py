#!/usr/bin/env python3
"""Egress credential-injection filter for Prime Agent.

Topology:
    prime-agent → [this proxy :8080] → the internet

Why: Prime Agent has no approvals layer — the model executes generated python
with the rights of the process. So the real key must not be kept in the container of the agent: it
would read it from the environment and could send it anywhere. Here the agent gets a
MASK (a deliberately non-working string), while the real key lives only in this sidecar
and is substituted into the header on the way out.

Threat model: the agent is COMPROMISED. Hence:
- we let it go anywhere into the internet (this is a deliberate decision — the agent needs access
  to docs, packages, repositories), but the substitution of the key is done ONLY on
  the hosts from INJECT_HOSTS. This is not a formality: without binding to the host the agent
  would send the mask to its own address and would get the real key back — the proxy
  would itself have substituted it there;
- the anchor of the check is the address of the REAL connection (request.host), and not the header
  Host: it is under the control of the agent, and a connection to evil.com with 'Host:
  api.deepseek.com' would otherwise get the real key;
- the host is matched by the exact name (or a subdomain), and not by a substring, otherwise
  api.deepseek.com.evil.tld would pass the check;
- on top of that we narrow to https:443 and to the paths from INJECT_PATHS — in case
  of a server-side forward (an open redirect, an SSRF endpoint) on the allowed
  host itself, where the host check is powerless, because the host is real.

What this scheme does NOT catch: an ordinary 302 from an allowed host does not leak the key —
the redirect is returned to the client of the agent, and it will follow it with its own mask,
the real value lives only on the segment proxy→provider.

TLS: mitmproxy terminates the connection with its own CA, therefore the header is visible.
The CA certificate lies on the shared volume /certs, the agent mounts it :ro.
"""
import base64
import binascii
import logging
import os

from mitmproxy import http

# The secrets and the scope of each. The scope is its OWN for each key, and not a common one:
# otherwise the DeepSeek key would be substituted on serpbase.dev and vice versa. This would not
# have ended in an error (there are no such endpoints there), but the rule "a secret goes exactly where
# it is intended" is cheaper to keep than later to prove it is not violated.
# Fields: name, hosts, exact paths, path suffixes.
#
# Suffixes are needed for git: its path depends on the repository
# (/owner/repo.git/info/refs), it cannot be set by an exact list, and to allow everything on
# github.com is undesirable — then the token would go off on any redirect on the same host.
# api.github.com has many paths and they are also variable (/repos/<owner>/<repo>/...),
# therefore for it the list of exact paths is empty, and the suffix "/" allows everything:
# the protection here rests on the host, as before.
_SPEC = [
    ("DEEPSEEK", "api.deepseek.com", "/chat/completions,/v1/chat/completions,/models,/v1/models", ""),
    ("SERPBASE", "api.serpbase.dev", "/google/search", ""),
    ("GITHUB", "github.com,api.github.com", "", "/info/refs,/git-upload-pack,/git-receive-pack,/"),
]


def _split(value: str) -> set[str]:
    return {x.strip() for x in value.split(",") if x.strip()}


def _read_real(name: str) -> str:
    """The real key: first the secrets file, then env (compatibility).

    The file is the main path. The key must not be in the environment: the environment of a
    container is read through the docker API by several routes (inspect, top),
    and the hand has access to this API. The contents of /run/secrets cannot be obtained that way:
    `docker cp` on a protected container is forbidden by the filter, while export and commit
    do not include what is mounted.

    The env branch is kept so that an old .env/compose does not bring the proxy down silently.
    """
    path = os.environ.get(f"{name}_API_KEY_FILE", f"/run/secrets/{name.lower()}_api_key")
    try:
        with open(path, encoding="utf-8") as fh:
            value = fh.read().strip()
        if value:
            return value
    except FileNotFoundError:
        pass
    except OSError as exc:
        logging.warning("egress-filter: %s read failed (%s)", path, exc)
    value = os.environ.get(f"{name}_API_KEY_REAL", "").strip()
    if value:
        logging.warning(
            "egress-filter: %s taken from the environment, and not from %s — the environment "
            "of the container is visible through the docker API, move the key into secrets",
            name, path,
        )
    return value


def _load_rules() -> list[dict]:
    """The substitution rules: the key from secrets, the rest from env. A secret without a
    real value is skipped —
    that way an unconfigured SerpBase simply switches the search off, and does not bring down the proxy."""
    rules = []
    for name, hosts_default, paths_default, suffixes_default in _SPEC:
        real = _read_real(name)
        mask = os.environ.get(f"{name}_API_KEY_MASK", "").strip()
        if not real or not mask:
            continue
        # Fail-fast: a mask coinciding with the key means that the real key
        # has gone off into the container of the agent and there is no masking at all.
        if mask == real:
            raise ValueError(f"{name}_API_KEY_MASK coincides with the real key — there is no masking")
        rules.append({
            "name": name,
            "mask": mask,
            "real": real,
            "hosts": {h.lower() for h in _split(os.environ.get(f"{name}_INJECT_HOSTS", hosts_default))},
            "paths": _split(os.environ.get(f"{name}_INJECT_PATHS", paths_default)),
            "suffixes": _split(os.environ.get(f"{name}_INJECT_PATH_SUFFIXES", suffixes_default)),
        })
    return rules


RULES = _load_rules()

for _r in RULES:
    logging.info(
        "egress-filter: %s → hosts %s, paths %s, suffixes %s",
        _r["name"], sorted(_r["hosts"]), sorted(_r["paths"]), sorted(_r["suffixes"]),
    )
if not RULES:
    logging.warning("egress-filter: not a single secret is configured, there will be no substitution")


def _host_matches(host: str, hosts: set[str]) -> bool:
    """True if host is exactly an allowed host or its subdomain.

    Exact comparison plus a check for a suffix with a dot. One must not compare by substring:
    one must not: 'api.deepseek.com' occurs also in 'api.deepseek.com.evil.tld'.
    """
    return any(host == h or host.endswith("." + h) for h in hosts)


def _path_matches(path: str, rule: dict) -> bool:
    """True if the path is allowed for substitution: an exact match or a suffix.

    We drop the query string: '/chat/completions?x=1' is the same endpoint.
    """
    path = path.split("?", 1)[0].rstrip("/")
    if any(path == p.rstrip("/") for p in rule["paths"]):
        return True
    for suffix in rule["suffixes"]:
        # "/" as a suffix means "any path on this host".
        if suffix == "/" or path.endswith(suffix.rstrip("/")):
            return True
    return False


def _swap_in_basic(value: str, mask: str, real: str) -> str | None:
    """Substitute the mask inside Authorization: Basic base64(user:token).

    That is how git authenticates over HTTPS: the token hides in base64 together with the name
    of the user, and an ordinary replace over the header does not find it. We decode,
    change, encode back. We return None if this is not Basic, the string does not
    decode, or there is no mask inside — then the header stays as it was.
    """
    scheme, _, payload = value.partition(" ")
    if scheme.lower() != "basic" or not payload:
        return None
    try:
        decoded = base64.b64decode(payload, validate=True).decode("utf-8")
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return None
    if mask not in decoded:
        return None
    return "Basic " + base64.b64encode(decoded.replace(mask, real).encode()).decode()


def request(flow: http.HTTPFlow) -> None:
    # IMPORTANT: request.host, and NOT pretty_host. pretty_host prefers the header
    # Host, which is entirely under the control of the agent: a connection to evil.com with
    # 'Host: api.deepseek.com' would pass the check and get the real key.
    # request.host is the address to which mitmproxy really establishes
    # the connection (DNS is resolved here, in the egress container).
    host = flow.request.host.lower()

    # We choose the rule by the host of the REAL connection. If not one fitted —
    # we let the request through as is, the mask will go off as a mask.
    rule = next((r for r in RULES if _host_matches(host, r["hosts"])), None)
    if rule is None:
        return

    # A Host header not coinciding with the address of the connection is itself a sign
    # of an attempted bypass. A legitimate client does not send such a thing.
    host_header = (flow.request.host_header or "").lower().split(":", 1)[0]
    if host_header and host_header != host:
        logging.warning("egress-filter: Host '%s' != connection address '%s', no substitution", host_header, host)
        return

    # Only TLS and the standard port: over http the key would go off in plain text.
    if flow.request.scheme != "https" or flow.request.port != 443:
        logging.warning("egress-filter: %s://%s:%d — substitution only over https:443", flow.request.scheme, host, flow.request.port)
        return

    # A path outside the list will not see the key. This is protection against server-side
    # forwards on an allowed host (an open redirect/an SSRF endpoint), where
    # the host check is powerless: the host is real.
    if not _path_matches(flow.request.path, rule):
        logging.warning(
            "egress-filter: path %s is not in %s_INJECT_PATHS, no substitution",
            flow.request.path.split("?", 1)[0], rule["name"],
        )
        return

    # Substitution of the real key instead of the mask. We look only at the headers where
    # the key is supposed to be: Authorization for openai-compatible APIs and GitHub,
    # X-API-Key for SerpBase. We do not touch the body: there is no reason to write a secret there, and a blind
    # replace over the body would break an arbitrary payload.
    for header in ("Authorization", "X-Api-Key", "Api-Key"):
        value = flow.request.headers.get(header)
        if not value:
            continue
        if rule["mask"] in value:
            flow.request.headers[header] = value.replace(rule["mask"], rule["real"])
        else:
            swapped = _swap_in_basic(value, rule["mask"], rule["real"])
            if swapped:
                flow.request.headers[header] = swapped


def response(flow: http.HTTPFlow) -> None:
    # Insurance against a reverse leak: if the provider for some reason reflects the key in
    # the answer (an echo of a header, the text of an error), the agent must not see it.
    # We check ALL the secrets, and not only the one relating to the host: the leak of a foreign
    # key in a foreign answer is just as harmful.
    for rule in RULES:
        mask, real = rule["mask"], rule["real"]
        for header, value in list(flow.response.headers.items()):
            if real in value:
                flow.response.headers[header] = value.replace(real, mask)
        if flow.response.content and real.encode() in flow.response.content:
            flow.response.content = flow.response.content.replace(real.encode(), mask.encode())
