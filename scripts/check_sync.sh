#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: check_sync.sh [options]

Options:
  --container NAME         Docker container name or ID to run curl/jq within
  --compose-service NAME   Docker Compose service name to resolve to a container
  --local-rpc URL          Local Tendermint RPC URL (default: http://127.0.0.1:${CL_RPC_PORT:-26657})
  --public-rpc URL         Public/reference Tendermint RPC URL (default: https://sei-rpc.polkachu.com:443)
  --block-lag N            Acceptable lag in blocks (default: 2)
  --no-install             Do not install curl/jq inside the container
  --env-file PATH          Path to env file to load
  -h, --help               Show this help

Examples:
  ./scripts/check_sync.sh
  ./scripts/check_sync.sh --public-rpc https://sei-rpc.polkachu.com:443
  ./scripts/check_sync.sh --compose-service sei --public-rpc https://sei-rpc.polkachu.com:443
  CONTAINER=sei-1 PUBLIC_RPC=https://sei-rpc.polkachu.com:443 ./scripts/check_sync.sh
USAGE
}

DEFAULT_PUBLIC_RPC="https://sei-rpc.polkachu.com:443"
DEFAULT_BLOCK_LAG_THRESHOLD="2"

ENV_FILE="${ENV_FILE:-}"
CONTAINER="${CONTAINER:-}"
DOCKER_SERVICE="${DOCKER_SERVICE:-}"
LOCAL_RPC="${LOCAL_RPC:-}"
PUBLIC_RPC="${PUBLIC_RPC:-}"
BLOCK_LAG_THRESHOLD="${BLOCK_LAG_THRESHOLD:-$DEFAULT_BLOCK_LAG_THRESHOLD}"
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
      export "${key}=${val}"
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

DEFAULT_LOCAL_RPC="http://127.0.0.1:${CL_RPC_PORT:-26657}"
LOCAL_RPC="${LOCAL_RPC:-$DEFAULT_LOCAL_RPC}"
PUBLIC_RPC="${PUBLIC_RPC:-$DEFAULT_PUBLIC_RPC}"

resolve_container_error=""
resolve_container() {
  if [[ -n "$CONTAINER" || -z "$DOCKER_SERVICE" ]]; then
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    resolve_container_error="docker not found; cannot resolve --compose-service ${DOCKER_SERVICE}"
    return 1
  fi
  if docker compose version >/dev/null 2>&1; then
    CONTAINER="$(docker compose ps -q "$DOCKER_SERVICE" | head -n 1)"
  elif command -v docker-compose >/dev/null 2>&1; then
    CONTAINER="$(docker-compose ps -q "$DOCKER_SERVICE" | head -n 1)"
  else
    resolve_container_error="docker compose not available; cannot resolve --compose-service ${DOCKER_SERVICE}"
    return 1
  fi
  if [[ -z "$CONTAINER" ]]; then
    resolve_container_error="no running container found for compose service ${DOCKER_SERVICE}"
    return 1
  fi
}

http_get() {
  local base="$1"
  local path="$2"
  local url="${base%/}${path}"
  if [[ -n "$CONTAINER" ]]; then
    docker exec "$CONTAINER" sh -c "curl -sS --fail --max-time 10 '$url' 2>/dev/null"
  else
    curl -sS --fail --max-time 10 "$url" 2>/dev/null
  fi
}

jq_eval() {
  if [[ -n "$CONTAINER" ]]; then
    docker exec -i "$CONTAINER" jq -r "$1"
  else
    jq -r "$1"
  fi
}

print_final_status() {
  local status="$1"
  case "$status" in
    in_sync)
      echo "✅ Final status: in sync";;
    syncing)
      echo "⏳ Final status: syncing";;
    *)
      echo "❌ Final status: error";;
  esac
}

fail_sync() {
  local msg="$1"
  echo "❌ error: $msg"
  echo
  print_final_status "error"
  exit 2
}

echo "⏳ Checking tools inside container"
if ! resolve_container; then
  fail_sync "$resolve_container_error"
fi

if [[ -n "$CONTAINER" ]]; then
  if ! docker exec "$CONTAINER" sh -c "command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1"; then
    if [[ "$INSTALL_TOOLS" == "1" ]]; then
      if ! docker exec -u root "$CONTAINER" sh -c '
        set -e
        if command -v apt-get >/dev/null 2>&1; then
          apt-get update -y
          apt-get install -y curl jq ca-certificates
        elif command -v apk >/dev/null 2>&1; then
          apk add --no-cache curl jq ca-certificates
        else
          exit 1
        fi
      '; then
        fail_sync "failed to install curl/jq inside container"
      fi
    else
      fail_sync "curl/jq not found in container and --no-install set"
    fi
  fi
else
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    fail_sync "curl and jq are required on the host when no --container is set"
  fi
fi

echo "✅ Tools available in container"
echo "⏳ Sync status"

if ! local_status="$(http_get "$LOCAL_RPC" "/status")"; then
  fail_sync "RPC unreachable (${LOCAL_RPC})"
fi

if ! public_status="$(http_get "$PUBLIC_RPC" "/status")"; then
  fail_sync "RPC unreachable (${PUBLIC_RPC})"
fi

local_height=""
public_height=""
local_hash=""
public_hash=""
local_catching_up=""

if ! local_height="$(printf '%s' "$local_status" | jq_eval '.result.sync_info.latest_block_height // .sync_info.latest_block_height // empty')"; then
  fail_sync "JSON parse failure (local RPC)"
fi
if ! public_height="$(printf '%s' "$public_status" | jq_eval '.result.sync_info.latest_block_height // .sync_info.latest_block_height // empty')"; then
  fail_sync "JSON parse failure (public RPC)"
fi
if ! local_hash="$(printf '%s' "$local_status" | jq_eval '.result.sync_info.latest_block_hash // .sync_info.latest_block_hash // empty')"; then
  fail_sync "JSON parse failure (local RPC)"
fi
if ! public_hash="$(printf '%s' "$public_status" | jq_eval '.result.sync_info.latest_block_hash // .sync_info.latest_block_hash // empty')"; then
  fail_sync "JSON parse failure (public RPC)"
fi
if ! local_catching_up="$(printf '%s' "$local_status" | jq_eval '.result.sync_info.catching_up // .sync_info.catching_up // empty')"; then
  fail_sync "JSON parse failure (local RPC)"
fi

if [[ -z "$local_height" || -z "$public_height" ]]; then
  fail_sync "missing latest_block_height in RPC response"
fi

if [[ ! "$local_height" =~ ^[0-9]+$ || ! "$public_height" =~ ^[0-9]+$ ]]; then
  fail_sync "non-numeric latest_block_height in RPC response"
fi

sync_state="unknown"
if [[ "$local_catching_up" == "true" ]]; then
  sync_state="syncing"
elif [[ "$local_catching_up" == "false" ]]; then
  sync_state="in_sync"
fi

case "$sync_state" in
  in_sync)
    echo "✅ sync_state: in_sync";;
  syncing)
    echo "⏳ sync_state: syncing";;
  *)
    echo "⚠️  sync_state: unknown";;
 esac

echo
echo "⏳ Head comparison"

local_height_dec="$local_height"
public_height_dec="$public_height"
lag=$((public_height_dec - local_height_dec))
if (( lag > 0 )); then
  lag_state="local behind"
  lag_abs=$lag
elif (( lag < 0 )); then
  lag_state="local ahead"
  lag_abs=$(( -lag ))
else
  lag_state="in sync"
  lag_abs=0
fi

echo "Local head:  ${local_height_dec}"
echo "Public head: ${public_height_dec}"
echo "Lag:         ${lag_abs} blocks (threshold: ${BLOCK_LAG_THRESHOLD}) (${lag_state})"
echo "ETA sample:  n/a"

echo
echo "⏳ Latest block comparison"

local_hash_display="$local_hash"
public_hash_display="$public_hash"
[[ -z "$local_hash_display" ]] && local_hash_display="n/a"
[[ -z "$public_hash_display" ]] && public_hash_display="n/a"

echo "Local latest:  ${local_height_dec} ${local_hash_display}"
echo "Public latest: ${public_height_dec} ${public_hash_display}"

echo

if [[ "$local_height_dec" == "$public_height_dec" && "$local_hash_display" != "n/a" && "$public_hash_display" != "n/a" && "$local_hash_display" != "$public_hash_display" ]]; then
  print_final_status "error"
  exit 2
fi

if [[ "$sync_state" == "syncing" ]]; then
  print_final_status "syncing"
  exit 1
fi

if (( lag > BLOCK_LAG_THRESHOLD )); then
  print_final_status "syncing"
  exit 1
fi

print_final_status "in_sync"
exit 0
