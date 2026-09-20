# The image of brain. The loop of the agent lives here, along with the memory and the keys.
#
# Python is not needed here at all: both the hand and the embedder live in their own containers
# and connect to brain over the network. Hence Alpine and 460 MB instead of 1.7 GB.
FROM elixir:1.18-otp-27-alpine

RUN apk add --no-cache git build-base \
    && mix local.hex --force && mix local.rebar --force

WORKDIR /app

# We build and launch as a RELEASE, in the prod environment. It is not about the size of the image
# (it is the same) and not about convenience, but about `start_permanent`: in dev it is false,
# and the chosen stock of restarts of `Sweet.Supervisor` left the VM alive —
# the node lies, while from the point of view of docker the container is alive, and there is no one to bring it up.
# In prod the death of the root supervisor puts the VM out, the container exits, and docker
# brings it up again (`restart: unless-stopped` in compose).
ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get && mix deps.compile

COPY config ./config
COPY lib ./lib
COPY rel ./rel
# We put the tests into the image: they have to be run with the same elixir that works, and the
# agent itself does not have it. The build is single-stage deliberately — mix and the sources
# remain in the image. We set the environment for the tests explicitly, otherwise they will go into prod,
# which stands here as the default:
#
#   docker run --rm -e MIX_ENV=test sweet-brain:dev mix test --no-start
COPY test ./test
RUN mix compile && mix release

# IEx as the front end: we connect with `docker attach sweet-brain`. `start_iex`, and not
# `start`, exactly for this. The release has no distribution (see rel/env.sh.eex).
CMD ["/app/_build/prod/rel/sweet/bin/sweet", "start_iex"]
