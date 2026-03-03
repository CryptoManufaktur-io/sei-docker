# sei-docker

Docker compose for Sei.

Meant to be used with [central-proxy-docker](https://github.com/CryptoManufaktur-io/central-proxy-docker) for traefik
and Prometheus remote write; use `:ext-network.yml` in `COMPOSE_FILE` inside `.env` in that case.

## Quick setup

Run `cp default.env .env`, then `nano .env`, and update values like MONIKER, NETWORK, and SNAPSHOT.

If you want the consensus node RPC ports exposed locally, use `rpc-shared.yml` in `COMPOSE_FILE` inside `.env`.

- `./seid install` brings in docker-ce, if you don't have Docker installed already.
- `./seid up`

To update the software, run `./seid update` and then `./seid up`

## Upgrading seid

To upgrade to a new seid version:

1. Update `SEID_TAG` in `.env` to the desired version tag.
2. Run `./seid update` to rebuild the Docker image with the new binary.
3. Run `./seid up` to start the node with the new version.

The seid binary is compiled from source during `docker compose build` in a multi-stage Dockerfile.

## Check sync

`./seid check-sync` compares the local node status with a public Sei RPC.

Defaults used when no flags are provided:
- Compose service: `sei`
- Local RPC: `http://127.0.0.1:${CL_RPC_PORT:-26657}`
- Public RPC: `https://sei-rpc.polkachu.com:443`

Override as needed:
- `./seid check-sync --public-rpc https://sei-rpc.polkachu.com:443`
- `./seid check-sync --compose-service sei --public-rpc https://sei-rpc.polkachu.com:443`

### CLI

An image with the `seid` binary is available, e.g:

- `docker compose run --rm cli version`

## Version

Sei Docker uses a semver scheme.

This is sei-docker v3.0.0
