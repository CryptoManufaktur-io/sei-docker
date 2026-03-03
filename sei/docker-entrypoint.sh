#!/usr/bin/env bash
set -euo pipefail

if [ "${FRESH_INIT_WITH_DATA}" = "true" ]; then
  rm -rf /cosmos/.initialized
  SNAPSHOT=""
  STATE_SYNC="false"
fi

if [[ ! -f /cosmos/.initialized ]]; then
  echo "Initializing!"

  echo "Running init..."
  seid init "$MONIKER" --chain-id "$NETWORK" --home /cosmos --overwrite

  echo "Downloading genesis..."
  wget "https://raw.githubusercontent.com/sei-protocol/testnet/main/$NETWORK/genesis.json" -O /cosmos/config/genesis.json

  if [ -n "$SNAPSHOT" ]; then
    echo "Downloading snapshot..."
    if command -v aria2c &> /dev/null; then
      echo "Using aria2c for faster download (multi-connection)..."
      aria2c -x 16 -s 16 -k 1M --file-allocation=none --allow-overwrite=true -d /tmp -o snapshot.tar.lz4 "$SNAPSHOT" && \
        lz4 -c -d /tmp/snapshot.tar.lz4 | tar --exclude='data/priv_validator_state.json' -x -C /cosmos && \
        rm -f /tmp/snapshot.tar.lz4
    else
      echo "aria2c not found, falling back to curl..."
      curl -o - -L "$SNAPSHOT" | lz4 -c -d - | tar --exclude='data/priv_validator_state.json' -x -C /cosmos
    fi
  else
    echo "No snapshot URL defined."
  fi

  # Check whether we should rapid state sync
  if [ "${STATE_SYNC}" = "true" ]; then
    echo "Configuring rapid state sync"
    # Get the latest height
    LATEST=$(curl -s "${RPC_URL}/block" | jq -r '.block.header.height')
    echo "LATEST=$LATEST"

    # Calculate the snapshot height
    SNAPSHOT_HEIGHT=$((LATEST - 2000));
    echo "SNAPSHOT_HEIGHT=$SNAPSHOT_HEIGHT"

    # Get the snapshot hash
    SNAPSHOT_HASH=$(curl -s "$RPC_URL/block\?height\=$SNAPSHOT_HEIGHT" | jq -r '.block_id.hash')
    echo "SNAPSHOT_HASH=$SNAPSHOT_HASH"

    dasel put -f /cosmos/config/config.toml -v true statesync.enable
    dasel put -f /cosmos/config/config.toml -v "${RPC_URL},${RPC_URL}" statesync.rpc-servers
    dasel put -f /cosmos/config/config.toml -v "$SNAPSHOT_HEIGHT" statesync.trust-height
    dasel put -f /cosmos/config/config.toml -v "$SNAPSHOT_HASH" statesync.trust-hash
    dasel put -f /cosmos/config/config.toml -v 2 statesync.fetchers
    dasel put -f /cosmos/config/config.toml -v "10s" statesync.chunk-request-timeout
  else
    echo "No rapid sync url defined."
  fi

  touch /cosmos/.initialized
else
  echo "Already initialized!"
fi

echo "Updating config..."

# Get public IP address.
__public_ip=$(curl -s ifconfig.me/ip)
echo "Public ip: ${__public_ip}"

# Always update public IP address, moniker and ports.
dasel put -f /cosmos/config/config.toml -v "10s" consensus.timeout_commit
dasel put -f /cosmos/config/config.toml -v "${__public_ip}:${CL_P2P_PORT}" p2p.external_address
dasel put -f /cosmos/config/config.toml -v "tcp://0.0.0.0:${CL_P2P_PORT}" p2p.laddr
dasel put -f /cosmos/config/config.toml -v "tcp://0.0.0.0:${CL_RPC_PORT}" rpc.laddr
dasel put -f /cosmos/config/config.toml -v "${MONIKER}" moniker
dasel put -f /cosmos/config/config.toml -v true prometheus
dasel put -f /cosmos/config/config.toml -v "${LOG_LEVEL}" log_level
dasel put -f /cosmos/config/config.toml -v "false" db-sync.db-sync-enable
dasel put -f /cosmos/config/config.toml -v 20480000000000 p2p.send-rate
dasel put -f /cosmos/config/config.toml -v 20480000000000 p2p.recv-rate
dasel put -f /cosmos/config/config.toml -v "${BLOCK_BEHIND_THRESHOLD}" self-remediation.blocks-behind-threshold

dasel put -f /cosmos/config/app.toml -v "0.0.0.0:${RPC_PORT}" json-rpc.address
dasel put -f /cosmos/config/app.toml -v "0.0.0.0:${WS_PORT}" json-rpc.ws-address
dasel put -f /cosmos/config/app.toml -v "0.0.0.0:${CL_GRPC_PORT}" grpc.address
dasel put -f /cosmos/config/app.toml -v true grpc.enable
dasel put -f /cosmos/config/app.toml -v "tcp://0.0.0.0:${REST_API_PORT}" api.address
dasel put -f /cosmos/config/app.toml -v "true" state-commit.sc-enable
dasel put -f /cosmos/config/app.toml -v "true" state-store.ss-enable

# experimental
dasel put -f /cosmos/config/app.toml -v 1 state-commit.sc-snapshot-writer-limit
dasel put -f /cosmos/config/app.toml -v 100000 state-commit.sc-cache-size

dasel put -f /cosmos/config/app.toml -v 40000 state-store.sc-cache-size
dasel put -f /cosmos/config/app.toml -v 500 state-store.concurrency-workers
dasel put -f /cosmos/config/app.toml -v "true" state-store.occ-enabled

dasel put -f /cosmos/config/client.toml -v "tcp://0.0.0.0:${CL_RPC_PORT}" node

# Always update peers.
echo "Downloading peers..."
if PEERS=$(curl -sL --max-time 30 "${RPC_URL}/net_info" 2>/dev/null) && [ -n "$PEERS" ]; then
  PARSED_PEERS=$(echo "$PEERS" | jq -r '.peers[].url | sub("^mconn://"; "")' | paste -sd "," -)
  if [ -n "$PARSED_PEERS" ]; then
    dasel put -f /cosmos/config/config.toml -v "$PARSED_PEERS" p2p.persistent-peers
  else
    echo "No peers found from RPC."
  fi
else
  echo "Could not fetch peers from ${RPC_URL}/net_info, skipping."
fi

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${EXTRA_FLAGS}
