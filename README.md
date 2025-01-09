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

### CLI

An image with the `seid` binary is also avilable, e.g:

- `docker compose run --rm cli version`

## Version

Sei Docker uses a semver scheme.

This is sei-docker v1.0.0
