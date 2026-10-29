#!/bin/bash

# shellcheck source=util/debug.sh
. /opt/zebrunner/util/debug.sh
# shellcheck source=util/logger.sh
. /opt/zebrunner/util/logger.sh

logger "INFO" "\n\n\n\t\tMCLOUD-ANDROID-CONNECTOR\n\n"

# the port of the host forwarded to adbd of the USB device of ADB_TRANSPORT_SERVER, 5555 like adbd itself by default
ADB_TRANSPORT_PORT="${ADB_TRANSPORT_PORT:-5555}"

#### Validate configuration
# A wrong configuration can't be fixed by a restart, so exit with 0 like the other unrecoverable errors
isConfigValid=1
numericVars=(ADB_PORT ADB_POLLING_SEC)
if [[ -n "$ADB_TRANSPORT_SERVER" ]]; then
  numericVars+=(ADB_TRANSPORT_PORT)
  if [[ ! "$ADB_TRANSPORT_SERVER" =~ ^[^:]+:[0-9]+$ ]]; then
    logger "ERROR" "ADB_TRANSPORT_SERVER must be <host>:<port>, but it is '${ADB_TRANSPORT_SERVER}'."
    isConfigValid=0
  fi
  if [[ -z "$ADB_TRANSPORT_SERIAL" ]]; then
    logger "ERROR" "ADB_TRANSPORT_SERIAL is required with ADB_TRANSPORT_SERVER."
    isConfigValid=0
  fi
fi
for var in "${numericVars[@]}"; do
  if [[ ! "${!var}" =~ ^[0-9]+$ ]]; then
    logger "ERROR" "$var must be a non-negative integer, but it is '${!var}'."
    isConfigValid=0
  fi
done
if [[ $isConfigValid -eq 0 ]]; then
  logger "ERROR" "Invalid configuration. Exiting!"
  exit 0
fi

#### Start ADB
# "-a" - allow remote access
# https://github.com/sorccu/docker-adb
adb -a -P "$ADB_PORT" server nodaemon &
adbServerPid=$!
# the adb client calls below use the same server port
export ANDROID_ADB_SERVER_PORT="$ADB_PORT"
sleep 1

# exitIfAdbServerStopped: without the server started above an adb client call starts a new server, but it listens
# on localhost only, so the device looks fine here while the other containers can't reach it
exitIfAdbServerStopped() {
  if ! kill -0 "$adbServerPid" 2> /dev/null; then
    logger "ERROR" "Adb server is not running. Restarting!"
    exit 1
  fi
}
exitIfAdbServerStopped

#### USB device of the host adb server
# Docker of macOS has no USB: the device stays on the adb server of the host, its adbd listens on tcp:5555 and the
# server forwards ADB_TRANSPORT_PORT of the host to it, so the device is connected below like a remote one and the
# adb server of the container stays the only one of the device (the forwards of Appium are in the container)
if [[ -n "$ADB_TRANSPORT_SERVER" ]]; then
  transportHost="${ADB_TRANSPORT_SERVER%:*}"
  transportPort="${ADB_TRANSPORT_SERVER##*:}"
  # transportAdb <args>: adb of the host server for the USB device
  transportAdb() {
    adb -H "$transportHost" -P "$transportPort" -s "$ADB_TRANSPORT_SERIAL" "$@"
  }
  # waitTransportDevice: waits for the device on the host server, exits when it is unauthorized or missing
  waitTransportDevice() {
    local state
    declare -i index=0
    while [[ $index -lt 10 ]]; do
      state=$(transportAdb get-state 2>&1)
      logger "Device '${ADB_TRANSPORT_SERIAL}' on the adb server ${ADB_TRANSPORT_SERVER}: ${state}"
      case $state in
      "device") return 0 ;;
      *"unauthorized"*)
        logger "WARN" "Authorize the adb server of the host on the device manually!"
        exit 0
        ;;
      esac
      sleep "${ADB_POLLING_SEC}"
      index+=1
    done
    logger "ERROR" "Device '${ADB_TRANSPORT_SERIAL}' is not found on the adb server ${ADB_TRANSPORT_SERVER}. Restarting!"
    exit 1
  }

  waitTransportDevice
  if [[ "$(transportAdb shell getprop service.adb.tcp.port 2> /dev/null | tr -d '\r')" != "5555" ]]; then
    logger "Switching adbd of the device to tcp:5555."
    transportAdb tcpip 5555
    sleep "${ADB_POLLING_SEC}"
    waitTransportDevice
  fi
  if ! transportAdb forward "tcp:${ADB_TRANSPORT_PORT}" tcp:5555; then
    logger "ERROR" "The adb server ${ADB_TRANSPORT_SERVER} can't forward the port ${ADB_TRANSPORT_PORT}. Restarting!"
    exit 1
  fi
  ANDROID_DEVICE="${transportHost}:${ADB_TRANSPORT_PORT}"
  logger "The device is forwarded by the adb server of the host to ${ANDROID_DEVICE}."
fi

#### ADB connect
# Via wireless network, an emulator by its adb address or via the adb server of the host
if [[ -n "$ANDROID_DEVICE" ]]; then
  isConnected=0
  declare -i index=0
  while [[ $index -lt 10 ]]; do
    exitIfAdbServerStopped
    logger "Connecting to: ${ANDROID_DEVICE}"
    adb connect "${ANDROID_DEVICE}"
    # the serial must be exactly ANDROID_DEVICE in the 'device' state: a serial like 'device:5555' contains 'device' itself
    if adb devices | awk -v serial="${ANDROID_DEVICE}" '$1 == serial && $2 == "device" { print; found = 1 } END { exit !found }'; then
      isConnected=1
      logger "Connected: ${ANDROID_DEVICE}"
      break
    fi

    sleep "${ADB_POLLING_SEC}"
    index+=1
  done

  if [[ $isConnected -eq 0 ]]; then
    logger "ERROR" "Device ${ANDROID_DEVICE} is not connected!"
    exit 1
  fi
fi

#### Make sure device is fully booted
declare -i index=0
info=""
# to support device reboot as device is available by adb but not functioning correctly.
# this extra dumpsys display call guarantees that android is fully booted (wait up to 5min)
while [[ "$info" == "" && $index -lt 60 ]]; do
  exitIfAdbServerStopped
  info=$(adb shell dumpsys display | grep -A 20 DisplayDeviceInfo)
  logger "sleeping ${ADB_POLLING_SEC} seconds..."
  sleep "${ADB_POLLING_SEC}"
  index+=1
done

if [[ "$info" == "" ]]; then
  logger "WARN" "Device dumpsys display is not available yet. Potentially device is not fully booted yet!"
  exit 1
else
  logger "info: $info"
fi

#### Print device filesystem usage statistics
adb shell df -h

logger "Device is fully available."

#### Entrypoint holder
while :; do
  isAvailable=0
  declare -i index=0
  # as default ADB_POLLING_SEC is 5s then we wait for authorizing ~50 sec only
  while [[ $index -lt 10 ]]; do
    # Possible adb statuses - https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/adb.cpp#118
    # Possible adb statuses2 - https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/proto/devices.proto#25
    # UsbNoPermissionsShortHelpText https://android.googlesource.com/platform/system/core/+/refs/heads/main/diagnose_usb/diagnose_usb.cpp#83
    exitIfAdbServerStopped
    state=$(adb get-state 2>&1)
    logger --------------
    logger state: "$state"

    case $state in
    "device")
      logger "Device connected successfully."
      isAvailable=1
      break
      ;;
    *"authorizing"* | *"connecting"* | *"unknown"* | *"bootloader"*)
      # do not break to repeat verification until device in temporary state
      logger "Waiting for valid device state..."
      ;;
    *"unauthorized"*)
      logger "WARN" "Authorize device manually!"
      exit 0
      ;;
    *"offline"*)
      logger "WARN" "Device is offline, performing adb reconnect."
      adb reconnect
      ;;
    *"no devices/emulators found"*)
      if [[ -n "$ANDROID_DEVICE" ]]; then
        logger "WARN" "Remote device is not found, restarting container."
        exit 1
      else
        logger "WARN" "Device not found, performing usb port reset or restarting container, if can't reset usb."
        usbreset "${DEVICE_BUS}" || exit 1
      fi
      ;;
    *)
      # it should cover such state as: host, recovery, rescue, sideload, no permissions
      logger "ERROR" "Troubleshoot device manually to define the best strategy."
      exit 0
      ;;
    esac

    logger "One more attempt in ${ADB_POLLING_SEC} seconds..."
    sleep "${ADB_POLLING_SEC}"
    index+=1
  done

  if [[ $isAvailable -eq 0 ]]; then
    logger "ERROR" "Retry limit reached. Exiting."
    exit 0
  fi

  sleep 33
done
