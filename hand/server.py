"""Hand: a Python kernel with persistent state behind a length-framed channel.

Frame: 4 bytes of length (big-endian) + JSON. Exactly what
`{packet: 4}` understands — both in `gen_tcp` and in `Port`.

The hand connects to brain ITSELF (SWEET_BRAIN_HOST/SWEET_BRAIN_PORT) and
introduces itself with a hello frame with SWEET_HAND_ID. It opens no ports — brain does not
guess whether the container has come up.

Logs go to stderr: stdout is occupied by nothing, but let the habit remain.

Why IPython InteractiveShell, and not ipykernel over ZeroMQ, as in prime-agent:
there the Jupyter protocol is needed because both ends are foreign. Here both ends are ours,
and the only ZMQ binding for Erlang is an NIF, that is, libzmq inside the BEAM.
InteractiveShell gives the same thing (state between calls, rich output,
magics), but without the network and without an extra process.
"""

import ctypes
import io
import json
import os
import re
import secrets
import signal
import socket
import subprocess
import struct
import sys
import threading
import time
import traceback
from contextlib import redirect_stdout, redirect_stderr

from IPython.core.interactiveshell import InteractiveShell

PORT = int(os.environ.get("SWEET_HAND_PORT", "5000"))
# A hard cap on a frame: the hand must not have the possibility to flood brain.
# Trimming the output is the concern of the one who reads it (`read_log` asks for exactly
# as much as it needs), here there is only protection of the transport.
MAX_FRAME = 64 * 1024 * 1024


# --- Background jobs: a shell handle that lives longer than a cell -----------
#
# A cell (op exec) is what the model WAITS for. A command of minutes does not fit
# into a cell by the design of the protocol: brain releases the wait only together with
# the answer. Therefore long work is started separately (op shell), it answers
# at once with a handle, and reports the end ITSELF with a frame kind=job. The frame goes to
# the session, and not to the waiting request — everything rests on this.
#
# A job runs in its OWN process group (start_new_session): otherwise a signal
# sent to the job would touch the kernel and brain would lose state, while a Ctrl-C on
# a cell would kill background work that has nothing to do with that cell.
#
# The three rules below — each a consequence of a concrete breakage:
#
#   * the return code is taken from the PROCESS (waitpid), and not from the pipes. A pipe is held
#     open by any background grandchild, and waiting for the pipe to close turns
#     `sleep 30 &` into a thirty-second cell;
#   * a non-zero exit does not turn into an exception. The model turns `set -e` on
#     itself, and the return code goes as a separate field — otherwise it simply has nothing
#     to branch `if rc != 0` on;
#   * the output goes to a file, and not to memory. The log is read in pieces (head, tail,
#     search by lines): "show the whole output" on hundreds of kilobytes eats a turn.

JOBDIR = os.environ.get("SWEET_JOB_DIR", "/tmp/sweet-jobs")

# How many bytes of output settle on disk. Beyond that the file does not grow, but the stream
# keeps being counted: "output 12 MB, tail shown" is a fact, while "the log
# has 200 KB" after trimming would be untrue.
LOG_CAP = 256 * 1024

# The tail that is kept in memory ALWAYS: even when the file on disk is trimmed,
# a trimmed log on disk holds the BEGINNING, and "the last lines" from it are
# the middle of the work.
TAIL_KEEP = 64 * 1024

# Limits of the answer to a log read request. Head and tail are asked in
# LINES (a line is the natural unit of a log, and it is the same for job events),
# while READ_CAP remains a byte ceiling on top: a single line is sometimes two hundred
# kilobytes — base64, minified json, a dump of an array.
READ_CAP = 16 * 1024
MATCH_LINE_CAP = 300
MATCH_COUNT_CAP = 100


# --- A job that does not count, but waits ---------------------------------
#
# A job that has stopped at a question ("Shall I install Hex? [Yn]"), from outside
# indistinguishable from a counting one: the same silence in the output, the same live process.
# One can tell one from the other only by the kernel — by WHAT the process
# stands on — and this can be looked at only here: brain has its own PID namespace,
# the /proc of the hand is inaccessible to it (checked live: from the hand the host processes are not
# visible, and vice versa). So the scan lives in the hand, while brain gets an event.
#
# We look at three things, and each cuts off its own kind of false positives:
#
#   * the process group of the job (pgid = pid of the job) — foreign processes are not ours;
#   * the state S — a counting process is in R, and it cannot be asking anything;
#   * where fd 0 points — at OUR pipe (the stdin of the job), and not at its own.
#
# The last is the main one. "Quiet and no newline" would catch `sleep 30`,
# `mkfifo` + `read < fifo` and `echo hi | (read x; sleep 30)` — none of these are
# questions, and they cannot be declared a question. By the descriptor, however, one sees exactly
# the one who is reading stdin FROM US.
#
# The BEAM is a separate line: it does not call read, but waits for readiness in epoll/select,
# and our pipe is visible in the fdinfo of the descriptor it stands on. A check of
# "only pipe_read" would have missed both `mix` and `iex` and `IO.gets` — that is,
# exactly the case for the sake of which all this is started.
JOB_TICK = 1.0

# How much silence is needed to look at the process at all. Less is
# ordinary work: `find | head` also has pauses.
WAITING_QUIET_S = 2.0

# How much silence counts as "the job has fallen silent". Minutes, and not seconds: a build and
# a snapshot of ten megabytes are legitimately silent, and to declare them hung would be
# lying. The value comes from brain (config/config.exs), because this is
# POLICY, and not the mechanics of the process.
QUIET_ALERT_S = float(os.environ.get("SWEET_JOB_QUIET_ALERT_S", "120"))

# How much head and tail travels into an event. An event is a REMINDER ("it is over",
# "it asks for input", "it has been silent for long"), while the log is read separately, through read_log.
#
# It is NOT the hand that trims to the shown size, but brain: the limit there is counted in
# lines and bytes at once, and the hand has no need to know about it. Here there is only a reserve,
# from which brain takes its piece — noticeably more than its limit and noticeably
# less than the full tail (64 KB), which in the session box would displace the conversation.
EVENT_HEAD = 8192
EVENT_TAIL = 8192


class Job:
    """A background command: its own process, its own group, its own log, its own return code."""

    def __init__(self, jid, code, cwd=None):
        self.id = jid
        self.code = code
        self.cwd = cwd or "/workspace"
        self.pid = None
        self.exit_code = None
        self.started_at = time.time()
        self.ended_at = None
        self.last_output_at = None
        self.lines = 0
        self.bytes_total = 0
        self.bytes_kept = 0
        self.truncated = False
        self.log_path = os.path.join(JOBDIR, f"{jid}.log")
        self._proc = None
        self._log = None
        self._tail = ""
        self._lock = threading.Lock()
        self._send = None
        # The number of the index of our stdin pipe. By it the watchdog learns whether the process
        # stands on our pipe: both halves of a pipe have one index.
        self.stdin_inode = None
        # The line with which the job asks for input, and the signs of the watchdog.
        # `waiting` — what is visible NOW (standing on our stdin), `ask` — with what
        # it asks (may be empty), `ask_sent` — what has already been said to
        # brain: the difference between them is the reason for an event.
        self.waiting = False
        self.ask = ""
        self.ask_sent = None
        self.stale_mark = None

    # --- internal ---

    def start(self, send):
        os.makedirs(JOBDIR, exist_ok=True)
        self._send = send
        self._log = open(self.log_path, "wb")
        self._proc = subprocess.Popen(
            ["bash", "-lc", self.code],
            cwd=self.cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        self.pid = self._proc.pid
        self.stdin_inode = os.fstat(self._proc.stdin.fileno()).st_ino
        threading.Thread(target=self._pump, daemon=True).start()
        threading.Thread(target=self._wait, args=(send,), daemon=True).start()

    def _pump(self):
        """Reads the stream of the job until it closes, and puts it into the log."""
        while True:
            chunk = self._proc.stdout.read1(65536)
            if not chunk:
                break

            with self._lock:
                self.bytes_total += len(chunk)
                self.lines += chunk.count(b"\n")
                self.last_output_at = time.time()

                if self.bytes_kept < LOG_CAP:
                    keep = chunk[: LOG_CAP - self.bytes_kept]
                    self._log.write(keep)
                    self._log.flush()
                    self.bytes_kept += len(keep)
                    if len(keep) < len(chunk):
                        self.truncated = True

                self._tail = (self._tail + chunk.decode("utf-8", "replace"))[-TAIL_KEEP:]

    def _wait(self, send):
        """Waits for the return code from the PROCESS and tells brain that the job is over."""
        code = self._proc.wait()

        with self._lock:
            self.exit_code = code
            self.ended_at = time.time()
            runtime = round(self.ended_at - self.started_at, 1)
            tail = self._tail

        send(
            {
                "kind": "job",
                "event": "finished",
                "job": self.id,
                "pid": self.pid,
                "exit": code,
                "runtime_s": runtime,
                "lines": self.lines,
                "bytes": self.bytes_total,
                "head": self.head(EVENT_HEAD),
                "tail": tail,
            }
        )

    # --- what the model sees from the kernel ---

    @property
    def running(self):
        return self._proc is not None and self._proc.poll() is None

    def poll(self):
        """State without waiting — the very thing the non-blocking loop stands on."""
        with self._lock:
            since = self.last_output_at or self.started_at
            return {
                "job": self.id,
                "code": self.code,
                "cwd": self.cwd,
                # The number of the process, if the job HAS one of its own. A cell of the kernel
                # has none: it counts in the process of the hand, and to give out the number of the
                # hand for it would be a lie — ten cells would show one number, and /proc by it
                # would point at the hand itself. An empty number here means "there is no
                # separate process", and not "the process is number zero".
                "pid": self.pid,
                "state": "running" if self.running else "exited",
                "exit": self.exit_code,
                "runtime_s": round((self.ended_at or time.time()) - self.started_at, 1),
                "quiet_s": round(time.time() - since, 1),
                "lines": self.lines,
                "bytes": self.bytes_total,
                "kept_bytes": self.bytes_kept,
                "truncated": self.truncated,
                # What the job asks with, if it asks. Empty — it does not ask.
                "ask": self.ask,
            }

    def output(self, n=None):
        """The whole log (what has settled on disk) or its last n characters."""
        with open(self.log_path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()

        return text if n is None else text[-n:]

    def head(self, n):
        with open(self.log_path, "r", encoding="utf-8", errors="replace") as f:
            return f.read(n)

    def tail(self, n):
        """The tail from memory: a trimmed log on disk holds the BEGINNING."""
        with self._lock:
            return self._tail[-n:]

    def head_lines(self, n, cap=None):
        """The first n lines of the log. The byte ceiling — on top of the line count."""
        out = []
        size = 0

        with open(self.log_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if len(out) >= n or (cap is not None and size >= cap):
                    break
                out.append(line)
                size += len(line)

        text = "".join(out)
        return text if cap is None else text[:cap]

    def tail_lines(self, n, cap=None):
        """The last n lines — from memory, for the same reason as tail()."""
        with self._lock:
            text = self._tail

        # The tail in memory begins in the middle of a line (64 KB were cut off by
        # bytes), but this does not affect the output: when there are more lines than asked for,
        # the stub remains outside the last n. It is discarded by the one who
        # cuts further by lines — brain (see Sweet.Session.last_lines/3).
        lines = text.splitlines(keepends=True)
        text = "".join(lines[-n:])
        return text if cap is None else text[-cap:]

    def send(self, text):
        """To answer a prompt inside a job: that is how interactivity comes alive."""
        if self._proc is None or self._proc.poll() is not None:
            raise RuntimeError(f"{self.id}: the job has already finished")

        self._proc.stdin.write(text.encode())
        self._proc.stdin.flush()

    def signal(self, sig):
        if self.pid and self.running:
            # To the group as a whole: a job has its own children (find | xargs, docker build),
            # and a signal to one shell would leave them counting further.
            os.killpg(self.pid, sig)

    def interrupt(self):
        self.signal(signal.SIGINT)

    def kill(self):
        self.signal(signal.SIGTERM)

    def wait(self, timeout=None):
        return self._proc.wait(timeout)

    def __repr__(self):
        state = self.poll()
        how = "running" if state["state"] == "running" else f"finished, code {state['exit']}"
        first = self.code.strip().splitlines()[0][:60] if self.code.strip() else ""
        return (
            f"<job {self.id}: {first} — {how}, {state['runtime_s']} s, "
            f"{state['lines']} lines>"
        )


# There is one kernel for all cells: they count one at a time, and not at once.
_kernel_lock = threading.Lock()


class CellJob(Job):
    """A kernel cell running in the background: from outside it is the same kind of job as a shell
    command. The difference is only in WHERE the code counts — in the kernel or in its own
    shell; in neither case does one have to wait for the result.

    Formerly a turn waited for a cell as a whole: `exec` answered at its end. Because of this
    a turn was divided into "while we count" and "between calls", and everything that arrived in
    the first half waited for the second.
    """

    def __init__(self, jid, code, shell, send):
        super().__init__(jid, code)
        self._shell = shell
        self._send = send
        self._alive = True
        self._thread = None

    def start(self, send=None):
        os.makedirs(JOBDIR, exist_ok=True)
        self._log = open(self.log_path, "wb")

        # A cell has NO process of its own: it counts in a thread of the hand, and the number
        # of the hand is the same for all cells. Formerly it was written into `self.pid`, and the
        # same number travelled to brain as "the pid of the job" — the model saw one process
        # under ten different cells. An empty number says honestly that there is none.
        #
        # The events carry it the same way: in the hand it is not a signal that is sent to a cell
        # (`CellJob.signal` interrupts the thread), and the number is not needed for the
        # control — the checkout of the thread lives on in `_thread.ident`.
        self.pid = None
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self):
        # A job started FROM a cell (bash()) must be able to send frames about itself;
        # the mark is local to the thread, and the thread now lives exactly one cell.
        _send_local.send = self._send
        _send_local.rc = None

        # The kernel is one, and `run_cell` in it does not tolerate a second call: formerly
        # this was ensured by itself — brain waited for the cell and did not send a second one.
        # Now cells go off as jobs, and the model has the right to start two in a row;
        # so a queue is needed here. It does not hold the turn: it is the job thread that waits,
        # and not the head.
        with _kernel_lock:
            frame = execute(self._shell, self.code, self._live)

        text = frame.get("stdout") or ""
        if frame.get("result"):
            text += ("\n" if text else "") + "=> " + frame["result"]
        if frame.get("error"):
            text += ("\n" if text else "") + frame["error"]

        self._absorb(text)

        # The return code: a cell with `%%bash` has its own, a real one, and it must be
        # taken. An ordinary Python cell has no return code — then it is
        # replaced by "fell over or not", otherwise the event about the end has nothing to say.
        rc = getattr(_send_local, "rc", None)

        with self._lock:
            self._alive = False
            self.exit_code = 1 if frame.get("error") else (0 if rc is None else rc)
            self.ended_at = time.time()
            runtime = round(self.ended_at - self.started_at, 1)
            tail = self._tail

        self._send(
            {
                "kind": "job",
                "event": "finished",
                "job": self.id,
                "pid": self.pid,
                "exit": self.exit_code,
                "runtime_s": runtime,
                "lines": self.lines,
                "bytes": self.bytes_total,
                "head": self.head(EVENT_HEAD),
                "tail": tail,
                "namespace": frame.get("namespace"),
            }
        )

    def _live(self, payload):
        """Live output of a cell. It has no request number: neither has a waiting one
        — the answer about the launch brain got at once, before the first line."""
        self._send(payload)

    def _absorb(self, text):
        """We put the output of a cell into a log of the same kind as a shell command has:
        then read_log, head, tail and output work over it without reservations."""
        chunk = text.encode("utf-8", "replace")

        with self._lock:
            self.bytes_total += len(chunk)
            self.lines += chunk.count(b"\n")
            self.last_output_at = time.time()

            keep = chunk[: max(LOG_CAP - self.bytes_kept, 0)]
            if keep:
                self._log.write(keep)
                self._log.flush()
                self.bytes_kept += len(keep)
            if len(keep) < len(chunk):
                self.truncated = True

            self._tail = (self._tail + chunk.decode("utf-8", "replace"))[-TAIL_KEEP:]

    # The kernel is not a process with its own group: the state and signals of a cell are its own.

    @property
    def running(self):
        return self._alive

    def send(self, text):
        raise RuntimeError(f"{self.id}: cell has no stdin")

    def signal(self, sig):
        if self._alive and self._thread is not None:
            interrupt(self._thread)

    def wait(self, timeout=None):
        if self._thread is not None:
            self._thread.join(timeout)
        return self.exit_code


# --- The watchdog: which of the jobs waits, and which is silent --------------


def proc_table():
    """What the kernel says about processes: which one has which pipe on stdin, and where it stands.

    One pass over /proc per tick, and not file by file on demand: a pass over a group
    costs fractions of a millisecond (measured: 1.1 ms for a full pass of 42 records), and
    there is no reason to read the same thing four times per tick.

    `wchan` is not readable for everyone: processes inside a container have their own, and on
    squeezed kernels it may be absent altogether. An empty string is not an error.
    """
    table = {}

    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue

        pid = int(entry)

        try:
            with open(f"/proc/{pid}/stat", "rb") as f:
                raw = f.read().decode("utf-8", "replace")

            # The name may contain anything, including parentheses and spaces,
            # therefore we cut not by spaces, but by the LAST parenthesis.
            after = raw.rpartition(")")[2].split()
            state, pgid = after[0], int(after[2])

            fd0 = os.readlink(f"/proc/{pid}/fd/0")
            inode = os.stat(f"/proc/{pid}/fd/0").st_ino

            try:
                with open(f"/proc/{pid}/wchan", "rb") as f:
                    wchan = f.read().decode("utf-8", "replace").strip()
            except OSError:
                wchan = ""
        except (OSError, ValueError, IndexError):
            # A process died between reads — an ordinary thing, and not a breakage.
            continue

        table[pid] = {"pid": pid, "state": state, "pgid": pgid, "fd0": fd0,
                      "inode": inode, "wchan": wchan}

    return table


def epoll_sees(info, inode):
    """Does the process hold OUR pipe in its waiting set.

    The BEAM does not call `read` on stdin: it waits for readiness in epoll and reads when
    the descriptor is ready. So it will never have `pipe_read`, and a check
    "by wchan only pipe_read" would have missed both `mix` and `iex` and `IO.gets` —
    exactly the case, about which further on.

    But in the `fdinfo` of an epoll descriptor all the descriptors of the set are listed
    (`tfd: N`), and among them our stdin is visible. This is an exact check, and not
    a guess: the set is what the process is waiting for right now.
    """
    for entry in os.listdir(f"/proc/{info['pid']}/fd"):
        try:
            target = os.readlink(f"/proc/{info['pid']}/fd/{entry}")
        except OSError:
            continue

        if "eventpoll" not in target:
            continue

        try:
            with open(f"/proc/{info['pid']}/fdinfo/{entry}") as f:
                lines = f.readlines()
        except OSError:
            continue

        for line in lines:
            if not line.startswith("tfd:"):
                continue

            number = line.split()[1]
            try:
                if os.stat(f"/proc/{info['pid']}/fd/{number}").st_ino == inode:
                    return True
            except OSError:
                continue

    return False


def group_reads_stdin(pgid, inode, table):
    """Does the process group of a job stand on reading OUR pipe.

    Three conditions, and each cuts off its own kind of false positives:

      * the process group is its own (`pgid` of the job; a job has its own session,
        `start_new_session`), foreign processes are not ours;
      * the state `S` — a counting process is in `R`, and it cannot be asking any
        thing;
      * `fd 0` points at OUR pipe. This is the main one: "quiet and no newline"
        would catch `sleep 30`, `mkfifo` + `read < fifo` and
        `echo hi | (read x; sleep 30)`, while by the descriptor one sees exactly the one
        who reads stdin FROM US. Its own pipeline and fifo are cut off by themselves.

    A process may stand in different ways, and this is all waiting:

      * `pipe_read` — an ordinary `read`;
      * epoll/select with our descriptor in the set (see `epoll_sees/2`);
      * `wchan` is empty — that is how a process inside a container looks, where the names
        of the kernel are not readable. To require a name would mean to miss everything that
        is executed in the hand.
    """
    for pid, info in table.items():
        if info["pgid"] != pgid or info["inode"] != inode:
            continue

        if info["state"] not in ("S", "D"):
            continue

        wchan = info["wchan"]

        if "pipe_read" in wchan or wchan == "":
            return True

        if "select" in wchan or "ep_poll" in wchan:
            if epoll_sees(info, inode):
                return True

    return False


def prompt_line(tail):
    """The line with which the job asks: the last non-empty one.

    From the log, and not from the pipe, and this is no trifle. Different programs send a prompt to
    different places: `read -p` — to stderr, mix — to stdout, python
    `input("...")` — to stdout, and sometimes it is absent altogether. In the log they are all
    already merged together, because the stderr of a job goes into the same stream.

    Reading the pipe of a job directly was tried — and abandoned. One can take the
    prompt out of it, but this cannot confirm the fact of waiting: opening
    a descriptor and reading nothing is not proof, and writing a "trial newline"
    into it means ANSWERING FOR THE MODEL. An empty
    line is a legitimate answer: `[Yn]` accepts it silently, and the job will go
    further as if the person had said "yes", and the model will then not find what it was
    asked about.
    """
    for line in reversed(tail.splitlines()):
        line = line.strip()
        if line:
            return line[:200]

    return ""


def watch_job(job, table=None):
    """One tick of the watchdog for one job. Returns an event frame or None.

    One rule for both occasions: an event is sent only when the state
    HAS CHANGED. Otherwise the job would remind about itself every second, and
    each such reminder raises a turn of the model.

    `table` — a snapshot of the kernel already read. It is taken by `watch_jobs` for the whole tick
    and passed here: one pass over /proc per tick, and not one per job.
    """
    state = job.poll()

    if not job.running:
        return None

    # --- A. It asks for input. This is a fact, and not a deadline: we look at the kernel. It is counted
    # only when the job has been silent for at least `WAITING_QUIET_S` — less than that is
    # an ordinary pause in `find | head`.
    # ---
    if state["quiet_s"] > WAITING_QUIET_S:
        table = table if table is not None else proc_table()

        with job._lock:
            tail = job._tail

        if group_reads_stdin(job.pid, job.stdin_inode, table):
            # The prompt line, if there is one. Empty — the question was asked, but
            # the prompt did not go into the log: `read -p` writes it only when
            # stdin is a terminal (checked: in a job nothing of it remains in the
            # log). We must not stay silent in such a case: a job in
            # which nothing is printed and which stands on reading stdin
            # will never end by itself, and it is useful for the model to know
            # what it needs. We still will not answer for it.
            ask = prompt_line(tail)

            with job._lock:
                job.waiting = True
                job.ask = ask
                job.stale_mark = None
        else:
            with job._lock:
                # It stood and stopped: either it was answered or the job moved on.
                job.waiting = False
                job.ask = ""

    with job._lock:
        waiting, ask = job.waiting, job.ask

    if waiting:
        # About one and the same question — once.
        if job.ask_sent != ask:
            job.ask_sent = ask
            return {
                "kind": "job",
                "event": "waiting",
                "job": job.id,
                "pid": job.pid,
                "runtime_s": state["runtime_s"],
                "quiet_s": state["quiet_s"],
                "ask": ask,
                "head": job.head(EVENT_HEAD),
                "tail": job.tail(EVENT_TAIL),
            }

        return None

    # It asked and stopped — it was answered. With a separate event, because this is
    # the same change of state as the start of waiting, and on that side it
    # must also be taken off the accounts: otherwise the session will remind the model
    # until the very end of the job about a question that was answered long ago.
    if job.ask_sent is not None:
        job.ask_sent = None
        return {"kind": "job", "event": "resumed", "job": job.id, "pid": job.pid,
                "runtime_s": state["runtime_s"]}

    # --- B. It is silent. This is not a fact, but a deadline: a long silence may be legitimate
    # (a build, a snapshot, a download), therefore the text is also different — "silent for long",
    # and not "asks for input". It is set once per band of silence: output has started —
    # the count has started anew.
    # ---
    quiet = state["quiet_s"]
    mark = job.stale_mark

    if mark == "sent" and quiet < WAITING_QUIET_S:
        with job._lock:
            job.stale_mark = None
        mark = None

    if quiet >= QUIET_ALERT_S and mark != "sent":
        with job._lock:
            job.stale_mark = "sent"

        return {
            "kind": "job",
            "event": "stale",
            "job": job.id,
            "pid": job.pid,
            "runtime_s": state["runtime_s"],
            "quiet_s": quiet,
            "limit_s": QUIET_ALERT_S,
            "head": job.head(EVENT_HEAD),
            "tail": job.tail(EVENT_TAIL),
        }

    return None


def watch_jobs():
    """One thread for ALL jobs, a tick per second.

    A thread per job would be simpler, but there are sometimes a dozen jobs, and they would all
    wake up at the same time: the price of a tick does not depend on how many
    jobs are running, while the price of a thread per job does.

    Only a snapshot of the dictionary is taken under the lock: the pass over the kernel itself goes without it,
    otherwise a tick of the watchdog would also hold the start of new jobs.
    """
    while True:
        time.sleep(JOB_TICK)

        with _job_lock:
            running = [job for job in jobs.values() if job.running]

        if not running:
            continue

        # A snapshot of the kernel for the whole tick. Taken lazily: while all the jobs are producing output,
        # there is nothing to look at in /proc, and a pass costs about a millisecond.
        table = None

        for job in running:
            try:
                if table is None:
                    table = proc_table()

                frame = watch_job(job, table)
            except Exception:
                log(f"watchdog of job {job.id} stumbled:\n{traceback.format_exc()}")
                continue

            if frame and job._send:
                try:
                    job._send(frame)
                except Exception:
                    log(f"event about job {job.id} did not go:\n{traceback.format_exc()}")


jobs = {}
_job_lock = threading.Lock()


# The name of a job is a hash, and not an ordinal number. The model takes a number for a
# counter: seeing j12, it reasons about how many jobs there were before, although this
# does not concern it. A hash promises nothing and is compared with nothing.
#
# The name comes FROM BRAIN, when a job is started at its request, and the hand takes
# a ready one. The reason is not politeness: brain shows the call to the person BEFORE
# the hand answers, and without its own name it has nothing to write above the code. To wait
# for the answer for the sake of a line in the chat would mean making the rendering depend on
# the network, and the branch "there is no answer — show without a hash" would have to be built on top.
# Its own name removes both at once.
#
# The hand owns the PROCESS, and not what it is called: an identifier established by
# the caller and passed with the request is an ordinary technique (the same `make_ref()` of the
# caller in OTP).
def new_id():
    with _job_lock:
        return secrets.token_hex(6)


def start_job(code, cwd=None, send=None, jid=None):
    jid = jid or new_id()

    job = Job(jid, code, cwd)
    jobs[jid] = job
    job.start(send or (lambda _frame: None))
    return job


def start_cell(code, shell, send, jid=None):
    jid = jid or new_id()

    job = CellJob(jid, code, shell, send)
    jobs[jid] = job
    job.start()
    return job


def read_job(job, head=0, tail=0, grep=None):
    """The answer to a log read request: the state always, the pieces — as asked.

    `head` and `tail` — in LINES. READ_CAP cuts on top, by bytes.

    A RUNNING JOB IS NOT READ. The log grows, and any piece of it is
    intermediate: the model would take interrupted work for finished, and without
    a single sign that this is not the result. There is nothing to wait for here either — a turn must not
    stand because of a read. Therefore the answer is short: it is not over yet.
    When it is over — the hand itself will report the head and the tail, and only then is the log read
    in full and in any piece.

    The refusal stands HERE, and not in brain, for two reasons. The truth about the state
    is known to the hand: brain keeps track only of those jobs that it started itself, while
    those started from inside a cell (`bash()`) are unknown to it altogether. And the contents on
    refusal do not leave the hand — there is no reason to drive sixteen kilobytes over the network
    that are thrown away anyway.
    """
    state = job.poll()

    if state["state"] == "running":
        return {"status": state, "running": True, "head": "", "tail": "", "matches": []}

    result = {"status": state, "head": "", "tail": "", "matches": []}

    if head:
        text = job.head_lines(int(head), READ_CAP)
        result["head"] = text
        result["head_cut"] = len(text) >= READ_CAP

    if tail:
        text = job.tail_lines(int(tail), READ_CAP)
        result["tail"] = text
        result["tail_cut"] = len(text) >= READ_CAP

    if grep:
        try:
            pattern = re.compile(grep)
        except re.error as exc:
            result["grep_error"] = str(exc)
            return result

        matches, total = [], 0
        # We search only what has settled on disk: in a trimmed log the search
        # hits its beginning, and this is honestly said in the answer.
        with open(job.log_path, "r", encoding="utf-8", errors="replace") as f:
            for number, line in enumerate(f, start=1):
                if pattern.search(line):
                    total += 1
                    if len(matches) < MATCH_COUNT_CAP:
                        matches.append(f"{number}: {line.rstrip()[:MATCH_LINE_CAP]}")

        result["matches"] = matches
        result["matches_total"] = total
        result["searched_bytes"] = job.bytes_kept

    return result


def describe_job(state):
    """One line about a job. In a form that there is no reason to parse with the eyes:
    the state, the time, the lines and the return code.

    The path to the log is deliberately absent here: the log is addressed by the HASH of the job and is read
    only through read_log. This line travels to the model, and a path in it was
    an invitation to read the logs bypassing the tool.
    """
    first = " ".join(state["code"].strip().splitlines()[:1])[:80]

    if state["state"] == "running":
        how = f"running {state['runtime_s']} s"

        # It waits for input — and this is visible from the kernel, and not inferred from silence. The line
        # is shown right here: it is answered by it, and there is no reason to look for it with the eyes in the log.
        if state.get("ask"):
            how += f", waiting for input: {state['ask'][:200]}"
        elif state["quiet_s"] > 10:
            how += f", quiet for {state['quiet_s']} s"

        rc = "no exit code yet"
    else:
        how = f"finished in {state['runtime_s']} s"
        rc = f"exit code {state['exit']}"

    kept = f"{state['kept_bytes']} B"
    if state["truncated"]:
        kept += f" of {state['bytes']} (log truncated)"

    # A job without a process of its own (a cell of the kernel) does not get the word "pid" at all:
    # "pid None" would read as a number that failed to be read.
    pid = f"pid {state['pid']}, " if state.get("pid") else ""

    return (
        f"job {state['job']} [{how}]: {first}\n"
        f"  {pid}{state['lines']} lines, {kept}, "
        f"rc: {rc}"
    )


def render_read(job, head=0, tail=0, grep=None):
    data = read_job(job, head, tail, grep)

    if data.get("running"):
        return describe_job(data["status"])

    lines = [describe_job(data["status"])]

    if data["head"]:
        mark = " (cut at 16 KB)" if data.get("head_cut") else ""
        lines += [f"--- start of the log{mark} ---", data["head"]]

    if data["tail"]:
        mark = " (cut at 16 KB)" if data.get("tail_cut") else ""
        lines += [f"--- tail{mark} ---", data["tail"]]

    if grep:
        got = data.get("matches", [])
        lines.append(f"--- by pattern {grep!r}: {data.get('matches_total', 0)} lines, "
                     f"first {len(got)} shown ---")
        lines += got

    if data.get("grep_error"):
        lines.append(f"the pattern did not parse: {data['grep_error']}")

    if data["status"]["truncated"] and not tail and not grep:
        lines.append(
            "the log is truncated by size: the beginning lies on disk, the end "
            "is in the tail (tail>0). The whole output has gone nowhere."
        )

    return "\n".join(lines)


def job_result(job, show=4000):
    """The result of a completed command — as readable as the output of a cell.

    `bash()` returns text, and not a report of success: the model needs the result of the
    work, and not a confirmation that it started it.
    """
    state = job.poll()

    if state["state"] == "running":
        return f"{describe_job(state)}\nstill working; read the tail: read_log {job.id}"

    body = job.output()
    if len(body) > show:
        body = (
            body[: show // 3]
            + f"\n... [{show} characters of {len(body)} shown; "
            + f"the rest is in the log: read_log {job.id}] ...\n"
            + body[-(show - show // 3):]
        )

    return (
        f"$ {job.code.strip()}\n"
        f"--- {describe_job(state)} ---\n"
        f"{body if body.strip() else '(empty output)'}"
    )


def bash(code, cwd=None, timeout=None, await_=True):
    """A shell command with a handle: it returns at once and outlives the cell.

    An ordinary cell waits for the command as a whole — `sleep 30 &` in a cell holds it
    for thirty seconds, and `pip install` in a cell holds it for minutes, and all this
    time the loop of the agent stands. Here the work goes into its own process group,
    the handle returns at once, and about the end hand tells brain ITSELF (a job frame).

    What is visible at the handle: `jobs["j3"].poll()` — the state and the return code;
    `.send(text)` — an answer to a prompt inside the command; `.interrupt()` /
    `.kill()` — a signal to the group; `.wait(seconds)` — to wait until waiting cannot be avoided.

    There is deliberately no log here. The output of a job is read by ONE path — through the
    tool `read_log` by the hash of the job. Formerly this list contained
    `.tail(n)`, `.head(n)` and `.output()`, and they called for reading the log bypassing the
    tool: past the limit on what is shown and past the trace in memory.

    A non-zero exit here is NOT an exception: the return code lies in the final
    text, and there is nothing to branch on it with except the code itself.
    """
    job = start_job(code, cwd=cwd, send=current_send())

    if not await_:
        return job

    try:
        job.wait(timeout)
    except subprocess.TimeoutExpired:
        return f"{describe_job(job.poll())}\ndid not wait it out in {timeout} s — it keeps running"

    return job_result(job)


_send_local = threading.local()
_default_send = {"fn": lambda _frame: None}


def current_send():
    """Where to send the frames of a job started from inside a cell.

    A background job has no waiting request — the result goes off by itself, as a frame.
    """
    return getattr(_send_local, "send", None) or _default_send["fn"]


def make_shell():
    shell = InteractiveShell.instance()

    # The return code of a shell command reaches brain as a separate field, and not as a
    # Python traceback. Otherwise `exit 3` turns into a CalledProcessError
    # a thousand characters long, where the code itself stands as the word "status 3" at the very
    # end, and the model simply has nothing to branch `if rc != 0` on.
    _bash = shell.magics_manager.magics["cell"].get("bash")

    if _bash is not None:

        def _bash_with_status(line, cell, _bash=_bash):
            try:
                _bash_with_status.rc = 0
                return _bash(line, cell)
            except subprocess.CalledProcessError as exc:
                _bash_with_status.rc = exc.returncode
                return None
            finally:
                _send_local.rc = _bash_with_status.rc

        _bash_with_status.rc = None
        shell.register_magic_function(_bash_with_status, "cell", "bash")

    # All below is about saving tokens, and not about beauty.
    #
    # 1. We do not print the traceback to stdout at all: it already arrives as a separate
    #    field `error`, and moreover without ANSI colouring, whose escape sequences
    #    take more room than the text of the error itself.
    # 2. The displayhook is silent: we give the value of the last expression in the field
    #    `result`, while IPython duplicates it to stdout with the line `Out[N]: ...`.
    #
    # We mute exactly the output, and not the displayhook itself: it also fills
    # `result.result`, from which we take this value.
    shell.colors = "NoColor"
    shell.InteractiveTB.set_mode(mode="Plain")
    shell.showtraceback = lambda *args, **kwargs: None
    shell.showsyntaxerror = lambda *args, **kwargs: None
    shell.displayhook.write_output_prompt = lambda: None
    shell.displayhook.write_format_data = lambda *args, **kwargs: None

    # The handle of a job is visible in the kernel: from the next cell one works with it as with an
    # ordinary object — `poll()`, `send()`, `interrupt()`, `wait()`.
    #
    # READING THE LOG from here IS A DEAD END, and it is left deliberately. Technically
    # `jobs["j3"].output()` from a cell works and will give the log in full, past
    # `read_log`: past the limit on what is shown and past the trace in memory. But nowhere
    # else is this path named — neither in the descriptions of the tools, nor in the
    # docstrings, nor in the lines about a job — and so there is no reason to walk it either.
    #
    # We did not close it. This is not a security boundary and cannot be one:
    # the model has `bash` in the same container where the logs lie, and one cannot separate it
    # from a file by a prohibition in the kernel — for that the logs would have to be carried away to
    # where the hand does not reach. Here a HINT is removed, and not a possibility:
    # a road that is not told about is not trodden. And the object itself is needed as a whole
    # — cutting its methods for the look of "closed" would mean breaking a working thing
    # for the sake of a non-existent protection.
    shell.user_ns["jobs"] = jobs
    shell.user_ns["bash"] = bash

    shell.run_cell("import os, sys, json, pathlib, re\n")
    return shell


class LiveOutput(io.StringIO):
    """Accumulates output and along the way sends it to brain in separate frames.

    The point is to show the person what is happening while the code is still working: without
    this a long calculation looks like silence. Frames are sent not on every
    write (a loop with print may print thousands of times), but in portions: when
    enough has accumulated or enough time has passed.
    """

    def __init__(self, send, stream_name):
        super().__init__()
        self._send = send
        self._name = stream_name
        self._pending = ""
        self._last = time.monotonic()

    def write(self, text):
        self._pending += text
        now = time.monotonic()

        if len(self._pending) >= 512 or now - self._last >= 0.5:
            self.flush_live()

        return super().write(text)

    def flush_live(self):
        if self._pending:
            self._send({"kind": "stream", "name": self._name, "text": self._pending})
            self._pending = ""
            self._last = time.monotonic()


def with_rid(send, rid):
    """The answer must return the request number.

    There may be several waiting on that side: brain is free during
    exec and legitimately asks about background jobs while the cell counts. Without
    a number the answers are indistinguishable — the second would overwrite the waiting one of the first. The number
    is set by brain, our business is to return it untouched.

    This does not concern events (kind=job): nobody requested them, they have no
    number and cannot have one.
    """

    def _send(payload):
        if rid is not None and "rid" not in payload:
            payload = {**payload, "rid": rid}
        return send(payload)

    return _send


def execute(shell, code, send=None, returncode=None):
    send = send or (lambda _frame: None)
    out = LiveOutput(send, "stdout")
    err = LiveOutput(send, "stderr")
    result_repr = None
    error = ""

    try:
        with redirect_stdout(out), redirect_stderr(err):
            result = shell.run_cell(code, store_history=True)
        if result.error_before_exec or result.error_in_exec:
            exc = result.error_before_exec or result.error_in_exec
            error = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))
        elif result.result is not None:
            result_repr = repr(result.result)
    except Exception:
        error = traceback.format_exc()

    # A tail that did not reach the threshold must also go off.
    out.flush_live()
    err.flush_live()

    frame = {
        "kind": "result",
        "stdout": out.getvalue() + err.getvalue(),
        "result": result_repr,
        "error": error,
        "namespace": namespace(shell),
    }

    # The return code is set ONLY when the cell ran a shell command.
    # An ordinary Python cell has no return code, and there is no need to invent one.
    if returncode is not None:
        frame["returncode"] = returncode

    return frame


def namespace(shell):
    """What lives in the kernel right now: the names and a very short description of each.

    The kernel survives calls, but the model only HEARD about it — from the prompt —
    and wrote every cell anew: import again, httpx.get of the same
    page again, parsing again. One page was downloaded like that eight times.
    Therefore we show the list to it right in the result: not "the state lives on",
    but "here are your variables, take what is ready".
    """
    items = []

    for name, value in shell.user_ns.items():
        if name.startswith("_") or name in shell.user_ns_hidden:
            continue

        kind = type(value).__name__

        try:
            if callable(value):
                what = "function" if kind == "function" else kind
            elif hasattr(value, "__len__"):
                what = f"{kind}[{len(value)}]"
            else:
                what = kind
        except Exception:
            what = kind

        items.append(f"{name}: {what}")

    return sorted(items)


def interrupt(thread):
    """A Ctrl-C into the thread of a cell: the cell falls, the kernel stays alive.

    It is called from `CellJob.signal` — that is, by `job_signal` with the hash of the cell.

    Formerly the only way to interrupt drawn-out code was to kill the hand —
    along with it went everything accumulated: downloaded pages, parsed data,
    defined functions. Here, however, exactly the cell is interrupted.

    PyThreadState_SetAsyncExc sets an exception to the thread, and the
    interpreter handles it at the nearest bytecode boundary. So inside a blocking
    syscall (the same httpx waiting for a server answer) the interruption will reach the code not
    instantly, but when the call returns. This is the price for the kernel staying whole.
    """
    if thread is None or not thread.is_alive():
        return False

    done = ctypes.pythonapi.PyThreadState_SetAsyncExc(
        ctypes.c_ulong(thread.ident), ctypes.py_object(KeyboardInterrupt)
    )

    # More than one — the interpreter did not understand whom to set it to: we roll back, otherwise
    # the exception would fly to a random thread.
    if done > 1:
        ctypes.pythonapi.PyThreadState_SetAsyncExc(ctypes.c_ulong(thread.ident), None)
        return False

    return done == 1


def log(message):
    print(message, file=sys.stderr, flush=True)


class Channel:
    """A transport-agnostic frame channel: read/write in terms of frames."""

    def __init__(self, read_exactly, write_all):
        self._read_exactly = read_exactly
        self._write_all = write_all
        self._lock = threading.Lock()

    def recv(self):
        header = self._read_exactly(4)
        if header is None:
            return None
        (length,) = struct.unpack(">I", header)
        if length > MAX_FRAME:
            raise ValueError(f"frame too large: {length}")
        return self._read_exactly(length)

    def send(self, payload):
        # Two write: the execution thread (live output and the result) and the main
        # loop (the answer to an interrupt). A frame must go off as a whole, otherwise at that
        # end the length and the parsing will diverge.
        data = json.dumps(payload).encode("utf-8")
        with self._lock:
            self._write_all(struct.pack(">I", len(data)) + data)


def connect_channel():
    host = os.environ.get("SWEET_BRAIN_HOST", "sweet-brain")
    port = int(os.environ.get("SWEET_BRAIN_PORT", "4000"))
    hand_id = os.environ.get("SWEET_HAND_ID", "")

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
    # We introduce ourselves: by this id brain finds the process that waits for us.
    channel.send({"op": "hello", "id": hand_id})
    return channel


def main():
    shell = make_shell()

    channel = connect_channel()

    # The job watchdog is ONE thread for all. A tick per second, and not a thread per
    # job: the price of a tick does not depend on the number of jobs at all, while the price of a thread
    # does, and on a dozen running works the difference is visible.
    #
    # It waits for nothing: it looks into /proc for the jobs that are still running, and
    # tells brain if a job has stopped at a question or has been silent for long. Its frame is
    # the same as for the end of a job — kind=job, only event differs.
    threading.Thread(target=watch_jobs, daemon=True).start()

    # The code is executed in separate job threads, while this loop is free
    # all the time and reads frames: while a cell counts, the hand hears both the requests and
    # the signals for every job.
    while True:
        frame = channel.recv()
        if frame is None:
            break

        try:
            msg = json.loads(frame)
        except Exception:
            # There is no number: the frame did not parse. brain will sort it out itself — such an
            # answer it hands out to all waiting ones.
            channel.send({"kind": "result", "error": "bad frame"})
            continue

        reply = with_rid(channel.send, msg.get("rid"))

        # Parsing a frame must not bring down the hand: an extra frame from brain or
        # an error in the handler itself — this is an answer about an error, and not the end of
        # the session. Formerly the very first exception carried away the container together
        # with the kernel and all the accumulated work.
        try:
            if msg.get("op") == "exec":
                # A cell is the same kind of background job as a shell command:
                # we answer with a handle AT ONCE, the result will come as an event. The live output
                # goes off in frames without a number — by then there is no waiting one.
                try:
                    job = start_cell(msg.get("code", ""), shell, channel.send, msg.get("job"))
                    reply(
                        {
                            "kind": "result",
                            "started": describe_job(job.poll()),
                            "job": job.id,
                            "pid": job.pid,
                            "stdout": "",
                            "result": None,
                            "error": "",
                            "namespace": namespace(shell),
                        }
                    )
                except Exception as exc:
                    reply(
                        {
                            "kind": "result",
                            "stdout": "",
                            "result": None,
                            "error": f"could not start the cell: {exc}",
                            "namespace": namespace(shell),
                        }
                    )
            elif msg.get("op") == "shell":
                # A background command: we answer with a handle AT ONCE, and not at its end. This is
                # the non-blocking hand — the turn of the model does not wait for the work.
                cwd = msg.get("cwd") or None
                try:
                    job = start_job(msg.get("code", ""), cwd=cwd, send=channel.send, jid=msg.get("job"))
                    reply(
                        {
                            "kind": "result",
                            "started": describe_job(job.poll()),
                            "job": job.id,
                            "pid": job.pid,
                            "stdout": "",
                            "result": None,
                            "error": "",
                            "namespace": namespace(shell),
                        }
                    )
                except Exception as exc:
                    reply(
                        {
                            "kind": "result",
                            "stdout": "",
                            "result": None,
                            "error": f"could not start the job: {exc}",
                            "namespace": namespace(shell),
                        }
                    )
            elif msg.get("op") == "job_read":
                # Reading the log is on request, the waiting one is released by the answer. That is how
                # the model reads work that is still running, without disturbing it.
                job = jobs.get(msg.get("job", ""))
                if job is None:
                    reply(
                        {
                            "kind": "result",
                            "stdout": "",
                            "result": None,
                            "error": f"job not found: {msg.get('job')}",
                            "namespace": namespace(shell),
                        }
                    )
                else:
                    text = render_read(
                        job,
                        head=int(msg.get("head") or 0),
                        tail=int(msg.get("tail") or 0),
                        grep=msg.get("grep") or None,
                    )
                    reply(
                        {
                            "kind": "result",
                            "stdout": text,
                            "result": None,
                            "error": "",
                            "namespace": namespace(shell),
                        }
                    )
            elif msg.get("op") == "job_list":
                # The state of every job goes to brain as STRUCTURE, and not as ready text: brain
                # takes the line apart into parts (the process, the launch, the ceiling) and adds to
                # them what the hand does not know — the code of the job and its question. The
                # number of the process is here the same one that went off in the answer about the
                # launch, therefore the two lines speak about one and the same job.
                #
                # The order is by the hash, as in the accounting of brain: the selection travels
                # into the context, and from the order it would change for no reason at all.
                states = [job.poll() for _jid, job in sorted(jobs.items())]

                reply(
                    {
                        "kind": "result",
                        "stdout": "",
                        "result": states,
                        "error": "",
                        "namespace": namespace(shell),
                    }
                )
            elif msg.get("op") == "job_signal":
                job = jobs.get(msg.get("job", ""))
                if job is None:
                    reply({"kind": "result", "stdout": "", "result": None,
                                  "error": f"job not found: {msg.get('job')}", "namespace": ""})
                else:
                    what = msg.get("signal", "interrupt")
                    if what == "kill":
                        job.kill()
                    else:
                        job.interrupt()
                    reply({"kind": "result", "stdout": describe_job(job.poll()),
                                  "result": None, "error": "", "namespace": namespace(shell)})
            elif msg.get("op") == "job_send":
                job = jobs.get(msg.get("job", ""))
                try:
                    job.send(msg.get("text", ""))
                    reply({"kind": "result", "stdout": "sent to the job stdin",
                                  "result": None, "error": "", "namespace": ""})
                except Exception as exc:
                    reply({"kind": "result", "stdout": "", "result": None,
                                  "error": f"{exc}", "namespace": ""})
            elif msg.get("op") == "ping":
                reply({"kind": "result", "stdout": "", "result": "pong", "error": ""})
            else:
                reply({"kind": "result", "error": f"unknown op: {msg.get('op')}"})
        except Exception:
            reply(
                {
                    "kind": "result",
                    "stdout": "",
                    "result": None,
                    "error": traceback.format_exc(),
                    "namespace": namespace(shell),
                }
            )

    log("brain disconnected, exiting")
    sys.exit(0)


if __name__ == "__main__":
    main()
