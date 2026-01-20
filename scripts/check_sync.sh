#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: check_sync.sh [options]

Options:
  --container NAME         Docker container name or ID to run curl/jq within
  --compose-service NAME   Docker Compose service name to resolve to a container
  --local-rpc URL          Local Tendermint RPC URL (default: http://127.0.0.1:${CL_RPC_PORT:-26657})
  --public-rpc URL         Public/reference Tendermint RPC URL (required)
  --block-lag N            Acceptable lag in blocks (default: 2)
  --no-install             Do not install curl/jq inside the container
  --env-file PATH          Path to env file to load
  -h, --help               Show this help

Examples:
  ./scripts/check_sync.sh --public-rpc https://sei-rpc.polkachu.com:443
  ./scripts/check_sync.sh --compose-service sei --public-rpc https://sei-rpc.polkachu.com:443
  CONTAINER=sei-1 PUBLIC_RPC=https://sei-rpc.polkachu.com:443 ./scripts/check_sync.sh
USAGE
}

ENV_FILE="${ENV_FILE:-}"
CONTAINER="${CONTAINER:-}"
DOCKER_SERVICE="${DOCKER_SERVICE:-}"
LOCAL_RPC="${LOCAL_RPC:-}"
PUBLIC_RPC="${PUBLIC_RPC:-}"
BLOCK_LAG_THRESHOLD="${BLOCK_LAG_THRESHOLD:-2}"
INSTALL_TOOLS="${INSTALL_TOOLS:-1}"

load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line#export }"
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      local key="${line%%=*}"
      local val="${line#*=}"
      val="${val#"${val%%[![:space:]]*}"}"
      if [[ "$val" =~ ^\".*\"$ ]]; then
        val="${val:1:-1}"
      elif [[ "$val" =~ ^\'.*\'$ ]]; then
        val="${val:1:-1}"
      fi
      printf -v "$key" '%s' "$val"
      export "$key"
    fi
  done < "$file"
}

args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--env-file" ]]; then
    ENV_FILE="${args[$((i+1))]:-}"
  fi
done

if [[ -n "${ENV_FILE:-}" ]]; then
  load_env_file "$ENV_FILE"
elif [[ -f ".env" ]]; then
  load_env_file ".env"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container) CONTAINER="$2"; shift 2 ;;
    --compose-service) DOCKER_SERVICE="$2"; shift 2 ;;
    --local-rpc) LOCAL_RPC="$2"; shift 2 ;;
    --public-rpc) PUBLIC_RPC="$2"; shift 2 ;;
    --block-lag) BLOCK_LAG_THRESHOLD="$2"; shift 2 ;;
    --no-install) INSTALL_TOOLS="0"; shift ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 2 ;;
  esac
done

LOCAL_RPC="${LOCAL_RPC:-http://127.0.0.1:${CL_RPC_PORT:-26657}}"
PUBLIC_RPC="${PUBLIC_RPC:-}"

resolve_container() {
  if [[ -n "$CONTAINER" || -z "$DOCKER_SERVICE" ]]; then
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "❌ docker not found; cannot resolve --compose-service $DOCKER_SERVICE"
    exit 2
  fi
  if docker compose version >/dev/null 2>&1; then
    CONTAINER="$(docker compose ps -q "$DOCKER_SERVICE" | head -n 1)"
  elif command -v docker-compose >/dev/null 2>&1; then
    CONTAINER="$(docker-compose ps -q "$DOCKER_SERVICE" | head -n 1)"
  else
    echo "❌ docker compose not available; cannot resolve --compose-service $DOCKER_SERVICE"
    exit 2
  fi
}

http_get() {
  local base="$1"
  local path="$2"
  local url="${base%/}${path}"
  if [[ -n "$CONTAINER" ]]; then
    docker exec "$CONTAINER" sh -c "
      curl -sS '$url'
    "
  else
    curl -sS "$url"
  fi
}

jq_eval() {
  if [[ -n "$CONTAINER" ]]; then
    docker exec -i "$CONTAINER" jq -r "$1"
  else
    jq -r "$1"
  fi
}

resolve_container

if [[ -z "$PUBLIC_RPC" ]]; then
  echo "❌ PUBLIC_RPC is required. Use --public-rpc or set PUBLIC_RPC."
  exit 2
fi

if [[ -n "$CONTAINER" ]]; then
  if [[ "$INSTALL_TOOLS" == "1" ]]; then
    echo "==> Ensuring curl and jq are installed inside container"
    docker exec -u root "$CONTAINER" sh -c '
    set -e
    if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
      exit 0
    fi
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y
      apt-get install -y curl jq ca-certificates
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache curl jq ca-certificates
    else
      echo "Unsupported base image. No apt-get or apk found."
      exit 1
    fi
    '
  fi
else
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "❌ curl and jq are required on the host when no --container is set."
    exit 2
  fi
fi

echo "==> Querying Tendermint /status"

local_status="$(http_get "$LOCAL_RPC" "/status")"
public_status="$(http_get "$PUBLIC_RPC" "/status")"

local_height="$(echo "$local_status" | jq_eval '.result.sync_info.latest_block_height // .sync_info.latest_block_height')"
local_hash="$(echo "$local_status" | jq_eval '.result.sync_info.latest_block_hash // .sync_info.latest_block_hash')"
local_catching_up="$(echo "$local_status" | jq_eval '.result.sync_info.catching_up // .sync_info.catching_up')"

public_height="$(echo "$public_status" | jq_eval '.result.sync_info.latest_block_height // .sync_info.latest_block_height')"
public_hash="$(echo "$public_status" | jq_eval '.result.sync_info.latest_block_hash // .sync_info.latest_block_hash')"

if [[ -z "$local_height" || "$local_height" == "null" ]]; then
  echo "❌ Local /status missing latest_block_height. Raw response:"
  echo "$local_status"
  exit 3
fi

if [[ -z "$public_height" || "$public_height" == "null" ]]; then
  echo "❌ Public /status missing latest_block_height. Raw response:"
  echo "$public_status"
  exit 4
fi

local_height_dec="$local_height"
public_height_dec="$public_height"
lag="$((public_height_dec - local_height_dec))"

echo "Local  height: $local_height_dec"
echo "Public height: $public_height_dec"
echo "Lag:          $lag blocks (threshold: $BLOCK_LAG_THRESHOLD)"
echo "Catching up:  $local_catching_up"
echo

if [[ "$local_height" == "$public_height" && "$local_hash" == "$public_hash" ]]; then
  echo "✅ Node is in sync (height and hash match)"
  exit 0
fi

if [[ "$local_catching_up" == "true" ]]; then
  echo "⚠️  Node reports catching_up=true. Still syncing."
  exit 1
fi

if (( lag > BLOCK_LAG_THRESHOLD )); then
  echo "⚠️  Heights differ beyond threshold. Still syncing."
  exit 1
fi

if [[ "$local_height" == "$public_height" && "$local_hash" != "$public_hash" ]]; then
  echo "❌ Heights match but hashes differ. Possible fork or divergence."
  exit 2
fi

if (( lag < 0 )); then
  echo "⚠️  Local height is ahead of public endpoint. Public may be lagging."
  exit 0
fi

echo "⚠️  Heights differ but within threshold. Likely normal propagation lag."
exit 0
