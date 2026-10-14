#!/bin/bash
# Tests of entrypoint.sh with stubs of adb, usbreset and sleep: no device, no docker.
# The image paths (/opt/zebrunner, /tmp/zebrunner, appium node modules) are replaced with the test workspace.
# The entrypoint needs bash 4, on macOS use the bash of brew.
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

(("$(bash -c 'echo "${BASH_VERSINFO[0]}"')" >= 4)) || skip "requires bash 4 in PATH"

sed -e "s#/opt/zebrunner/#${REPO}/#g" -e "s#/tmp/zebrunner/#${WORK}/zebrunner/#g" \
  -e "s#/usr/lib/node_modules/#${WORK}/node_modules/#g" entrypoint.sh > "${WORK}/entrypoint.sh"
SETTINGS_APK="${WORK}/node_modules/appium/node_modules/appium-uiautomator2-driver/node_modules/io.appium.settings/apks/settings_apk-debug.apk"
CHROME_APK="${WORK}/zebrunner/chrome/latest.apk"

# the stubs read their behavior from the FAKE_* variables of the scenario
export FAKE_WORK="$WORK"
# usbreset: FAKE_USBRESET=fail can't reset the port
stub usbreset 'echo "usbreset|$*" >> "$FAKE_WORK/calls.log"
[[ "$FAKE_USBRESET" != fail ]]'
# sleep: the entrypoint holder sleeps 33 seconds between the device checks, after 20 of them the entrypoint is stopped
# as a scenario has to end with a state that ends the entrypoint
stub sleep 'if [[ "$1" == 33 ]]; then
  n=$(cat "$FAKE_WORK/sleep33.n" 2> /dev/null || echo 0)
  echo $((n + 1)) > "$FAKE_WORK/sleep33.n"
  [[ "$n" -ge 20 ]] && kill -TERM "$PPID"
fi
exit 0'
# adb: every call is logged, the server port (ANDROID_ADB_SERVER_PORT) of the client calls too;
# FAKE_CONNECT=ok|fail|flaky (FAKE_CONNECT_FAILS failed attempts first) is the result of 'adb connect',
# FAKE_DEVICE_STATE the state of the connected device in 'adb devices', FAKE_OTHER_DEVICE one more device there,
# FAKE_BOOT=ok|never|late (FAKE_BOOT_FAILS empty answers first) the answer of 'adb shell dumpsys display',
# FAKE_STATES the ';' separated answers of 'adb get-state', the last one is repeated
stub adb 'echo "adb|$*" >> "$FAKE_WORK/calls.log"
[[ "$*" == *" server "* ]] || echo "${ANDROID_ADB_SERVER_PORT:-unset}" >> "$FAKE_WORK/ports.log"
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
  shell)
    case "$*" in
      *dumpsys\ display*)
        n=$(counter boot)
        if [[ "$FAKE_BOOT" == never || ("$FAKE_BOOT" == late && "$n" -lt "$FAKE_BOOT_FAILS") ]]; then
          exit 1
        fi
        echo "  DisplayDeviceInfo{\"Built-in Screen\": 1080 x 1920, 60.0 fps}" ;;
      *df\ -h*) echo "Filesystem      Size  Used Avail Use% Mounted on" ;;
    esac ;;
  get-state)
    n=$(counter state)
    IFS=";" read -r -a states <<< "$FAKE_STATES"
    [[ "$n" -ge "${#states[@]}" ]] && n=$((${#states[@]} - 1))
    echo "${states[$n]}" ;;
  install) echo "Success" ;;
esac
exit 0'

# scenario <name>: a fresh state, a booted USB device that becomes unauthorized after the first holder check by default
scenario() {
  rm -rf "${WORK}"/*.n "${WORK}/connected" "${WORK}/ports.log" "${WORK}/node_modules" "${WORK}/zebrunner"
  reset_calls
  FAKE_CONNECT=ok
  FAKE_CONNECT_FAILS=0
  FAKE_DEVICE_STATE=device
  FAKE_OTHER_DEVICE=''
  FAKE_BOOT=ok
  FAKE_BOOT_FAILS=0
  FAKE_STATES="device;unauthorized"
  FAKE_USBRESET=ok
  export FAKE_CONNECT FAKE_CONNECT_FAILS FAKE_DEVICE_STATE FAKE_OTHER_DEVICE FAKE_BOOT FAKE_BOOT_FAILS FAKE_STATES FAKE_USBRESET
  export ANDROID_DEVICE='' DEVICE_BUS=/dev/bus/usb/001/002 ADB_PORT=5037 ADB_POLLING_SEC=0 LOGGER_LEVEL=DEBUG
  unset DEBUG VERBOSE ANDROID_ADB_SERVER_PORT
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
check_contains "banner" "MCLOUD-ANDROID-CONNECTOR" "$OUT"
check "adb server allows remote access on its port" "-a -P 5037 server nodaemon" "$(calls adb | grep ' server ')"
check "adb clients use the server port" "5037" "$(sort -u "${WORK}/ports.log" | tr '\n' ' ' | sed 's/ $//')"

scenario
ADB_PORT=5038
run_entrypoint
check "adb server uses ADB_PORT" "-a -P 5038 server nodaemon" "$(calls adb | grep ' server ')"
check "adb clients use ADB_PORT" "5038" "$(sort -u "${WORK}/ports.log" | tr '\n' ' ' | sed 's/ $//')"

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
  check "${state} Redroid emulator is not connected" "10" "$(cat "${WORK}/connect.n")"
  check_not_contains "${state} Redroid emulator is not reported as connected" "Connected: device:5555" "$OUT"
  check "${state} Redroid emulator exits with 1" "1" "$STATUS"
done

scenario
ANDROID_DEVICE=192.168.0.10:5555
FAKE_DEVICE_STATE=offline
FAKE_OTHER_DEVICE=192.168.0.10:55555
run_entrypoint
check_not_contains "another device with the same serial prefix is not the remote device" "Connected: 192.168.0.10:5555" "$OUT"
check "remote device with the same serial prefix exits with 1" "1" "$STATUS"

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

section "Redroid emulator"
scenario
ANDROID_DEVICE=device:5555
mkdir -p "$(dirname "$SETTINGS_APK")" "$(dirname "$CHROME_APK")"
touch "$SETTINGS_APK" "$CHROME_APK"
run_entrypoint
check_contains "appium settings are installed" "install ${SETTINGS_APK}" "$(calls adb)"
check_contains "chrome is installed" "install ${CHROME_APK}" "$(calls adb)"

scenario
ANDROID_DEVICE=device:5555
run_entrypoint
check_not_contains "missing apks are not installed" "install" "$(calls adb)"
check_contains "emulator without apks goes on" "Device is fully available." "$OUT"

scenario
ANDROID_DEVICE=192.168.0.10:5555
mkdir -p "$(dirname "$SETTINGS_APK")" "$(dirname "$CHROME_APK")"
touch "$SETTINGS_APK" "$CHROME_APK"
run_entrypoint
check_not_contains "apks are installed on the emulator only" "install" "$(calls adb)"

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

finish
