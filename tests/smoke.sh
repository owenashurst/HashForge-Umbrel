#!/usr/bin/env bash
# Starts the package's compose file with stand-ins for what umbrelOS provides (its variables, its proxy
# and the Bitcoin Node app) and checks that the pool comes up, answers and keeps its data over a restart.
# It catches mistakes in the compose file early; it does not prove the package works on an Umbrel.
#
# Usage: tests/smoke.sh [pool image] [host port for the web interface]
#   pool image   Use this image for the pool instead of the one pinned in the compose file, for
#                example a local build that has not been published yet.
set -euo pipefail

pool_image="${1:-}"
export SMOKE_WEB_PORT="${2:-18343}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="hashforge-pool"
# A folder inside Docker's own machine rather than this one, so file ownership behaves as it does on an Umbrel.
data="/var/tmp/hashforge-umbrel-smoke"

# Stops Git Bash on Windows from rewriting the container paths below; it means nothing elsewhere.
export MSYS_NO_PATHCONV=1

# What umbrelOS and the Bitcoin Node app would supply.
export APP_DATA_DIR="$data"
export DEVICE_DOMAIN_NAME="umbrel.local"
export NETWORK_IP="10.21.0.0"
export APP_BITCOIN_NODE_IP="bitcoin"
export APP_BITCOIN_RPC_PORT="8332"
export APP_BITCOIN_RPC_USER="umbrel"
export APP_BITCOIN_RPC_PASS="smoke-test-rpc-password"
export APP_BITCOIN_ZMQ_HASHBLOCK_PORT="28332"
export APP_HASHFORGE_POOL_POSTGRES_PASSWORD="smoke-test-postgres-password"
export APP_HASHFORGE_POOL_REDIS_PASSWORD="smoke-test-redis-password"
export APP_PASSWORD="smoke-test-app-password"
export SMOKE_BITCOIN_IMAGE="${SMOKE_BITCOIN_IMAGE:-hashforge-bitcoind}"

# Paths are given relative to the repository so that they mean the same to Docker on every system.
cd "$repo"
files=(--file "$app/docker-compose.yml" --file "tests/umbrel-stand-in.yml")
if [ -n "$pool_image" ]; then
    override="tests/.pool-image.yml"
    printf 'services:\n  pool:\n    image: %s\n' "$pool_image" > "$override"
    files+=(--file "$override")
fi

# --compatibility names containers app_service_1, as umbrelOS does and as the compose file expects.
compose() {
    docker compose --compatibility --project-name "$app" "${files[@]}" "$@"
}

in_data_folder() {
    docker run --rm --volume /var/tmp:/var/tmp busybox:1.37 sh -c "$1"
}

cleanup() {
    compose down --volumes --remove-orphans > /dev/null 2>&1 || true
    in_data_folder "rm -rf $data" > /dev/null 2>&1 || true
}
trap 'cleanup; rm -f "${override:-}"' EXIT
cleanup

# Checks below read from here-strings rather than pipes: with pipefail, a grep that stops at its first
# match can make the command feeding it fail, which would report a failure that did not happen.
fail() {
    echo "FAILED: $*" >&2
    compose logs --tail 60 pool db redis >&2 || true
    exit 1
}

wait_for_pool() {
    for _ in $(seq 1 90); do
        if curl --silent --fail --max-time 3 "http://127.0.0.1:${SMOKE_WEB_PORT}/healthz" > /dev/null; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# umbrelOS hands the app its data folders owned by user 1000, which is who the services run as.
in_data_folder "mkdir -p $data/data/pool $data/data/postgres $data/data/redis && chown -R 1000:1000 $data"

started="$(compose up --detach 2>&1)" || fail "the services did not start: $started"
echo "Waiting for the pool to answer on port ${SMOKE_WEB_PORT}"
wait_for_pool || fail "the pool did not answer within three minutes"

pools="$(curl --silent --fail --max-time 10 "http://127.0.0.1:${SMOKE_WEB_PORT}/api/pools")"
grep --quiet '"solo"' <<< "$pools" || fail "the solo pool is missing from /api/pools: $pools"

connect="$(curl --silent --fail --max-time 10 "http://127.0.0.1:${SMOKE_WEB_PORT}/connect")" || fail "the Connect page did not load"
# Only the host and port are matched: the page writes the "+" of stratum+tcp as an HTML entity.
grep --quiet '//umbrel.local:3342' <<< "$connect"     || fail "the Connect page does not show the Umbrel's address and the solo port; it shows: $(grep --only-matching 'tcp://[^<]*' <<< "$connect" | head -n 5)"

# Other apps share the pool's network on an Umbrel, so the admin page must ask for the app's password.
admin="http://127.0.0.1:${SMOKE_WEB_PORT}/admin"
status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 "$admin")"
[ "$status" = "401" ] || fail "the admin page answered $status without a password; it should ask for one (401)"
status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 --user "admin:wrong" "$admin")"
[ "$status" = "401" ] || fail "the admin page answered $status to a wrong password; it should refuse (401)"
status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 --user "admin:${APP_PASSWORD}" "$admin")"
[ "$status" = "200" ] || fail "the admin page answered $status to the right password; it should open (200)"

# The Stratum port must accept a miner on the port the package publishes.
# shellcheck disable=SC2016 # The script is meant to be expanded inside the container, not here.
reply="$(compose exec -T pool bash -c '
    exec 3<>/dev/tcp/127.0.0.1/3342
    printf "%s\n" "{\"id\":1,\"method\":\"mining.subscribe\",\"params\":[\"smoke/1.0\"]}" >&3
    IFS= read -r -t 10 line <&3
    printf "%s" "$line"')"
grep --quiet '"result"' <<< "$reply" || fail "the solo pool did not answer mining.subscribe: $reply"

# The databases must refuse a visitor without the password, since every Umbrel app shares one network.
if compose exec -T redis redis-cli ping 2> /dev/null | grep --quiet PONG; then
    fail "Redis answered without its password"
fi

# The services run as user 1000 and must have been able to write their data.
owners="$(in_data_folder "stat -c %u $data/data/postgres/PG_VERSION $data/data/redis/appendonlydir" 2>&1)" \
    || fail "the databases wrote no data: $owners"
grep --quiet --invert-match '^1000$' <<< "$owners" && fail "data was written by a user other than 1000: $owners"

# A restart recreates the containers, as an Umbrel restart or update does; the data must still be there.
keys_before="$(in_data_folder "ls $data/data/pool/.aspnet/DataProtection-Keys" 2>&1)" || fail "the pool stored no keys: $keys_before"
compose down > /dev/null 2>&1
started="$(compose up --detach 2>&1)" || fail "the services did not restart: $started"
wait_for_pool || fail "the pool did not come back after a restart"
keys_after="$(in_data_folder "ls $data/data/pool/.aspnet/DataProtection-Keys")"
[ "$keys_before" = "$keys_after" ] || fail "the pool's keys changed over a restart"
logs="$(compose logs pool 2>&1)"
grep --quiet --ignore-case "Database schema is up to date" <<< "$logs" || fail "the pool did not find its database after the restart"

echo "Smoke test passed"
