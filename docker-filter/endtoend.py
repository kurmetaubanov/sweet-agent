#!/usr/bin/env python3
"""A full run of the filter against a STUB daemon.

Why separately from selftest.py. That one checks render_create — a pure function, and
therefore it checks only "was it refused". Everything that handle() does remained
unchecked, and there I put a hole: inside the parsing of container:<ref> I started
a variable url, overwriting with it the forwarding address assembled a hundred lines above. Upstream
went POST /containers/<target>/json with a create body, and a legitimate sidecar got a 404.
The prohibitions at the same time answered correctly — the first gate fires BEFORE the spoiling of the address,
therefore the test for a prohibition noticed nothing.

Hence the rule: it is not enough to know that the forbidden was rejected. One must know that
the allowed went UPSTREAM and went EXACTLY THERE. The stub below answers like the daemon and
records what it received — and the request is compared with the record, and not with the response code.

The daemon is a stub, therefore the test creates nothing and does not touch the live docker.
"""
import asyncio, importlib.util, json, os, sys

from aiohttp import web, ClientSession

# The stub daemon: it answers like the real one and writes down what it received.
SEEN = []
PROTECTED = "sweet-brain"          # marked with the label
PLAIN = "sweet-hand-1"             # an ordinary container, it is also the target of container:
IDS = {PROTECTED: "ffff" * 16, PLAIN: "aaaa" * 16}
NETS = {"sweet_hands": "1111" * 8, "sweet_world": "2222" * 8}


async def stub(request):
    SEEN.append((request.method, str(request.rel_url)))
    p = request.path

    if p.startswith("/v1.43/containers/") and p.endswith("/json"):
        ref = p.split("/containers/")[1][: -len("/json")]
        name = next((n for n, i in IDS.items() if ref in (n, i)), None)
        if name is None:
            return web.json_response({"message": "no such container"}, status=404)
        labels = {"sweet.protected": "true"} if name == PROTECTED else {}
        return web.json_response({
            "Id": IDS[name], "Name": "/" + name,
            "Config": {"Labels": labels, "Env": ["SECRET=let_it_lie_here"]},
            "NetworkSettings": {"Networks": {"sweet_hands": {}}},
            "Mounts": [],
        })

    if p.startswith("/v1.43/networks/"):
        ref = p.split("/networks/")[1]
        name = next((n for n, i in NETS.items() if ref in (n, i)), None)
        if name is None:
            return web.json_response({"message": "no such network"}, status=404)
        return web.json_response({"Id": NETS[name], "Name": name, "Containers": {}})

    return web.json_response({"Id": "created"}, status=201)


def load(path, env):
    for k, v in env.items():
        os.environ[k] = v
    spec = importlib.util.spec_from_file_location("f", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def create_body(**hc):
    return {"Image": "alpine", "HostConfig": hc}


async def run(path, env):
    daemon = web.Application()
    daemon.router.add_route("*", "/{tail:.*}", stub)
    drunner = web.AppRunner(daemon)
    await drunner.setup()
    dsite = web.TCPSite(drunner, "127.0.0.1", 0)
    await dsite.start()
    dport = dsite._server.sockets[0].getsockname()[1]

    env = dict(env)
    env["UPSTREAM_URL"] = f"http://127.0.0.1:{dport}"
    env["DOCKER_SOCKET"] = "/nonexistent/docker.sock"   # so it will go over TCP
    m = load(path, env)

    frunner = web.AppRunner(m.make_app())
    await frunner.setup()
    fsite = web.TCPSite(frunner, "127.0.0.1", 0)
    await fsite.start()
    base = f"http://127.0.0.1:{fsite._server.sockets[0].getsockname()[1]}"

    # (name, method, path, body, expected code, expected path UPSTREAM or None)
    fwd = "/v1.43/containers/create"
    cases = [
        ("an ordinary create", "POST", "/v1.43/containers/create",
         create_body(), 201, fwd),
        ("the network is allowed", "POST", "/v1.43/containers/create",
         create_body(NetworkMode="sweet_hands"), 201, fwd),
        # exactly the case that was broken: the target is its own container
        ("container: its own", "POST", "/v1.43/containers/create",
         create_body(NetworkMode=f"container:{PLAIN}"), 201, fwd),
        ("PidMode: its own", "POST", "/v1.43/containers/create",
         create_body(PidMode=f"container:{PLAIN}"), 201, fwd),
        ("PidMode: protected", "POST", "/v1.43/containers/create",
         create_body(PidMode=f"container:{PROTECTED}"), 403, None),
        ("network by name", "POST", "/v1.43/containers/create",
         create_body(NetworkMode="sweet_world"), 403, None),
        ("network by id", "POST", "/v1.43/containers/create",
         create_body(NetworkMode=NETS["sweet_world"]), 403, None),
        ("PidMode=host", "POST", "/v1.43/containers/create",
         create_body(PidMode="host"), 403, None),
        ("exec", "POST", f"/v1.43/containers/{PLAIN}/exec", {}, 403, None),
        # the reference is expanded into an Id: what goes upstream is it, and not the name
        ("stop by name", "POST", f"/v1.43/containers/{PLAIN}/stop",
         None, 201, f"/v1.43/containers/{IDS[PLAIN]}/stop"),
        ("stop of a protected one", "POST", f"/v1.43/containers/{PROTECTED}/stop",
         None, 403, None),
    ]

    bad = 0
    async with ClientSession() as sess:
        for name, method, path_, body, want_code, want_fwd in cases:
            SEEN.clear()
            kw = {"json": body} if body is not None else {}
            async with sess.request(method, base + path_, **kw) as r:
                code = r.status
                text = await r.text()
            # Forwarding differs from the internal checks by the method: the filter
            # asks the daemon only with GETs, while a POST arrived here.
            got_fwd = [u for mth, u in SEEN if mth == method]
            if code != want_code:
                print(f"  FAILURE {name}: code {code}, expected {want_code} — {text[:120]}")
                bad += 1
                continue
            if want_fwd is None:
                if got_fwd:
                    print(f"  FAILURE {name}: it refused, but upstream went {got_fwd}")
                    bad += 1
            elif want_fwd not in got_fwd:
                print(f"  FAILURE {name}: upstream went {got_fwd}, expected {want_fwd}")
                bad += 1

    # inspect of a protected one: it is let through, but without Config.Env
    async with ClientSession() as sess:
        async with sess.get(base + f"/v1.43/containers/{PROTECTED}/json") as r:
            data = await r.json()
    # The key remains, the value is zeroed — the docker CLI reads such an answer, and
    # there are no secrets in it. We check exactly the VALUE.
    if (data.get("Config") or {}).get("Env"):
        print("  FAILURE inspect of a protected one: Config.Env is not cut out")
        bad += 1

    await frunner.cleanup()
    await drunner.cleanup()
    print(f"  probes: {len(cases) + 1}")
    print("  there are no errors" if not bad else f"  PROBLEMS: {bad}")
    return bad


if __name__ == "__main__":
    env = dict(x.split("=", 1) for x in sys.argv[2:])
    sys.exit(1 if asyncio.run(run(sys.argv[1], env)) else 0)
