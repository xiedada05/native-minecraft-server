#!/usr/bin/env bash

set -o errexit
set -o nounset

# Automated PGO training: boots the instrumented binary in a throwaway world,
# generates load (fresh world generation, a hot tick sprint, console commands,
# optionally bot-client network traffic), and stops the server gracefully so
# the profile is flushed. Collects the profile into build/pgo/.
#
# Usage: scripts/train-pgo.sh [path-to-botmark-binary]

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
REPO_DIR=$( dirname "${SCRIPT_DIR}" )
BIN="${REPO_DIR}/build/native-minecraft-server-instrument"
PROFILES_DIR="${REPO_DIR}/build/pgo"

if [[ ! -x "${BIN}" ]]; then
    echo "No instrumented binary at ${BIN}."
    echo "Run 'PGO=instrument ./build.sh' first. Exiting..."
    exit 1
fi

TRAIN_DIR=$(mktemp -d "${REPO_DIR}/build/pgo-train.XXXXXX")
echo "eula=true" > "${TRAIN_DIR}/eula.txt"
# Dedicated port so the training server never collides with a real one.
printf 'sync-chunk-writes=false\nlevel-seed=0\nserver-port=25599\nquery.port=25599\n' > "${TRAIN_DIR}/server.properties"

cd "${TRAIN_DIR}"
mkfifo console.fifo
sleep infinity > console.fifo &
KEEP_OPEN=$!
trap 'kill "${KEEP_OPEN}" 2> /dev/null || true' EXIT

"${BIN}" nogui < console.fifo > server.log 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 120); do
    if ! kill -0 "${SERVER_PID}" 2> /dev/null; then
        echo "Server exited early:"
        tail -30 server.log
        exit 1
    fi
    if grep -q 'Done ([0-9.]*s)! For help, type "help"' server.log 2> /dev/null; then
        break
    fi
    sleep 5
done
echo "Booted. Generating training load..."

# Hot tick loop over the freshly generated world.
echo "tick sprint 2000" > console.fifo
sleep 45

# Console and persistence code paths.
for cmd in "list" "seed" "datapack list" "save-all" "whitelist list" "gamerule randomTickSpeed"; do
    echo "${cmd}" > console.fifo
    sleep 3
done

# Optional network-path training with a protocol bot client
# (e.g. Pumpkin-MC/BotMark). Vanilla's anti-cheat rejects bot movement and
# 26.3 chat signing rejects unsolicited bot chat, so rotation/swing only.
BOTMARK_BIN="${1:-${BOTMARK_BIN:-}}"
if [[ -n "${BOTMARK_BIN}" ]] && [[ -x "${BOTMARK_BIN}" ]]; then
    for count in 100 200; do
        echo "Training wave: ${count} bot clients (rotation/swing)..."
        timeout 120 "${BOTMARK_BIN}" --ip "127.0.0.1:25599" --count "${count}" --delay 50 \
            --enable-spam-message=false --enable-movement=false --enable-jumping=false \
            --enable-physics=false > /dev/null 2>&1 || true
        sleep 3
    done
else
    echo "No bot client configured (set BOTMARK_BIN for network-path training);"
    echo "profiling boot, world generation, tick loop and console paths only."
fi

sleep 5
echo "Stopping to flush profile..."
echo "stop" > console.fifo
wait "${SERVER_PID}" || true

mkdir -p "${PROFILES_DIR}"
STAMP=$(date +%Y%m%d-%H%M%S)
for profile in ./*.iprof; do
    if [[ -e "${profile}" ]]; then
        mv "${profile}" "${PROFILES_DIR}/train-${STAMP}-${RANDOM}.iprof"
    fi
done
if ! compgen -G "${PROFILES_DIR}/*.iprof" > /dev/null; then
    echo "No profile was written! Training failed."
    exit 1
fi
rm -rf "${TRAIN_DIR}"
ls -la "${PROFILES_DIR}"
echo "Training complete. Rebuild with: PGO=apply ./build.sh"
