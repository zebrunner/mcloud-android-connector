#!/bin/bash

. /opt/debug.sh
. /opt/logger.sh

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


#### Detect device state
if ! healthcheck; then
  logger "WARN" "Device is not ready."
  exit 0
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


#### Healthcheck
while :; do
  if ! healthcheck; then
    logger "WARN" "Device connection lost."
    exit 0
  fi
  sleep 30
done
