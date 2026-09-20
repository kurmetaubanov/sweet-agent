#!/usr/bin/env bash
# Lay the secrets from .env out into files in secrets/ — one value per file.
#
# Why separate files if there is .env. In .env the keys get into the environment
# of a container, and the hand reads out the environment of any container through the docker API:
# `docker top sweet-brain ps_args=wwaxe` prints it in full, and the cutting of
# Config.Env in docker-filter does not help here — it is only about inspect.
# A file, however, is mounted by compose (the source file: in docker-compose.yml), and
# mountings get neither into export nor into commit.
#
# .env at the same time remains the only place where the keys are edited by hand:
# this script only lays them out, it does not keep its own copy.
#
# Run it on the HOST before `docker compose up`. From the container of the agent it is impossible:
# its docker goes through docker-filter, and the filter will not let the bind of secrets/ through.
set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE="${ENV_FILE:-.env}"
OUT_DIR="${OUT_DIR:-secrets}"

# On the left is the name of the file (as docker-compose.yml expects it), on the right is the name in .env.
PAIRS="
github_api_key:SWEET_GITHUB_API_KEY
serpbase_api_key:SWEET_SERPBASE_API_KEY
anthropic_api_key:SWEET_ANTHROPIC_API_KEY
telegram_bot_token:SWEET_TELEGRAM_BOT_TOKEN
tg_allowed_user_id:SWEET_TG_ALLOWED_USER_ID
"

if [ ! -f "$ENV_FILE" ]; then
  echo "there is no $ENV_FILE — there is nowhere to take the keys from" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
# 711, and not 700. Docker-filter runs as nobody and checks every bind source
# of a create request; with 700 it cannot enter this directory at all and the
# whole stack stops at "bind source not visible to filter". 711 lets it traverse
# to the named file, while the listing of the directory stays closed: a stranger
# who does not already know the file name learns nothing.
chmod 711 "$OUT_DIR"

missing=""

for pair in $PAIRS; do
  file="${pair%%:*}"
  var="${pair##*:}"

  # The last assignment wins — exactly as compose reads it.
  # We strip the quotes at the edges: the value must go into the file, and not an .env record.
  value="$(sed -n "s/^[[:space:]]*${var}=//p" "$ENV_FILE" | tail -n 1)"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"

  if [ -z "$value" ]; then
    missing="$missing $var"
    continue
  fi

  # Without a newline: the value is read as is both in Elixir and in python.
  # umask for the time of the write, otherwise the file exists for a moment with the default mode.
  (umask 077; printf '%s' "$value" > "$OUT_DIR/$file")

  # 644, and not 600. The file is mounted into the containers and read by a process INSIDE
  # them, and its uid is not subject to us: brain works as root and will read any,
  # but mitmdump in egress drops privileges to the mitmproxy user. That one
  # is now uid 1000, coinciding by chance with the owner of these files, — the base image will change,
  # and egress will silently stop substituting tokens (an unreadable
  # file leads Sweet.Secret and the addon into the fallback branch, and there it is empty).
  # From outside this opens nothing: the directory remains 700, only the owner can enter it,
  # while the bind mounts the file directly, bypassing the rights of the directory.
  chmod 644 "$OUT_DIR/$file"
  echo "$OUT_DIR/$file — $(wc -c < "$OUT_DIR/$file") bytes"
done

if [ -n "$missing" ]; then
  # We do not fall: SerpBase may be deliberately unconfigured — then egress simply
  # does not substitute the search key. But an empty model key is noticed at once, by
  # the very first request, and will not be silent.
  echo "there are no values in $ENV_FILE:$missing" >&2
fi

echo
echo "next: docker compose up -d --force-recreate brain egress-filter"
