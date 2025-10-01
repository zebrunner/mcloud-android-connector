#!/bin/bash

. /opt/zebrunner/util/debug.sh
. /opt/zebrunner/util/logger.sh

logger "INFO" "\n\n\n\t\tMCLOUD-ANDROID-CONNECTOR\n\n"


#### Start ADB
# "-a" - allow remote access
# https://github.com/sorccu/docker-adb
adb -a -P 5037 server nodaemon &
sleep 1


#### ADB connect
# Via wireless network or via tcp for redroid emulator
if [[ -n "$ANDROID_DEVICE" ]]; then
  isConnected=0
  declare -i index=0
  while [[ $index -lt 10 ]]; do
    logger "Connecting to: ${ANDROID_DEVICE}"
    adb connect "${ANDROID_DEVICE}"
    if adb devices | grep "${ANDROID_DEVICE}" | grep "device"; then
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


#### Extra steps for Zebrunner Redroid Emulator
if [[ "$ANDROID_DEVICE" == "device:5555" ]]; then
  # Moved sleep after reconnection to root where the problem occurs much more often
  #sleep 5
  #adb devices

  # install appium apk
  if [[ -f /usr/lib/node_modules/appium/node_modules/appium-uiautomator2-driver/node_modules/io.appium.settings/apks/settings_apk-debug.apk ]]; then
    adb install /usr/lib/node_modules/appium/node_modules/appium-uiautomator2-driver/node_modules/io.appium.settings/apks/settings_apk-debug.apk
  fi

  # download and install chrome apk from https://www.apkmirror.com/apk/google-inc/chrome/chrome-99-0-4844-73-release/
  # version: x86 + x86_64
  # url: https://www.apkmirror.com/apk/google-inc/chrome/chrome-99-0-4844-73-release/google-chrome-fast-secure-99-0-4844-73-10-android-apk-download/
  # /tmp/zebrunner/chrome/latest.apk is default shared location for chrome browser apk
  if [[ -f /tmp/zebrunner/chrome/latest.apk ]]; then
    adb install /tmp/zebrunner/chrome/latest.apk
  fi
fi

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
