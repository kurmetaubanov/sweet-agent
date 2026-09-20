# The image of the hand. Built separately: docker build -t sweet-hand:dev hand/
#
# The set repeats prime-agent: the agent works with the same data and the same
# formats, and it cannot install this on the spot — the container lives one
# session, while pip through the egress filter for every new container is minutes.
#
# The layers are split DELIBERATELY: an edit of one list must not re-download
# the rest. The heavy ones (torch, LibreOffice, the browser) separately from the light ones.
FROM python:3.12-slim

# --- System ---
#
# We started from an empty image and got burnt: the agent was asked how to commit, and git
# was not in the container at all — it spent a turn searching for the binary and installed
# dulwich into /workspace for itself.
#
# build-essential gives the code of the model a compiler inside the container. The same as in
# prime; a deliberate decision, and not a trifle: with it the hand will build a native
# extension — and anything else besides.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates gnupg \
    ripgrep jq sqlite3 \
    tmux procps \
    build-essential \
    poppler-utils \
    && rm -rf /var/lib/apt/lists/*

# --- Docker CLI ---
#
# The client only, as in prime. ATTENTION: by itself it opens nothing —
# the hand sits on the sweet_hands network, the docker filter on sweet_ctl, there is no route between them, and
# DOCKER_HOST is not given to the hand. The binary is there, it has no one to talk to.
# Granting access is a separate decision, and not a consequence of the installation.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# --- Elixir ---
#
# We install it as a Debian package, and NOT by building from source: trixie already holds
# an assembled OTP 27 with JIT (erts) and Elixir 1.18, so there is nothing to compile —
# 23 MB from
# installations elixir, elixirc and mix work, including the downloading of hex packages.
#
# The package has exactly 7 dependencies, and elixir/elixirc work on them, while mix does
# not: without erlang-asn1 it falls with "application asn1 could not be found", without
# erlang-ssl — "application ssl could not be found". We add them explicitly so that the
# list does not depend on how apt sorts out the dependencies next time.
#
# erlang-dev — the headers of OTP, for the build, and not for the launch. mint carries one
# .erl (mint_shims.erl), and that one does -include_lib("public_key/include/
# public_key.hrl"). In the deb layout of Debian erlang-public-key consists of one
# ebin, while the header travels separately, in erlang-dev: without it mix deps.compile falls
# on "can't find include lib", and the tests do not follow (checked: erlc on the same
# file gives the same error).
#
# HEX_CACERTS_PATH — the CA of the egress filter, the same one the hand already mounts into
# /certs. Without it mix falls on TLS: "Unknown CA" (checked live).
RUN apt-get update && apt-get install -y --no-install-recommends \
    elixir erlang-asn1 erlang-ssl erlang-dev \
    && rm -rf /var/lib/apt/lists/*
ENV HEX_CACERTS_PATH=/certs/mitmproxy-ca-cert.pem

# --- Hex and rebar3 ---
#
# Otherwise MIX_HOME remains $HOME/.mix, while the HOME of the hand at runtime is /tmp (see below).
# On an empty MIX_HOME mix does not fall and does not scold, but ASKS "Shall I install
# Hex? [Yn]" and silently waits for an answer: the stdin of the hand is open, but there is no one to write into it.
# That is how the first run of the tests stood for 12 minutes (checked live: the question
# appears after 0.4 s and hangs until the end of the session). Therefore we put both tools
# into the image, and take MIX_HOME away from $HOME.
#
# /opt, and NOT /workspace: /workspace is a bind mount of the host, it overrides
# everything the image would have put there, and on a fresh rollout .mix would simply not be there —
# the hand would stop at the same question. /opt is the image itself.
#
# And not /tmp either: it is mounted noexec, while rebar3 is an escript. With /tmp in MIX_HOME
# the rebar3 dependency (telemetry) falls on :eacces even before compilation
# (checked live). /opt is executable, as is /workspace.
#
# HEX_CACERTS_PATH is REMOVED for the time of the build, and not left empty: it is set by the line
# above, and /certs/mitmproxy-ca-cert.pem does not exist at the build stage — the folder
# appears only at runtime. With an empty value Hex takes cacertfile "" and
# falls on "Unknown CA" (checked in a real build); without the variable at all it
# goes into the system store, and the download passes.
ENV MIX_HOME=/opt/mix
RUN env -u HEX_CACERTS_PATH mix local.hex --force \
    && env -u HEX_CACERTS_PATH mix local.rebar --force

# --- The kernel of the hand ---
RUN pip install --no-cache-dir ipython==8.* dill==0.3.* uv

# --- Data ---
RUN pip install --no-cache-dir numpy scipy pandas matplotlib \
    scikit-learn lightgbm statsmodels ruptures

# --- Databases ---
RUN pip install --no-cache-dir psycopg2-binary duckdb

# --- Documents ---
RUN pip install --no-cache-dir pypdf pdfminer.six python-docx python-pptx \
    openpyxl Pillow pylatexenc

# --- Web ---
#
# bs4 in pair with lxml: on the built-in parser bs4 is slower and parses
# crooked markup worse. Parsing ready HTML is an order of magnitude cheaper than bringing up a
# browser — prime does not have this, there everything goes through playwright.
RUN pip install --no-cache-dir requests httpx beautifulsoup4 lxml markdownify

# --- torch, CPU-only build (a separate PyTorch index) ---
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu

# --- LibreOffice, the heaviest layer ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    libreoffice-calc libreoffice-writer libreoffice-impress \
    && rm -rf /var/lib/apt/lists/*

# --- The browser ---
#
# The browser lands in /opt, and NOT in the home directory: the rootfs of the hand is read
# only, while HOME at runtime is taken away into /tmp (see below). By default
# playwright looks for the browser in ~/.cache and would not find it.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright
RUN pip install --no-cache-dir playwright==1.61.0 \
    && playwright install-deps chromium \
    && playwright install chromium \
    && chmod -R a+rX /opt/playwright \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 1000 hand

COPY server.py /opt/hand/server.py

# The home directory is not writable at runtime: the rootfs is mounted
# read-only (it is set for the container from the brain side). One can write into
# /workspace and /tmp, therefore we take everything the libraries want to cache there:
# matplotlib — fonts, playwright and the rest — temporary files. Without this
# matplotlib falls on the very first plot, while IPython scolds at start.
ENV HOME=/tmp \
    MPLCONFIGDIR=/tmp/mpl \
    XDG_CACHE_HOME=/tmp/cache

# An unprivileged user.
USER hand
WORKDIR /workspace

EXPOSE 5000
CMD ["python", "-u", "/opt/hand/server.py"]
