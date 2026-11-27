#!/bin/bash
# Tests of entrypoint.sh with stubs of adb, usbreset and sleep: no device, no docker.
# The image paths (/opt/zebrunner, /tmp/zebrunner, appium node modules) are replaced with the test workspace.
# The entrypoint needs bash 4, on macOS use the bash of brew.
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

(("$(bash -c 'echo "${BASH_VERSINFO[0]}"')" >= 4)) || skip "requires bash 4 in PATH"

sed -e "s#/opt/zebrunner/#${REPO}/#g" -e "s#/root/.android/#${WORK}/android/#g" entrypoint.sh > "${WORK}/entrypoint.sh"

# the stubs read their behavior from the FAKE_* variables of the scenario
export FAKE_WORK="$WORK"
# usbreset: FAKE_USBRESET=fail can't reset the port
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub usbreset 'echo "usbreset|$*" >> "$FAKE_WORK/calls.log"
[[ "$FAKE_USBRESET" != fail ]]'
# sleep: the entrypoint holder sleeps 33 seconds between the device checks, after 20 of them the entrypoint is stopped
# as a scenario has to end with a state that ends the entrypoint; FAKE_STOP_SLEEP=1: that sleep goes on after the stop
# FAKE_SERVER=dies: the pause after the adb server start lets it exit, FAKE_SERVER=crash: the server stops before
# the second holder check, FAKE_SERVER=crash-on-boot: before the second boot check
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub sleep 'if [[ "$1" == 1 && "$FAKE_SERVER" == dies ]]; then
  /bin/sleep 0.5
elif [[ "$1" == 33 ]]; then
  n=$(cat "$FAKE_WORK/sleep33.n" 2> /dev/null || echo 0)
  echo $((n + 1)) > "$FAKE_WORK/sleep33.n"
  if [[ "$n" -ge 20 ]]; then
    kill -TERM "$PPID"
    [[ "$FAKE_STOP_SLEEP" == 1 ]] && exec /bin/sleep 30
  fi
  if [[ "$FAKE_SERVER" == crash ]]; then
    touch "$FAKE_WORK/server.stop"
    /bin/sleep 0.5
  fi
fi
exit 0'
# adb: every call is logged, the server port (ANDROID_ADB_SERVER_PORT) of the client calls too;
# the server runs until the entrypoint exits (FAKE_SERVER=dies: it exits at once, server.stop file: it stops);
# FAKE_CONNECT=ok|fail|flaky (FAKE_CONNECT_FAILS failed attempts first) is the result of 'adb connect',
# FAKE_DEVICE_STATE the state of the connected device in 'adb devices', FAKE_OTHER_DEVICE one more device there,
# FAKE_BOOT=ok|never|late (FAKE_BOOT_FAILS empty answers first) the answer of 'adb shell dumpsys display',
# FAKE_SERVER=crash-on-boot stops the server on the first boot check,
# FAKE_STATES the ';' separated answers of 'adb get-state', the last one is repeated;
# 'adb reboot' (counted in reboot.n) by FAKE_REBOOT: gone (the device disconnects), boot (it stays connected with a new
# boot id), noop (nothing happens, it stays in the 'device' state), once (the first one is a noop);
# FAKE_BOOT_ID=none: the boot id is not readable
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub adb 'echo "adb|$*" >> "$FAKE_WORK/calls.log"
# the adb server of the host (-H): FAKE_TRANSPORT_STATES the ";" separated answers of get-state, the last one is
# repeated, FAKE_TCP_PORT the tcp port of adbd, FAKE_FORWARD=fail can not forward
if [[ "$1" == -H ]]; then
  shift 6
  case "$1" in
    get-state)
      n=$(cat "$FAKE_WORK/transport.n" 2> /dev/null || echo 0)
      echo $((n + 1)) > "$FAKE_WORK/transport.n"
      IFS=";" read -r -a states <<< "$FAKE_TRANSPORT_STATES"
      [[ "$n" -ge "${#states[@]}" ]] && n=$((${#states[@]} - 1))
      echo "${states[$n]}" ;;
    shell) echo "${FAKE_TCP_PORT}" ;;
    forward) [[ "$FAKE_FORWARD" == fail ]] && { echo "error: cannot bind listener"; exit 1; } ;;
  esac
  exit 0
fi
if [[ "$*" == *" server "* ]]; then
  [[ "$FAKE_SERVER" == dies ]] && exit 1
  trap "echo \"adb|server-stopped\" >> \"$FAKE_WORK/calls.log\"; exit 0" TERM
  exec > /dev/null 2>&1
  while kill -0 "$PPID" 2> /dev/null && [[ ! -e "$FAKE_WORK/server.stop" ]]; do /bin/sleep 0.1; done
  exit 0
fi
echo "${ANDROID_ADB_SERVER_PORT:-unset}" >> "$FAKE_WORK/ports.log"
reboots=$(cat "$FAKE_WORK/reboot.n" 2> /dev/null || echo 0)
rebooted=""
case "$FAKE_REBOOT" in
  noop) ;;
  once) [[ "$reboots" -ge 2 ]] && rebooted="gone" ;;
  *) [[ "$reboots" -ge 1 ]] && rebooted="$FAKE_REBOOT" ;;
esac
counter() {
  local n
  n=$(cat "$FAKE_WORK/$1.n" 2> /dev/null || echo 0)
  echo $((n + 1)) > "$FAKE_WORK/$1.n"
  echo "$n"
}
case "$1" in
  connect)
    n=$(counter connect)
    if [[ "$FAKE_CONNECT" == fail || ("$FAKE_CONNECT" == flaky && "$n" -lt "$FAKE_CONNECT_FAILS") ]]; then
      echo "failed to connect to $2"
    else
      touch "$FAKE_WORK/connected"
      echo "connected to $2"
    fi ;;
  devices)
    echo "List of devices attached"
    [[ -n "$FAKE_OTHER_DEVICE" ]] && printf "%s\tdevice\n" "$FAKE_OTHER_DEVICE"
    [[ -e "$FAKE_WORK/connected" ]] && printf "%s\t%s\n" "$ANDROID_DEVICE" "$FAKE_DEVICE_STATE" ;;
  reboot) echo $((reboots + 1)) > "$FAKE_WORK/reboot.n" ;;
  shell)
    case "$*" in
      *boot_id*)
        [[ "$FAKE_BOOT_ID" == none ]] && exit 0
        if [[ "$rebooted" == boot ]]; then
          echo "6f1c2a9e-0b7d-4c55-9a3e-2d8f4b6c1e70"
        else
          echo "0c9d7e21-5a4b-4f3c-8e2d-1b6a9f0e3d42"
        fi ;;
      *dumpsys\ display*)
        n=$(counter boot)
        if [[ "$FAKE_SERVER" == crash-on-boot ]]; then
          touch "$FAKE_WORK/server.stop"
          /bin/sleep 0.5
        fi
        if [[ "$FAKE_BOOT" == never || ("$FAKE_BOOT" == late && "$n" -lt "$FAKE_BOOT_FAILS") ]]; then
          exit 1
        fi
        echo "  DisplayDeviceInfo{\"Built-in Screen\": 1080 x 1920, 60.0 fps}" ;;
      *df\ -h*) echo "Filesystem      Size  Used Avail Use% Mounted on" ;;
      # FAKE_UIDS=none: the log of the device tells that an app got no UID
      *logcat*"valid UID"*)
        [[ "$FAKE_UIDS" == none ]] &&
          echo "E PackageManager: Package jp.co.cyberagent.stf could not be assigned a valid UID" ;;
    esac ;;
  get-state)
    [[ "$rebooted" == gone ]] && { echo "error: no devices/emulators found"; exit 1; }
    [[ "$reboots" -ge 1 ]] && { echo device; exit 0; }
    n=$(counter state)
    IFS=";" read -r -a states <<< "$FAKE_STATES"
    [[ "$n" -ge "${#states[@]}" ]] && n=$((${#states[@]} - 1))
    echo "${states[$n]}" ;;
  install) echo "Success" ;;
  get-serialno) echo "R28M:1384" ;;
esac
exit 0'

# scenario <name>: a fresh state, a booted USB device that becomes unauthorized after the first holder check by default
scenario() {
  rm -rf "${WORK}"/*.n "${WORK}/connected" "${WORK}/ports.log" "${WORK}/server.stop" "${WORK}/node_modules" "${WORK}/zebrunner"
  reset_calls
  FAKE_CONNECT=ok
  FAKE_CONNECT_FAILS=0
  FAKE_DEVICE_STATE=device
  FAKE_OTHER_DEVICE=''
  FAKE_BOOT=ok
  FAKE_BOOT_FAILS=0
  FAKE_STATES="device;unauthorized"
  FAKE_USBRESET=ok
  FAKE_SERVER=ok
  FAKE_TRANSPORT_STATES=device
  FAKE_TCP_PORT=''
  FAKE_FORWARD=ok
  FAKE_STOP_SLEEP=0
  FAKE_UIDS=ok
  FAKE_REBOOT=gone
  FAKE_BOOT_ID=ok
  export FAKE_REBOOT FAKE_BOOT_ID FAKE_UIDS FAKE_STOP_SLEEP FAKE_TRANSPORT_STATES FAKE_TCP_PORT FAKE_FORWARD
  export FAKE_SERVER FAKE_CONNECT FAKE_CONNECT_FAILS FAKE_DEVICE_STATE FAKE_OTHER_DEVICE FAKE_BOOT FAKE_BOOT_FAILS FAKE_STATES FAKE_USBRESET
  export ANDROID_DEVICE='' DEVICE_BUS=/dev/bus/usb/001/002 ADB_PORT=5037 ADB_POLLING_SEC=0 LOGGER_LEVEL=DEBUG
  unset DEBUG VERBOSE ANDROID_ADB_SERVER_PORT ADB_TRANSPORT_SERVER ADB_TRANSPORT_SERIAL ADB_TRANSPORT_PORT
  unset ALLOW_REBOOT REBOOT_INTERVAL REBOOT_CONFIRM_TIMEOUT
}

# run_entrypoint: output of the entrypoint in $OUT, its exit status in $STATUS
run_entrypoint() {
  OUT="$(PATH="${WORK}/bin:${PATH}" bash "${WORK}/entrypoint.sh" 2>&1)"
  STATUS=$?
}

# count <pattern> <text>: the number of the lines of the text matching the pattern
count() {
  grep -c -- "$1" <<< "$2" || true
}

section "configuration"
for var in ADB_PORT ADB_POLLING_SEC; do
  for value in "" abc -1 1.5 "1 2"; do
    scenario
    export "${var}=${value}"
    run_entrypoint
    check_contains "${var}='${value}' is reported" "${var} must be a non-negative integer, but it is '${value}'." "$OUT"
    check "${var}='${value}' exits with 0" "0" "$STATUS"
  done
done

scenario
ADB_PORT=abc
ADB_POLLING_SEC=xyz
run_entrypoint
check_contains "every invalid variable is reported: first" "ADB_PORT must be" "$OUT"
check_contains "every invalid variable is reported: second" "ADB_POLLING_SEC must be" "$OUT"
check_contains "invalid configuration is reported" "Invalid configuration. Exiting!" "$OUT"
check "nothing is started with invalid configuration" "" "$(calls adb)$(calls usbreset)"

section "DEBUG and VERBOSE"
scenario
ADB_PORT=abc
DEBUG=true
DEBUG_TIMEOUT=0
export DEBUG DEBUG_TIMEOUT
run_entrypoint
check_contains "DEBUG banner" "DEBUG mode is on!" "$OUT"
check_contains "exit of the entrypoint is intercepted" "Exit attempt intercepted." "$OUT"
check "exit status is kept in the DEBUG mode" "0" "$STATUS"

scenario
ADB_PORT=abc
VERBOSE=true
export VERBOSE
run_entrypoint
check_contains "VERBOSE banner" "VERBOSE mode is on!" "$OUT"
check_contains "entrypoint commands are traced" "+ isConfigValid=1" "$OUT"

scenario
LOGGER_LEVEL=ERROR
ADB_PORT=abc
run_entrypoint
check_contains "ERROR level shows errors" "[ERROR] ADB_PORT must be" "$OUT"
check_not_contains "ERROR level hides info" "[INFO]" "$OUT"

section "adb server"
scenario
run_entrypoint
check_contains "banner" $'\xe2\x94\x81\xe2\x94\x81 mcloud-android-connector ' "$OUT"
check "adb server allows remote access on its port" "-a -P 5037 server nodaemon" "$(calls adb | grep ' server ')"
check "adb clients use the server port" "5037" "$(sort -u "${WORK}/ports.log" | tr '\n' ' ' | sed 's/ $//')"

scenario
ADB_PORT=5038
run_entrypoint
check "adb server uses ADB_PORT" "-a -P 5038 server nodaemon" "$(calls adb | grep ' server ')"
check "adb clients use ADB_PORT" "5038" "$(sort -u "${WORK}/ports.log" | tr '\n' ' ' | sed 's/ $//')"

scenario
FAKE_SERVER=dies
run_entrypoint
check_contains "adb server that can't start is reported" "Adb server is not running. Restarting!" "$OUT"
check "adb server that can't start exits with 1" "1" "$STATUS"
check_not_contains "the device is not checked without the adb server" "dumpsys" "$(calls adb)"

scenario
FAKE_SERVER=crash
FAKE_STATES="device"
run_entrypoint
check "the device is checked while the adb server runs" "1" "$(count 'Device connected successfully.' "$OUT")"
check_contains "stopped adb server is reported" "Adb server is not running. Restarting!" "$OUT"
check "stopped adb server exits with 1" "1" "$STATUS"

scenario
FAKE_SERVER=crash-on-boot
FAKE_BOOT=never
run_entrypoint
check "the boot wait ends when the adb server stops" "1" "$(cat "${WORK}/boot.n")"
check_contains "adb server stopped during the boot wait is reported" "Adb server is not running. Restarting!" "$OUT"
check "adb server stopped during the boot wait exits with 1" "1" "$STATUS"

section "USB device"
scenario
run_entrypoint
check_not_contains "USB device is not connected over the network" "connect" "$(calls adb)"
check_contains "booted device is detected" "DisplayDeviceInfo" "$OUT"
check "boot is checked once" "1" "$(cat "${WORK}/boot.n")"
check_contains "filesystem usage is printed" "shell df -h" "$(calls adb)"
check_contains "device is available" "Device is fully available." "$OUT"

section "remote device"
scenario
ANDROID_DEVICE=192.168.0.10:5555
run_entrypoint
check "remote device is connected" "connect 192.168.0.10:5555" "$(calls adb | grep '^connect')"
check_contains "connected remote device is reported" "Connected: 192.168.0.10:5555" "$OUT"
check_contains "connected remote device goes on" "Device is fully available." "$OUT"

scenario
ANDROID_DEVICE=192.168.0.10:5555
FAKE_CONNECT=flaky
FAKE_CONNECT_FAILS=2
run_entrypoint
check "remote device is connected until it answers" "3" "$(cat "${WORK}/connect.n")"
check_contains "late remote device goes on" "Device is fully available." "$OUT"

scenario
ANDROID_DEVICE=192.168.0.10:5555
FAKE_CONNECT=fail
run_entrypoint
check "unreachable remote device is retried 10 times" "10" "$(cat "${WORK}/connect.n")"
check_contains "unreachable remote device is reported" "Device 192.168.0.10:5555 is not connected!" "$OUT"
check "unreachable remote device exits with 1" "1" "$STATUS"
check_not_contains "boot is not checked without connection" "dumpsys" "$(calls adb)"

for state in offline unauthorized authorizing; do
  scenario
  ANDROID_DEVICE=device:5555
  FAKE_DEVICE_STATE=$state
  run_entrypoint
  check "${state} device:5555 is not connected" "10" "$(cat "${WORK}/connect.n")"
  check_not_contains "${state} device:5555 is not reported as connected" "Connected: device:5555" "$OUT"
  check "${state} device:5555 exits with 1" "1" "$STATUS"
done

scenario
ANDROID_DEVICE=192.168.0.10:5555
FAKE_DEVICE_STATE=offline
FAKE_OTHER_DEVICE=192.168.0.10:55555
run_entrypoint
check_not_contains "another device with the same serial prefix is not the remote device" "Connected: 192.168.0.10:5555" "$OUT"
check "remote device with the same serial prefix exits with 1" "1" "$STATUS"

section "USB device of the adb server of the host"
scenario
export ADB_TRANSPORT_SERVER=host.docker.internal:5037 ADB_TRANSPORT_SERIAL=R28M1384YQY ADB_TRANSPORT_PORT=7422
run_entrypoint
check_contains "the device is awaited on the host server" "adb|-H host.docker.internal -P 5037 -s R28M1384YQY get-state" "$(cat "${WORK}/calls.log")"
check_contains "adbd of the device is switched to tcp" "-s R28M1384YQY tcpip 5555" "$(calls adb)"
check_contains "the host server forwards the port to adbd" "-s R28M1384YQY forward tcp:7422 tcp:5555" "$(calls adb)"
check_contains "the forwarded port is connected" "connect host.docker.internal:7422" "$(calls adb)"
check_contains "the forwarded device is reported" "The device is forwarded by the adb server of the host to host.docker.internal:7422." "$OUT"
check_contains "the forwarded device boots" "DisplayDeviceInfo" "$OUT"

scenario
export ADB_TRANSPORT_SERVER=host.docker.internal:5037 ADB_TRANSPORT_SERIAL=R28M1384YQY ADB_TRANSPORT_PORT=7422
FAKE_TCP_PORT=5555
run_entrypoint
check_not_contains "adbd already on tcp is not switched again" "tcpip" "$(calls adb)"
check_contains "adbd already on tcp is forwarded" "forward tcp:7422 tcp:5555" "$(calls adb)"

scenario
export ADB_TRANSPORT_SERVER=host.docker.internal:5037 ADB_TRANSPORT_SERIAL=R28M1384YQY
FAKE_TRANSPORT_STATES="error: device 'R28M1384YQY' not found;error: device 'R28M1384YQY' not found;device"
FAKE_TCP_PORT=5555
run_entrypoint
check "the device is polled on the host server until it appears" "3" "$(cat "${WORK}/transport.n")"
check_contains "the default port is forwarded" "forward tcp:5555 tcp:5555" "$(calls adb)"

scenario
export ADB_TRANSPORT_SERVER=host.docker.internal:5037 ADB_TRANSPORT_SERIAL=R28M1384YQY
FAKE_TRANSPORT_STATES="error: device 'R28M1384YQY' not found"
run_entrypoint
check_contains "missing device of the host server is reported" "is not found on the adb server host.docker.internal:5037. Restarting!" "$OUT"
check "missing device of the host server is polled 10 times" "10" "$(cat "${WORK}/transport.n")"
check "missing device of the host server exits with 1" "1" "$STATUS"
check_not_contains "missing device of the host server is not connected" "connect" "$(calls adb)"

scenario
export ADB_TRANSPORT_SERVER=host.docker.internal:5037 ADB_TRANSPORT_SERIAL=R28M1384YQY
FAKE_TRANSPORT_STATES=unauthorized
run_entrypoint
check_contains "unauthorized host server is reported" "Authorize the adb server of the host on the device manually!" "$OUT"
check "unauthorized host server exits with 0" "0" "$STATUS"

scenario
export ADB_TRANSPORT_SERVER=host.docker.internal:5037 ADB_TRANSPORT_SERIAL=R28M1384YQY
FAKE_FORWARD=fail
run_entrypoint
check_contains "failed forward is reported" "can't forward the port 5555. Restarting!" "$OUT"
check "failed forward exits with 1" "1" "$STATUS"

for value in host.docker.internal "host:port" ":5037"; do
  scenario
  export ADB_TRANSPORT_SERVER="$value" ADB_TRANSPORT_SERIAL=R28M1384YQY
  run_entrypoint
  check_contains "ADB_TRANSPORT_SERVER='${value}' is reported" "ADB_TRANSPORT_SERVER must be <host>:<port>, but it is '${value}'." "$OUT"
  check "ADB_TRANSPORT_SERVER='${value}' exits with 0" "0" "$STATUS"
done

scenario
export ADB_TRANSPORT_SERVER=host.docker.internal:5037 ADB_TRANSPORT_SERIAL=''
run_entrypoint
check_contains "the serial is required with the host server" "ADB_TRANSPORT_SERIAL is required with ADB_TRANSPORT_SERVER." "$OUT"

scenario
export ADB_TRANSPORT_SERVER=host.docker.internal:5037 ADB_TRANSPORT_SERIAL=R28M1384YQY ADB_TRANSPORT_PORT=abc
run_entrypoint
check_contains "invalid ADB_TRANSPORT_PORT is reported" "ADB_TRANSPORT_PORT must be a non-negative integer, but it is 'abc'." "$OUT"

scenario
export ADB_TRANSPORT_PORT=abc
FAKE_STATES="unauthorized"
run_entrypoint
check_not_contains "ADB_TRANSPORT_PORT is not validated without the host server" "ADB_TRANSPORT_PORT must be" "$OUT"

section "boot"
scenario
FAKE_BOOT=late
FAKE_BOOT_FAILS=3
run_entrypoint
check "boot is checked until the display answers" "4" "$(cat "${WORK}/boot.n")"
check_contains "late boot goes on" "Device is fully available." "$OUT"

scenario
FAKE_BOOT=never
run_entrypoint
check "boot is checked 60 times" "60" "$(cat "${WORK}/boot.n")"
check_contains "not booted device is reported" "Potentially device is not fully booted yet!" "$OUT"
check "not booted device exits with 1" "1" "$STATUS"
check_not_contains "not booted device is not monitored" "get-state" "$(calls adb)"

section "holder"
scenario
FAKE_STATES="device;device;device;unauthorized"
run_entrypoint
check "available device is checked every 33 seconds" "3" "$(cat "${WORK}/sleep33.n")"
check "available device is reported on every check" "3" "$(count 'Device connected successfully.' "$OUT")"

scenario
run_entrypoint
check_contains "unauthorized device is reported" "Authorize device manually!" "$OUT"
check "unauthorized device exits with 0" "0" "$STATUS"

for state in authorizing connecting unknown bootloader; do
  scenario
  FAKE_STATES="${state};${state};device;unauthorized"
  run_entrypoint
  check "${state} is waited for" "2" "$(count 'Waiting for valid device state...' "$OUT")"
  check_contains "${state} goes on when the device is back" "Device connected successfully." "$OUT"
done

scenario
FAKE_STATES="authorizing"
run_entrypoint
check "temporary state is checked 10 times" "10" "$(cat "${WORK}/state.n")"
check_contains "endless temporary state is reported" "Retry limit reached. Exiting." "$OUT"
check "endless temporary state exits with 0" "0" "$STATUS"

scenario
FAKE_STATES="device;offline;device;unauthorized"
run_entrypoint
check_contains "offline device is reported" "Device is offline, performing adb reconnect." "$OUT"
check "offline device is reconnected" "reconnect" "$(calls adb | grep '^reconnect')"
check "reconnected device is monitored" "2" "$(count 'Device connected successfully.' "$OUT")"

scenario
FAKE_STATES="device;offline"
run_entrypoint
check "offline device is reconnected on every check" "10" "$(calls adb | grep -c '^reconnect')"
check_contains "device staying offline is reported" "Device is still offline or lost after the reconnects, restarting container." "$OUT"
check "device staying offline exits with 1" "1" "$STATUS"

scenario
FAKE_STATES="device;error: no devices/emulators found"
run_entrypoint
check "USB device staying lost after the resets exits with 1" "1" "$STATUS"

scenario
ANDROID_DEVICE=192.168.0.10:5555
FAKE_STATES="device;error: no devices/emulators found"
run_entrypoint
check_contains "lost remote device is reported" "Remote device is not found, restarting container." "$OUT"
check "lost remote device exits with 1" "1" "$STATUS"
check "lost remote device has no usb reset" "" "$(calls usbreset)"

scenario
FAKE_STATES="device;error: no devices/emulators found;device;unauthorized"
run_entrypoint
check "lost USB device resets its port" "/dev/bus/usb/001/002" "$(calls usbreset)"
check "reset USB device is monitored" "2" "$(count 'Device connected successfully.' "$OUT")"

scenario
FAKE_STATES="error: no devices/emulators found"
FAKE_USBRESET=fail
run_entrypoint
check "lost USB device without reset exits with 1" "1" "$STATUS"
check "lost USB device without reset is not retried" "1" "$(cat "${WORK}/state.n")"

for state in recovery rescue sideload host "error: insufficient permissions for device"; do
  scenario
  FAKE_STATES="$state"
  run_entrypoint
  check_contains "'${state}' asks for troubleshooting" "Troubleshoot device manually to define the best strategy." "$OUT"
  check "'${state}' exits with 0" "0" "$STATUS"
done

section "no free app UIDs"
lastReboot="${WORK}/android/reboot/R28M_1384"
rm -rf "${WORK}/android"
scenario
FAKE_UIDS=none
FAKE_STATES=device
run_entrypoint
check_contains "no free app UIDs are reported" "The device has no free app UIDs, apps can't be installed (STFService of STF): E PackageManager: Package jp.co.cyberagent.stf could not be assigned a valid UID" "$OUT"
check_contains "without ALLOW_REBOOT the reboot is recommended" "Device reboot is recommended (ALLOW_REBOOT=true reboots it)!" "$OUT"
check "without ALLOW_REBOOT the device is not rebooted" "0" "$(count '^reboot' "$(calls adb)")"
check "the report is once per start" "1" "$(count "has no free app UIDs" "$OUT")"
check "the log of the device is not read again after the report" "1" "$(count 'logcat' "$(calls adb)")"
check "without ALLOW_REBOOT the device keeps running until the stop" "0" "$STATUS"

scenario
FAKE_UIDS=none
export ALLOW_REBOOT=true
run_entrypoint
check "ALLOW_REBOOT reboots the device" "1" "$(count '^reboot$' "$(calls adb)")"
check_contains "the reboot is reported" "Rebooting the device to free the app UIDs!" "$OUT"
check "the reboot restarts the container" "1" "$STATUS"
check "the time of the reboot is kept in the volume of the adb key" "true" \
  "$([[ "$(cat "$lastReboot" 2> /dev/null)" =~ ^[0-9]+$ ]] && echo true || echo false)"

scenario
FAKE_UIDS=none
FAKE_STATES=device
export ALLOW_REBOOT=TRUE
run_entrypoint
check "no second reboot within REBOOT_INTERVAL" "0" "$(count '^reboot' "$(calls adb)")"
check_contains "no free app UIDs within REBOOT_INTERVAL after the reboot need a person" "seconds after its reboot (one per REBOOT_INTERVAL 21600 seconds): the device needs a person." "$OUT"
check "the device keeps running within REBOOT_INTERVAL" "0" "$STATUS"

scenario
FAKE_UIDS=none
export ALLOW_REBOOT=true REBOOT_INTERVAL=3600
echo $(($(date +%s) - 4000)) > "$lastReboot"
run_entrypoint
check "a reboot older than REBOOT_INTERVAL allows another one" "1" "$(count '^reboot$' "$(calls adb)")"

section "no free app UIDs: the reboot is confirmed"
# reboot_scenario: no free app UIDs at the first device check, ALLOW_REBOOT=true and no earlier reboot
reboot_scenario() {
  rm -rf "${WORK}/android"
  scenario
  FAKE_UIDS=none
  FAKE_STATES=device
  export ALLOW_REBOOT=true REBOOT_CONFIRM_TIMEOUT=6
}

reboot_scenario
run_entrypoint
check_contains "the reboot is confirmed when the device disconnects" "The device is rebooting: it disconnected 0 seconds after 'adb reboot' (error: no devices/emulators found)." "$OUT"
check "the boot id is read before the reboot" "true" "$([[ "$(count 'boot_id' "$(calls adb)")" -ge 1 ]] && echo true || echo false)"
check "a confirmed reboot is recorded" "true" "$([[ "$(cat "$lastReboot" 2> /dev/null)" =~ ^[0-9]+$ ]] && echo true || echo false)"
check "a confirmed reboot restarts the container" "1" "$STATUS"

reboot_scenario
FAKE_REBOOT=once
run_entrypoint
check "'adb reboot' without a reboot is asked once more" "2" "$(count '^reboot$' "$(calls adb)")"
check_contains "the first 'adb reboot' without a reboot is reported" "'adb reboot' returned, but the device did not reboot within 6 seconds: it is still connected and its boot id is the same." "$OUT"
check_contains "the second attempt is reported" "Rebooting the device: 'adb reboot' (attempt 2/2)." "$OUT"
check "the reboot confirmed by the second attempt is recorded" "true" "$([[ -e "$lastReboot" ]] && echo true || echo false)"
check "the reboot confirmed by the second attempt restarts the container" "1" "$STATUS"

reboot_scenario
FAKE_REBOOT=boot
run_entrypoint
check_contains "the reboot is confirmed by a new boot id" "The device is rebooting: its boot id changed 0 seconds after 'adb reboot'." "$OUT"
check "the reboot confirmed by the boot id is recorded" "true" "$([[ -e "$lastReboot" ]] && echo true || echo false)"

reboot_scenario
FAKE_REBOOT=noop
run_entrypoint
check "a device that does not reboot gets 2 'adb reboot'" "2" "$(count '^reboot$' "$(calls adb)")"
check_contains "a device that does not reboot needs a person" "The device did not reboot on 'adb reboot' (2 attempts): the device needs a person, reboot it by hand." "$OUT"
check "a reboot that did not happen is not recorded for REBOOT_INTERVAL" "false" "$([[ -e "$lastReboot" ]] && echo true || echo false)"
check "a device that does not reboot keeps running (adb, Appium) until the stop" "0" "$STATUS"
check_contains "a device that does not reboot is still checked" "Device connected successfully." "$(tail -n 5 <<< "$OUT")"
check_not_contains "a reboot that did not happen is not reported as a reboot" "The device is rebooting" "$OUT"

reboot_scenario
FAKE_REBOOT=boot
FAKE_BOOT_ID=none
run_entrypoint
check "without the boot id a device that stays connected is not confirmed" "2" "$(count '^reboot$' "$(calls adb)")"
check "without the boot id nothing is recorded" "false" "$([[ -e "$lastReboot" ]] && echo true || echo false)"

scenario
export ALLOW_REBOOT=true
FAKE_STATES=device
run_entrypoint
check "free app UIDs: no reboot" "0" "$(count '^reboot' "$(calls adb)")"
check_not_contains "free app UIDs: nothing is reported" "app UIDs" "$OUT"
check "free app UIDs: the log of the device is checked at every device check" "true" \
  "$([[ "$(count 'logcat' "$(calls adb)")" -gt 1 ]] && echo true || echo false)"

for value in maybe 1; do
  scenario
  export ALLOW_REBOOT="$value"
  run_entrypoint
  check_contains "ALLOW_REBOOT='${value}' is reported" "ALLOW_REBOOT must be true or false, but it is '${value}'." "$OUT"
  check "ALLOW_REBOOT='${value}' exits with 0" "0" "$STATUS"
done
for var in REBOOT_INTERVAL REBOOT_CONFIRM_TIMEOUT; do
  scenario
  export "${var}=abc"
  run_entrypoint
  check_contains "${var}='abc' is reported" "${var} must be a non-negative integer, but it is 'abc'." "$OUT"
done

section "stop"
scenario
FAKE_STATES=device
FAKE_STOP_SLEEP=1
started="$SECONDS"
run_entrypoint
check "SIGTERM ends the entrypoint with 0" "0" "$STATUS"
check "SIGTERM ends the pause of the holder at once" "true" "$([[ $((SECONDS - started)) -lt 10 ]] && echo true || echo false)"
check_contains "the stop is logged" "Stopped. Exiting!" "$OUT"
/bin/sleep 0.3
check "the adb server is stopped" "server-stopped" "$(calls adb | grep -x server-stopped)"

finish
