"""The embedding calculator. A separate OS process, like the hand.

The same frame as everywhere in the project: 4 bytes of length + JSON, stdin/stdout.
Logs — to stderr, otherwise they will spoil the channel.

BERT lives here, and not in the BEAM, for the same reason for which the python of the hand
lives here: an NIF with torch inside the VM would mean that a segfault or an OOM in the
model lays down the whole agent. A port is a separate process, its death will be survived by
the supervisor.

    input:  {"op": "embed", "texts": [...]}
    output: {"kind": "result", "vectors": [[...], ...], "dim": 384}

`kind` is mandatory: the listener in brain is one for the hands and the embedder and distinguishes an
answer from an uninvited event by this field, and not by a residual sign.
It discards a frame without a kind — the answer will not arrive, the request will hang until the timeout.

`rid` — the request number set by brain. There may be several waiting at a connection,
and the answer returns its number so that it is given to the one who
waits for it. We return it untouched: inventing numbers is not our business.
"""

import json
import os
import socket
import struct
import sys

MODEL = os.environ.get("SWEET_EMBED_MODEL", "intfloat/multilingual-e5-small")
MAX_LEN = int(os.environ.get("SWEET_EMBED_MAX_LEN", "512"))
# e5 requires prefixes, otherwise the quality drops noticeably. bge-m3 does not have them.
PREFIXED = "e5" in MODEL.lower()


def log(message):
    print(message, file=sys.stderr, flush=True)


class Channel:
    def __init__(self, read_exactly, write_all):
        self._read_exactly = read_exactly
        self._write_all = write_all

    def recv(self):
        header = self._read_exactly(4)
        if header is None:
            return None
        (length,) = struct.unpack(">I", header)
        return self._read_exactly(length)

    def send(self, payload):
        data = json.dumps(payload).encode("utf-8")
        self._write_all(struct.pack(">I", len(data)) + data)


def connect_channel():
    host = os.environ.get("SWEET_BRAIN_HOST", "sweet-brain")
    port = int(os.environ.get("SWEET_BRAIN_PORT", "4000"))
    conn = socket.create_connection((host, port), timeout=30)
    conn.settimeout(None)
    log(f"connected to brain at {host}:{port}")

    def read_exactly(n):
        buf = b""
        while len(buf) < n:
            chunk = conn.recv(n - len(buf))
            if not chunk:
                return None
            buf += chunk
        return buf

    channel = Channel(read_exactly, conn.sendall)
    channel.send({"op": "hello", "id": os.environ.get("SWEET_EMBED_ID", "embedder")})
    return channel


def main():
    import torch

    # Otherwise torch takes as many threads as there are cores and suffocates the schedulers of the BEAM —
    # the agent starts lagging on everything, including the answers to the person.
    torch.set_num_threads(int(os.environ.get("SWEET_EMBED_THREADS", "2")))

    from sentence_transformers import SentenceTransformer

    # We load the weights BEFORE the connection: then the very fact of the connection means that the
    # embedder is ready, and brain does not guess whether it has waited for the loading.
    model = SentenceTransformer(MODEL, device=os.environ.get("SWEET_EMBED_DEVICE", "cpu"))
    model.max_seq_length = min(model.max_seq_length, MAX_LEN)
    log(f"embedder ready: {MODEL}")

    channel = connect_channel()
    send = channel.send

    while True:
        frame = channel.recv()
        if frame is None:
            break

        try:
            message = json.loads(frame)
        except Exception as error:
            # The frame did not parse — there is no number in it either. brain will hand out such an
            # answer to all waiting ones: whose it is, there is no way to know.
            send({"kind": "result", "error": f"bad frame: {error}"})
            continue

        rid = message.get("rid")

        def answer(payload, rid=rid):
            send({**payload, "rid": rid} if rid is not None else payload)

        if message.get("op") != "embed":
            answer({"kind": "result", "error": f"unknown op: {message.get('op')}"})
            continue

        texts = message.get("texts", [])
        kind = message.get("kind", "passage")

        if PREFIXED:
            texts = [f"{kind}: {t}" for t in texts]

        # FROM WHICH END TO CUT if the text is longer than the window of the model (512 tokens).
        #
        # The side comes as a separate field, and is not derived from `kind`. Formerly it
        # was derived — and by this glued two independent things: WHAT we encode
        # (the e5 prefix, which has only two values) and WHAT we sacrifice on
        # overflow. A paragraph of memory is encoded with the passage prefix, but it must be cut
        # ON THE LEFT: it is embedded together with the window of the previous paragraphs, it
        # itself stands last, and when cut on the right it would fly out first — the vector
        # would be obtained from a foreign context without the paragraph itself.
        #
        # The default preserves the former behaviour: the query on the left, the stored one
        # on the right. In a description of a skill the meaning is at the beginning — the first phrase is the essence.
        #
        # We do this with the tokenizer, and not with our own cutting by characters: the boundary
        # runs along tokens, and not in the middle of a word, and there is no need to guess how many
        # characters of Russian text fit into 512 tokens.
        cut = message.get("cut") or ("left" if kind == "query" else "right")
        model.tokenizer.truncation_side = cut

        try:
            vectors = model.encode(
                texts,
                batch_size=int(message.get("batch", 16)),
                convert_to_numpy=True,
                show_progress_bar=False,
            )
            answer({"kind": "result",
                    "vectors": [v.tolist() for v in vectors],
                    "dim": int(vectors.shape[1])})
        except Exception as error:
            answer({"kind": "result", "error": str(error)})


if __name__ == "__main__":
    main()
