#!/usr/bin/env python3
"""Self-check of docker-filter. It catches what ast.parse and the import do not catch.

The reason it appeared: ALLOWED_CAPS/ALLOWED_DEVICES/PRIV_NETWORKS once went into
a commit UNDEFINED. The syntax is valid, the import with an empty environment passes,
and it blows up on the first request with CapAdd or with a set list of networks. Therefore
there are two mandatory conditions here: an import with a FILLED environment and a run of
render_create over REAL bodies, and not over invented ones.
"""
import importlib.util, json, os, subprocess, sys, types

def load(path, env):
    for k, v in env.items():
        os.environ[k] = v
    sys.modules['aiohttp'] = types.SimpleNamespace(
        web=types.SimpleNamespace(Request=object, StreamResponse=object, Response=object,
                                  Application=object, HTTPException=Exception,
                                  json_response=lambda *a, **k: None),
        ClientSession=object, ClientTimeout=object, UnixConnector=object)
    spec = importlib.util.spec_from_file_location("f", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

def live_bodies():
    """Create bodies recovered from live containers."""
    names = subprocess.run(["docker", "ps", "-a", "--format", "{{.Names}}"],
                           capture_output=True, text=True).stdout.split()
    for n in names:
        r = subprocess.run(["docker", "inspect", n, "--format", "{{json .}}"],
                           capture_output=True, text=True, timeout=30)
        if r.returncode:
            continue
        d = json.loads(r.stdout)
        cfg = {k: v for k, v in (d.get("Config") or {}).items() if v not in (None, "", [], {}, False)}
        hc = {k: v for k, v in (d.get("HostConfig") or {}).items() if v not in (None, "", [], {}, 0, False)}
        cfg["HostConfig"] = hc
        yield n, cfg

# *=container:<ref> is NOT checked here: the indiscriminate prohibition was removed deliberately (climbing
# into the namespace of one's own container is legitimate debugging), while the decision about the target is made by
# handle(), where there is access to the daemon. There is no live daemon here, therefore we autonomously
# watch over what is autonomously checkable — see the invariant in main(): every field of
# HostConfig that chooses a namespace must stand in NAMESPACE_FIELDS, otherwise both
# gates (host and container:) will not learn about it. That is exactly how
# PidMode=container: was missed — the field is in the schema, in the private check not a word about it.
ATTACKS = [
    ("VolumeOptions → a bind of the host", {"Image": "a", "HostConfig": {"Mounts": [
        {"Type": "volume", "Source": "p", "Target": "/h",
         "VolumeOptions": {"DriverConfig": {"Name": "local", "Options": {"o": "bind", "device": "/"}}}}]}}),
    ("Mounts Type=image", {"Image": "a", "HostConfig": {"Mounts": [{"Type": "image", "Source": "x", "Target": "/t"}]}}),
    ("Privileged", {"Image": "a", "HostConfig": {"Privileged": True}}),
    ("SecurityOpt", {"Image": "a", "HostConfig": {"SecurityOpt": ["seccomp=unconfined"]}}),
    ("VolumesFrom", {"Image": "a", "HostConfig": {"VolumesFrom": ["x"]}}),
    ("an unknown field", {"Image": "a", "BrandNew": 1}),
]

def main(path, env):
    m = load(path, env)           # 1. an import with a filled environment

    # An invariant of the schema: a HostConfig field with a name ending in "Mode" chooses a namespace,
    # and therefore must be in NAMESPACE_FIELDS — otherwise "host" and "container:"
    # will pass through. It is checked before the attacks: if the list has diverged from the schema,
    # the remaining probes will prove nothing anyway.
    modes = {k for k in m.HOSTCONFIG_KEYS if k.endswith("Mode")}
    lost = modes - set(m.NAMESPACE_FIELDS)
    if lost:
        print(f"  FAILURE: namespace fields outside NAMESPACE_FIELDS: {sorted(lost)}")
        return 1

    # PidMode stands in this list not for symmetry: with userns-remap turned off
    # it gives /proc/<pid>/environ and /proc/<pid>/root of any container, that is,
    # a direct extraction of foreign keys past the filter and past the labels.
    attacks = ATTACKS + [(f"{f}=host", {"Image": "a", "HostConfig": {f: "host"}})
                         for f in m.NAMESPACE_FIELDS]
    bad = 0
    for label, body in attacks:   # 2. the attacks must be rejected
        _, reason = m.render_create(json.dumps(body).encode())
        if reason is None:
            print(f"  HOLE: {label} passed"); bad += 1
    seen = 0
    for name, body in live_bodies():   # 3. live bodies must pass
        seen += 1
        try:
            _, reason = m.render_create(json.dumps(body).encode())
        except Exception as exc:
            print(f"  FALL on {name}: {type(exc).__name__}: {exc}"); bad += 1; continue
        # Refusals that are NOT an error of the schema:
        #   * bind source — a container of a foreign stack has its own whitelist;
        #   * denied/network — the service containers (brain, filter, egress) themselves
        #     stand in forbidden networks, but they are created by compose from the host, and not by
        #     the hand through the filter. To require their bodies to pass is pointless.
        ignorable = ("bind source", "is denied", "forbidden network")
        if reason and not any(x in reason for x in ignorable):
            print(f"  REFUSAL on a live {name}: {reason}"); bad += 1
    if not seen:
        # A silent success is worse than a failure: formerly, with docker unavailable, the test
        # reported "there are no errors", having checked only the attacks and not a single live body.
        print("  FAILURE: not a single live body obtained — is docker unavailable?")
        bad += 1
    else:
        print(f"  live bodies checked: {seen}")
    print("  there are no errors" if not bad else f"  PROBLEMS: {bad}")
    return bad

if __name__ == "__main__":
    env = dict(x.split("=", 1) for x in sys.argv[2:])
    sys.exit(1 if main(sys.argv[1], env) else 0)
