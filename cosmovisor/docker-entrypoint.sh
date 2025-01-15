#!/usr/bin/env bash
set -euo pipefail

# rm /cosmos/.cosmovisor

compile_version() {
  version=$1

  echo "Compiling $version binary..."

  # Always start from a clean state.
  rm -rf /build/*
  cd /build
  git clone https://github.com/sei-protocol/sei-chain.git && cd sei-chain && git checkout tags/${version}
  go mod download
  WASMVM_VERSION=$(go list -m all | grep 'github.com/CosmWasm/wasmvm' | awk '{print $2}')
  LIBWASMVM_FILENAME="libwasmvm_muslc.x86_64.a"
  LIBWASMVM_URL="https://github.com/CosmWasm/wasmvm/releases/download/$WASMVM_VERSION/$LIBWASMVM_FILENAME"
  curl -L -o $LIBWASMVM_FILENAME $LIBWASMVM_URL
  mkdir -p lib
  mv $LIBWASMVM_FILENAME lib/libwasmvm.a
  export CGO_ENABLED=1
  export CGO_CFLAGS="-I$PWD/lib"
  export CGO_LDFLAGS="-L$PWD/lib -lwasmvm -lm"
  export CGO_LDFLAGS_ALLOW="-Wl,-rpath=.*"
  GOOS="linux" GOARCH="amd64" make build
}

# Common cosmovisor paths.
__cosmovisor_path=/cosmos/cosmovisor
__genesis_path=$__cosmovisor_path/genesis
__current_path=$__cosmovisor_path/current
__upgrades_path=$__cosmovisor_path/upgrades

if [[ ! -f /cosmos/.initialized ]]; then
  echo "Initializing!"

  compile_version $DAEMON_VERSION
  mv /build/sei-chain/build/$DAEMON_NAME $__genesis_path/bin/$DAEMON_NAME

  # Point to current.
  ln -s -f $__genesis_path $__current_path

  echo "Running init..."
  $__genesis_path/bin/$DAEMON_NAME init $MONIKER --chain-id $NETWORK --home /cosmos --overwrite

  echo "Downloading genesis..."
  wget https://raw.githubusercontent.com/sei-protocol/testnet/main/$NETWORK/genesis.json -O /cosmos/config/genesis.json

  if [ -n "$SNAPSHOT" ]; then
    echo "Downloading snapshot..."
    curl -o - -L $SNAPSHOT | lz4 -c -d - | tar --exclude='data/priv_validator_state.json' -x -C /cosmos
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
    SNAPSHOT_HASH=$(curl -s $RPC_URL/block\?height\=$SNAPSHOT_HEIGHT | jq -r '.result.block_id.hash')
    echo "SNAPSHOT_HASH=$SNAPSHOT_HASH"

    dasel put -f /cosmos/config/config.toml -v true statesync.enable
    dasel put -f /cosmos/config/config.toml -v "${RPC_URL},${RPC_URL}" statesync.rpc_servers
    dasel put -f /cosmos/config/config.toml -v $SNAPSHOT_HEIGHT statesync.trust_height
    dasel put -f /cosmos/config/config.toml -v $SNAPSHOT_HASH statesync.trust_hash
    dasel put -f /cosmos/config/config.toml -v 2 statesync.fetchers
    dasel put -f /cosmos/config/config.toml -v "10s" statesync.chunk-request-timeout
  else 
    echo "No rapid sync url defined."
  fi

  touch /cosmos/.initialized
  touch /cosmos/.cosmovisor
else
  echo "Already initialized!"
fi

# If previously running without cosmovisor.
if [[ ! -f /cosmos/.cosmovisor ]]; then
  compile_version $DAEMON_VERSION
  mkdir -p $__genesis_path/bin
  mkdir $__upgrades_path
  mv /build/sei-chain/build/$DAEMON_NAME $__genesis_path/bin/$DAEMON_NAME

  # Point to current.
  ln -s -f $__genesis_path $__current_path

  touch /cosmos/.cosmovisor
else
  echo "Cosmovisor support already handled!"
fi

# Handle updates and upgrades.
__should_update=0

compare_versions() {
    current=$1
    new=$2

    # Remove leading 'v' if present
    ver_current="${current#v}"
    ver_new="${new#v}"

    # Extract major and minor from the first two dot-separated fields
    major_current=$(echo "$ver_current" | cut -d. -f1)
    minor_current=$(echo "$ver_current" | cut -d. -f2)
    major_new=$(echo "$ver_new" | cut -d. -f1)
    minor_new=$(echo "$ver_new" | cut -d. -f2)

    # For the third field, we might have patch plus possible suffix
    patch_part_current=$(echo "$ver_current" | cut -d. -f3)
    patch_part_new=$(echo "$ver_new" | cut -d. -f3)

    # Now split the patch from the suffix at the first dash
    patch_current="${patch_part_current%%-*}"
    suffix_current="${patch_part_current#*-}"
    if [ "$suffix_current" = "$patch_part_current" ]; then
        # Means there was no dash
        suffix_current=""
    fi

    patch_new="${patch_part_new%%-*}"
    suffix_new="${patch_part_new#*-}"
    if [ "$suffix_new" = "$patch_part_new" ]; then
        suffix_new=""
    fi

    # Convert major/minor/patch to numbers
    major_current=$((major_current))
    minor_current=$((minor_current))
    patch_current=$((patch_current))

    major_new=$((major_new))
    minor_new=$((minor_new))
    patch_new=$((patch_new))

    # Compare major/minor/patch
    if [ "$major_new" -gt "$major_current" ]; then
        __should_update=2
        return
    elif [ "$major_new" -lt "$major_current" ]; then
        __should_update=0
        return
    fi

    if [ "$minor_new" -gt "$minor_current" ]; then
        __should_update=2
        return
    elif [ "$minor_new" -lt "$minor_current" ]; then
        __should_update=0
        return
    fi

    if [ "$patch_new" -gt "$patch_current" ]; then
        __should_update=2
        return
    elif [ "$patch_new" -lt "$patch_current" ]; then
        __should_update=0
        return
    fi

    # If major/minor/patch are identical, check suffix difference
    if [ "$suffix_current" != "$suffix_new" ]; then
        __should_update=1
        return
    fi

    # Otherwise, exact match
    __should_update=0
}
# Upgrades overview.

# Protocol Upgrades:
# - These involve significant changes to the network, such as major or minor version releases.
# - Stored in a dedicated directory: /cosmos/cosmovisor/{upgrade_name}.
# - Cosmovisor automatically manages the switch based on the network's upgrade plan.

# Binary Updates:
# - These are smaller, incremental changes such as patch-level fixes.
# - Only the binary is replaced in the existing /cosmos/cosmovisor/{upgrade_name} directory.
# - Binary updates are applied immediately without additional actions.

# First, we get the current version and compare it with the desired version.
# Also don't know why seid writes to stderr.
__current_version=$($__current_path/bin/$DAEMON_NAME version 2>&1)

echo "Current version: ${__current_version}. Desired version: ${DAEMON_VERSION}"

compare_versions $__current_version $DAEMON_VERSION

# __should_update=0: No update needed or versions are the same.
# __should_update=1: Higher patch version.
# __should_update=2: Higher minor or major version.
if [ "$__should_update" -eq 2 ]; then
  echo "Network upgrade..."
  # This is a network upgrade. We'll build the binary, put it in a new folder
  # and we'll let cosmovisor handle the upgrade just in time.
  # Thankfully, sei keeps the upgrade name the same as the version tag, so no need to query
  # the tendermint API.
  mkdir -p $__upgrades_path/$DAEMON_VERSION/bin
  compile_version $DAEMON_VERSION
  mv /build/sei-chain/build/$DAEMON_NAME $__upgrades_path/$DAEMON_VERSION/bin/$DAEMON_NAME
  echo "Done!"
elif [ "$__should_update" -eq 1 ]; then
  echo "Updating binary for current version."
  compile_version $DAEMON_VERSION
  mv /build/sei-chain/build/$DAEMON_NAME $__current_path/bin/$DAEMON_NAME
  echo "Done!"
else
  echo "No updates needed."
fi

# temporary measure
mkdir -p $__upgrades_path/$DAEMON_VERSION/bin
compile_version $DAEMON_VERSION
mv /build/sei-chain/build/$DAEMON_NAME $__upgrades_path/$DAEMON_VERSION/bin/$DAEMON_NAME
echo "Done!"
# temporary measure


echo "Updating config..."

# Get public IP address.
__public_ip=$(curl -s ifconfig.me/ip)
echo "Public ip: ${__public_ip}"

# Always update public IP address, moniker and ports.
dasel put -f /cosmos/config/config.toml -v "10s" consensus.timeout_commit
dasel put -f /cosmos/config/config.toml -v "${__public_ip}:${CL_P2P_PORT}" p2p.external_address
dasel put -f /cosmos/config/config.toml -v "tcp://0.0.0.0:${CL_P2P_PORT}" p2p.laddr
dasel put -f /cosmos/config/config.toml -v "tcp://0.0.0.0:${CL_RPC_PORT}" rpc.laddr
dasel put -f /cosmos/config/config.toml -v ${MONIKER} moniker
dasel put -f /cosmos/config/config.toml -v true prometheus
dasel put -f /cosmos/config/config.toml -v ${LOG_LEVEL} log_level
dasel put -f /cosmos/config/config.toml -v "false" db-sync.db-sync-enable
dasel put -f /cosmos/config/config.toml -v 20480000000000 p2p.send-rate
dasel put -f /cosmos/config/config.toml -v 20480000000000 p2p.send-rate

dasel put -f /cosmos/config/app.toml -v "0.0.0.0:${RPC_PORT}" json-rpc.address
dasel put -f /cosmos/config/app.toml -v "0.0.0.0:${WS_PORT}" json-rpc.ws-address
dasel put -f /cosmos/config/app.toml -v "0.0.0.0:${CL_GRPC_PORT}" grpc.address
dasel put -f /cosmos/config/app.toml -v true grpc.enable
dasel put -f /cosmos/config/app.toml -v "tcp://0.0.0.0:${REST_API_PORT}" api.address
dasel put -f /cosmos/config/app.toml -v "true" state-commit.sc-enable
dasel put -f /cosmos/config/app.toml -v "true" state-store.ss-enable

dasel put -f /cosmos/config/client.toml -v "tcp://localhost:${CL_RPC_PORT}" node

# Always update peers.
echo "Downloading peers..."
PEERS=$(curl -sL "${RPC_URL}/net_info")
PARSED_PEERS=$(echo "$PEERS" | jq -r '.peers[].url | sub("^mconn://"; "")' | paste -sd "," -)

dasel put -f /cosmos/config/config.toml -v $PARSED_PEERS p2p.persistent-peers

# cosmovisor will create a subprocess to handle upgrades
# so we need a special way to handle SIGTERM

# Start the process in a new session, so it gets its own process group.
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
setsid "$@" ${EXTRA_FLAGS} &
pid=$!

# Trap SIGTERM in the script and forward it to the process group
trap 'kill -TERM -$pid' TERM

# Wait for the background process to complete
wait $pid
