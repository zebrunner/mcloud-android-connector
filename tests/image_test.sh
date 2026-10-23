#!/bin/bash
# Checks of the docker image: build, contents and the entrypoint startup without a device.
# IMAGE overrides the tag of the tested image (it is built when missing, REBUILD=true builds it anyway),
# PLATFORM its platform (the image is amd64 only: adb and usbreset are amd64 binaries).
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

IMAGE="${IMAGE:-mcloud-android-connector:test}"
PLATFORM="${PLATFORM:-linux/amd64}"

PREFIX="mcloud-android-connector-test-$$"

require_cmd docker
docker info > /dev/null 2>&1 || skip "requires a running docker daemon"

# cleanup: removes the container of the adb server checks
# called by the EXIT trap of lib.sh
# shellcheck disable=SC2329
cleanup() {
  docker rm --force "${PREFIX}-server" > /dev/null 2>&1
}

# in_image <command...>: runs the command in a new container of the image instead of the entrypoint
in_image() {
  docker run --rm --platform "$PLATFORM" --entrypoint "$1" "$IMAGE" "${@:2}" 2>&1
}

# run_image <docker run options...>: the output of the entrypoint in $OUT, its exit status in $STATUS
run_image() {
  OUT="$(docker run --rm --platform "$PLATFORM" "$@" "$IMAGE" 2>&1)"
  STATUS=$?
}

section "build"
if [[ "${REBUILD:-false}" != "true" ]] && docker image inspect "$IMAGE" > /dev/null 2>&1; then
  skip_check "image builds" "$IMAGE exists, REBUILD=true builds it again"
elif docker build --progress=plain --platform "$PLATFORM" --provenance=false --tag "$IMAGE" . > "${WORK}/build.log" 2>&1; then
  pass "image builds"
else
  fail "image builds" "docker build failed" "$(tail -100 "${WORK}/build.log")"
  finish
fi

section "contents"
check_contains "adb works" "Version 37.0.1" "$(in_image adb version)"
for file in /opt/zebrunner/entrypoint.sh /opt/zebrunner/util/logger.sh /opt/zebrunner/util/debug.sh /usr/local/bin/adb /usr/local/bin/usbreset; do
  if in_image test -x "$file" > /dev/null; then
    pass "${file} is executable"
  else
    fail "${file} is executable" "not executable" "$(in_image ls -l "$file")"
  fi
done
check_contains "libc++ of adb is next to it" "/usr/local/bin/libc++.so" "$(in_image ls /usr/local/bin/libc++.so)"
check_contains "usbreset works" "Usage:" "$(in_image usbreset)"
check_not_contains "the downloads are removed" "platform-tools" "$(in_image ls /tmp)"

section "pinned versions"
# the packages of the 'apk add' command are name=version
installed="$(in_image apk list --installed)"
packages="$(awk '/apk add --no-cache/ { found = 1 } found { print } found && !/\\$/ { exit }' Dockerfile |
  grep -oE '[a-z0-9][a-z0-9.+_-]*=[^ \\]+')"
for package in $packages; do
  check_contains "${package%%=*} ${package#*=} is installed" "${package%%=*}-${package#*=} " "$installed"
done

section "configuration"
config="$(docker image inspect "$IMAGE" --format '{{json .Config}}')"
check_contains "entrypoint" '"Entrypoint":["/opt/zebrunner/entrypoint.sh"]' "$config"
# the literal text of the image configuration
# shellcheck disable=SC2016
check_contains "healthcheck checks the device state on ADB_PORT" 'adb -P \"${ADB_PORT}\" get-state' "$config"
for env in ANDROID_DEVICE= DEVICE_BUS= ADB_PORT=5037 ADB_POLLING_SEC=5 LOGGER_LEVEL=INFO DEBUG=false DEBUG_TIMEOUT=3600 VERBOSE=false \
  ADB_TRANSPORT_SERVER= ADB_TRANSPORT_SERIAL= ADB_TRANSPORT_PORT=5555; do
  check_contains "default ${env}" "\"${env}\"" "$config"
done

section "startup"
# the unreachable remote device is retried 10 times, then the entrypoint asks for a restart
run_image --env ANDROID_DEVICE=127.0.0.1:1 --env ADB_POLLING_SEC=0 --env ADB_PORT=5038
check_contains "banner" "MCLOUD-ANDROID-CONNECTOR" "$OUT"
check_contains "the adb server answers on ADB_PORT" "failed to connect to" "$OUT"
check_not_contains "the adb clients do not start another server" "daemon not running" "$OUT"
check_contains "unreachable remote device is reported" "Device 127.0.0.1:1 is not connected!" "$OUT"
check "unreachable remote device exits with 1" "1" "$STATUS"

# without a USB device the boot wait ends after its retries
run_image --env ADB_POLLING_SEC=0
check_contains "missing USB device is reported" "Potentially device is not fully booted yet!" "$OUT"
check "missing USB device exits with 1" "1" "$STATUS"

# the adb clients would start a server without remote access, so a stopped adb server ends the entrypoint
docker run --detach --name "${PREFIX}-server" --platform "$PLATFORM" --env ANDROID_DEVICE=127.0.0.1:1 \
  --env ADB_POLLING_SEC=3 "$IMAGE" > /dev/null
sleep 5
docker exec "${PREFIX}-server" pkill -f 'server nodaemon'
STATUS="$(docker wait "${PREFIX}-server")"
OUT="$(docker logs "${PREFIX}-server" 2>&1)"
check_contains "stopped adb server is reported" "Adb server is not running. Restarting!" "$OUT"
check_not_contains "stopped adb server ends the connect retries" "is not connected!" "$OUT"
check "stopped adb server exits with 1" "1" "$STATUS"

section "configuration validation"
run_image --env ADB_PORT=abc
check_contains "invalid ADB_PORT is reported" "ADB_PORT must be a non-negative integer, but it is 'abc'." "$OUT"
check_contains "invalid configuration ends the entrypoint" "Invalid configuration. Exiting!" "$OUT"
run_image --env ADB_TRANSPORT_SERVER=host.docker.internal
check_contains "invalid ADB_TRANSPORT_SERVER is reported" "ADB_TRANSPORT_SERVER must be <host>:<port>" "$OUT"
check "invalid configuration exits with 0" "0" "$STATUS"

finish
