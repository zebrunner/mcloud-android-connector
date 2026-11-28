# Zebrunner MCloud Android Connector

The Zebrunner MCloud Android Connector is a lightweight Docker image that exposes an Android device over adb. It starts an adb server with remote access, connects a remote device (Wi-Fi, an emulator by its adb address or the USB device of the adb server of a macOS host) when needed, waits until the device is fully booted and monitors the device state. Its adb server is the only one of the device: the Appium and STF containers use it (`connector:5037`).

## Image contents

The image is based on Alpine and is built for `linux/amd64` and `linux/arm64`: on amd64 it contains `adb` of the Android [platform-tools](https://developer.android.com/tools/releases/platform-tools) 37.0.1, on arm64, for which Google publishes no platform-tools, `adb` of the Alpine package `android-tools-adb` 35.0.2; both speak the adb protocol 1.0.41 of the adb servers of the hosts (a USB device of a macOS host). `usbreset` is built from `tools/usbreset/usbreset.c` in the image build.

Everything the image build downloads is pinned: the base image by version and digest, the Alpine packages by version, and the platform-tools archive by its SHA-256. Alpine drops the old revisions of a package from its release repositories, so a failing `apk add` after a security update means the pinned versions in the `Dockerfile` need a bump (the installed ones are checked by `make docker`).

## Build

```bash
make build VERSION=2.0   # public.ecr.aws/zebrunner/mcloud-android-connector:2.0 in the local docker
make push VERSION=2.0    # built by docker buildx and pushed: docker login public.ecr.aws first
```

`make build` builds the image for the platform of this machine, `make push` builds `linux/amd64` and `linux/arm64` (`PLATFORMS`) with `docker buildx` and pushes them as one multi-platform image. `IMAGE_REPO` sets another repository (e.g. `IMAGE_REPO=registry.example.com/mcloud-android-connector`), `VERSION` is the tag and the
`org.opencontainers.image.version` label (`dev` by default, required by `push`). `make push` uses the buildx builder
`mcloud` (docker-container driver), which it creates once; another platform than the one of the machine needs QEMU
(`docker run --privileged --rm tonistiigi/binfmt --install all`).

The file `VERSION` is the release in work (bumped by hand after a release, CONVENTIONS.md#versions). The `publish` job of CI pushes the image of every merge into `develop` after all the checks passed: `public.ecr.aws/zebrunner/mcloud-android-connector:<VERSION>-develop-<sha>` (7 characters of the commit) and `<VERSION>-develop-latest`, the newest commit of `develop`. Each platform is built on a runner of its own (arm64 on an arm64 runner) and pushed by digest, with the cache of GitHub Actions (`PUSH_OUTPUT` and `PUSH_CACHE` of `make push`), then the job merges them into the image.

## Run

mcloud-agent creates the container (`roles/common/files/zebrunner-farm`, `device-<name>-<udid>-connector`, where `<name>` is the name of the device in `mcloud-devices.txt`) on the docker network of the farm (`STF_DOCKER_NETWORK`); the STF and Appium containers of the device link to it as `connector` and use its adb server `connector:5037`. A USB device of a Linux host:

```bash
docker run -d --name device-<name>-<udid>-connector --net infra --restart on-failure:<restarts> \
  --device /dev/device-<name>-<udid>:/dev/bus/usb/<bus>/<device> -e DEVICE_BUS=/dev/bus/usb/<bus>/<device> \
  -v mcloud-key-volume:/root/.android \
  -v device-<name>-<udid>:/tmp/log \
  public.ecr.aws/zebrunner/mcloud-android-connector:2.0
```

- `--device /dev/device-<name>-<udid>:/dev/bus/usb/<bus>/<device>` and `DEVICE_BUS`: the USB device, the symlink of the udev rule of mcloud-agent passed at the path of its bus, which `usbreset` resets when adb loses the device (`usb` on Linux only).
- `/root/.android`: the adb key, one volume shared by the connectors of the host, so a device authorizes the host once and stays authorized over the container recreations.
- `/tmp/log`: the log volume of the device, mcloud-agent mounts it into all its containers (the connector logs to the container output only).
- A wireless device or an emulator: `-e ANDROID_DEVICE=<host>:<port>` without `--device` and `DEVICE_BUS`. A USB device of a macOS host (Docker of macOS has no USB): `-e ADB_TRANSPORT_SERVER=host.docker.internal:5037 -e ADB_TRANSPORT_SERIAL=<serial> -e ADB_TRANSPORT_PORT=<port>`, see [USB device of a macOS host](#usb-device-of-a-macos-host).
- No port is published: the other containers of the device reach the adb server on the docker network. mcloud-agent also passes `PLATFORM_NAME` and `DEVICE_UDID`, which the connector does not read.

## Configuration

Set these environment variables when starting the container. The entrypoint validates the configuration before anything is started, logs every invalid variable and exits with `0`: the non-negative integers `ADB_PORT`, `ADB_POLLING_SEC`, `REBOOT_INTERVAL` and `REBOOT_CONFIRM_TIMEOUT`, `ALLOW_REBOOT` (`true` or `false`, case-insensitive); with `ADB_TRANSPORT_SERVER` set, it must be `<host>:<port>`, `ADB_TRANSPORT_SERIAL` is required and `ADB_TRANSPORT_PORT` is a non-negative integer.

| Variable | Default | Description |
| --- | --- | --- |
| `ANDROID_DEVICE` | empty | Remote device to connect with `adb connect` in `host:port` form (for example a Wi-Fi device or an emulator). If empty, the device is expected on USB. |
| `DEVICE_BUS` | empty | USB device path (for example `/dev/bus/usb/001/002`) that is reset with `usbreset` when the USB device is lost (the `USBDEVFS_RESET` ioctl; `usbreset -h` shows the other strategies: `-u` driver unbind/bind, `-a` the `authorized` toggle). |
| `ADB_PORT` | `5037` | Port of the adb server; the entrypoint and the healthcheck use the same port. Keep `5037` with mcloud-agent: it does not pass `ADB_PORT`, the STF and Appium containers use `connector:5037`. |
| `ADB_POLLING_SEC` | `5` | Delay in seconds between the connection, boot and device state checks. |
| `ADB_TRANSPORT_SERVER` | empty | The adb server (`host:port`, e.g. `host.docker.internal:5037`) that has the USB device: Docker of macOS has no USB, see [USB device of a macOS host](#usb-device-of-a-macos-host). |
| `ADB_TRANSPORT_SERIAL` | empty | The serial of the USB device on `ADB_TRANSPORT_SERVER` (required with it). |
| `ADB_TRANSPORT_PORT` | `5555` | The port of the host that `ADB_TRANSPORT_SERVER` forwards to adbd of the device, unique for every device of the host. |
| `CONNECTOR_PEERS` | empty | The names of the containers (separated by commas) that open connections to the connector, the STF and appium containers of the device (mcloud-agent passes them); the new connections of every other host of the docker networks of the container are dropped, see [Peer filter](#peer-filter). Empty: no filter. |
| `PEER_FILTER_INTERVAL` | `2` | The seconds between the resolutions of `CONNECTOR_PEERS`: a recreated peer gets its new address. |
| `ALLOW_REBOOT` | `false` | `true`: the device is rebooted when it has no free app UIDs, see [Reboot](#reboot). |
| `REBOOT_INTERVAL` | `21600` | At most one reboot of the device per this many seconds. Only a confirmed reboot counts. |
| `REBOOT_CONFIRM_TIMEOUT` | `30` | How long in seconds the device has to show its reboot after `adb reboot` (it disconnects or gets a new boot id), see [Reboot](#reboot). |
| `IMAGE_VERSION` | the `VERSION` of the build | The version of the image in the first log line. |
| `LOGGER_LEVEL` | `INFO` | Minimum log level: `DEBUG`, `INFO`, `WARN`, or `ERROR`. |
| `DEBUG` | `false` | Intercept script exit and wait for `DEBUG_TIMEOUT` seconds. |
| `DEBUG_TIMEOUT` | `3600` | Debug exit pause duration in seconds. |
| `VERBOSE` | `false` | Enable Bash command tracing. |

## USB device of a macOS host

Docker of macOS has no USB, so a USB device stays on the adb server of the host (`adb -a -P 5037 server nodaemon`, mcloud-agent runs it as a launch agent) and the container takes it from there, the host runs no device commands itself. With `ADB_TRANSPORT_SERVER` the entrypoint waits for `ADB_TRANSPORT_SERIAL` on that server (an unauthorized device exits with `0`: authorize the host on the device), switches adbd of the device to `tcp:5555` when it is not there yet (`adb tcpip 5555`, it is reset by a reboot of the device and done again by the restart), forwards `ADB_TRANSPORT_PORT` of the host to it and connects `<host>:<ADB_TRANSPORT_PORT>` as a remote device. The adb server of the container is the only one of the device for the other containers, the forwards of Appium are in the container as on Linux. The serial of the device in the container (`DEVICE_UDID` of Appium and STF) is `<host>:<ADB_TRANSPORT_PORT>`; the device also authorizes the key of the container (`/root/.android`) on the first connection.

## Peer filter

The adb server has no authentication and listens on all the interfaces of the container (`-a`): its forwards too, and appium reaches the ones it makes on the connector (the server of UiAutomator2, chromedriver), so it can not listen on the loopback or one address only. With `CONNECTOR_PEERS` (the containers of STF and appium of the device, `CONNECTOR_PEER_FILTER` of mcloud-agent) the entrypoint installs a packet filter in the network namespace of the container before the adb server starts (`util/peerfilter.sh`, iptables, the container needs `--cap-add NET_ADMIN`):

- the new connections from the docker networks of the container (`eth+`) go through the chain `MCLOUD_PEERS`: the addresses of the peers are accepted, every other one is dropped: the docker host through the gateway of the network (its local users), an emulator container joined to the network of the device, the containers of other devices on a shared network (`DEVICE_NETWORK_ISOLATION=false` of mcloud-agent); IPv6 is dropped;
- the loopback (the healthcheck, the adb clients of the entrypoint) and the answers to the connections of the connector (`adb connect`, the adb server of a macOS host) are not filtered;
- the names are resolved again every `PEER_FILTER_INTERVAL` seconds: a recreated peer gets its new address, a connection of it dropped meanwhile is retried by TCP;
- a filter that can not be installed (no `NET_ADMIN`, no packet filter of the kernel) ends the entrypoint with `0`: the connector does not run without it; `CONNECTOR_PEER_FILTER: false` of mcloud-agent turns it off.

Without `CONNECTOR_PEERS` nothing is filtered (an earlier mcloud-agent), the entrypoint warns about it.

## Startup

1. With `CONNECTOR_PEERS`, the peer filter is installed (see above).
2. The adb server starts with remote access (`adb -a -P ${ADB_PORT} server nodaemon`).
3. With `ADB_TRANSPORT_SERVER` set, the USB device of the host server is forwarded and becomes `ANDROID_DEVICE` (see above).
4. With `ANDROID_DEVICE` set, the device is connected with `adb connect` (10 attempts).
5. The entrypoint waits until `adb shell dumpsys display` returns the display info, so the device is fully booted (60 attempts, `ADB_POLLING_SEC` apart), and prints the filesystem usage of the device.
6. Every 33 seconds the device state (`adb get-state`) is checked, and the log of the device for an app without a UID (see [Reboot](#reboot)).

`docker stop` ends the entrypoint (PID 1 of the container) at once, also in a wait: it stops the adb server and exits with `0`.

## Reboot

A device that has not been rebooted for long, with many installs and uninstalls of apps, runs out of the app UIDs of its PackageManager: no app can be installed, e.g. STFService of STF (`INSTALL_FAILED_INSUFFICIENT_STORAGE: Scanning Failed.: Package jp.co.cyberagent.stf could not be assigned a valid UID`, while the storage is free), and the STF container of the device spends its restarts. Restarting the containers does not help, a reboot of the device frees the UIDs. The connector looks for `could not be assigned a valid UID` in the log of the device (`adb shell logcat -d`, filtered on the device) at every device check:

- `ALLOW_REBOOT=false` (the default): the log says `Device reboot is recommended`, once per start of the container.
- `ALLOW_REBOOT=true`: `adb reboot`, then exit `1`; a USB device gets its containers created again when it reconnects, a remote one is connected again by the restart. At most one reboot per `REBOOT_INTERVAL`: the time of the last one is kept in `/root/.android/reboot/<serial>` (the volume of the adb key survives a new container); the same failure within it is reported once (`the device needs a person`) and the connector keeps running (adb, Appium and the other apps still work).
- The reboot is confirmed within `REBOOT_CONFIRM_TIMEOUT` seconds: the device leaves the `device` state of adb (it disconnects) or its boot id (`/proc/sys/kernel/random/boot_id`, new on every boot) changes; without a sign `adb reboot` is sent once more. Only a confirmed reboot is written to `/root/.android/reboot/<serial>`. A device that does not reboot on both commands is logged (`The device did not reboot on 'adb reboot' (2 attempts)`), nothing is recorded and the connector keeps running.

## Exit codes and health

- Exit code `0` means a problem that a restart does not fix or a stop: `docker stop` (`SIGTERM`), invalid configuration, a peer filter that can not be installed, an unauthorized device (authorize it manually, also the adb server of the host with `ADB_TRANSPORT_SERVER`), a device in a state that needs troubleshooting (`recovery`, `rescue`, `sideload`, no permissions, ...), or a device that stays in a temporary state (`authorizing`, `connecting`, `unknown`, `bootloader`) for 10 checks.
- Exit code `1` asks for a restart: the USB device is missing on `ADB_TRANSPORT_SERVER` or its port can't be forwarded, the adb server is not running (an adb client call would start a new one without remote access, so it is checked during the startup and before every device check), the remote device can't be connected or is lost, the device is not fully booted, the USB device is lost and its port can't be reset with `usbreset`, or the device was rebooted because it has no free app UIDs (`ALLOW_REBOOT`).
- An `offline` device is reconnected with `adb reconnect`, a lost USB device gets its `DEVICE_BUS` port reset, the checks go on after that; a device still offline or lost after 10 checks exits with `1` (a restart connects it again).
- The image healthcheck expects `adb -P ${ADB_PORT} get-state` to return `device`.
- Set `DEBUG=true` to keep the container alive for `DEBUG_TIMEOUT` seconds after the entrypoint exits, and `LOGGER_LEVEL=DEBUG` or `VERBOSE=true` for more output.

## Development

`make help` lists the targets, `make check` runs all of them as CI does (every step runs, the failed ones fail the target):

| Target | What it checks |
| --- | --- |
| `make lint` | `tests/lint.sh`: yamllint, actionlint, hadolint, pymarkdown, `bash -n`, ShellCheck and shfmt (style of `.editorconfig`), every env var of the `Dockerfile` documented in this README, the text file checks of CONVENTIONS.md. The tools are installed into `.venv` from `tests/requirements-lint.txt`; hadolint comes from `brew install hadolint` on macOS. |
| `make test` | The static checks of the repository (`tests/repo_test.sh`: the pins of the `Dockerfile`, the Dependabot configuration) and the tests of `util/logger.sh`, `util/debug.sh` and `entrypoint.sh`: configuration validation, the adb server port and its liveness, USB and remote devices, the boot wait, every device state of the holder with its retry limits, the reboot of a device without free app UIDs, the peer filter, `SIGTERM`, the `DEBUG` and `VERBOSE` modes. The tools are stubs (`adb`, `usbreset`, `sleep`, `iptables`, `getent`), so no docker and no Android device are needed, but bash 4+ is (on macOS `brew install bash`). |
| `make docker` | `tests/image_test.sh`: builds the image (`PLATFORM`: `linux/amd64` by default or `linux/arm64`, `IMAGE` overrides its tag, `REBUILD=true` rebuilds it), checks its contents, the installed versions of the pinned packages, configuration, configuration validation and the entrypoint startup without a device, also with a stopped adb server, `docker stop`, and the peer filter in a docker network (a peer connects, another container does not). |

Every test script prints its checks and writes JUnit XML into `JUNIT_DIR` when it is set.

The GitHub Actions workflow `.github/workflows/ci.yml` runs the same `lint`, `test` and `docker` jobs on pushes and pull requests to `develop`, `main` and `master`.

Dependabot (`.github/dependabot.yml`) opens weekly pull requests for the GitHub Actions and the base image of the `Dockerfile`. The linters of `tests/requirements-lint.txt` are the shared ones of mcloud-conventions, updated there and synced; the Alpine packages and platform-tools (its URL and SHA-256) are updated by hand.

The conventions of the style, the formatting and the tooling of this repository are in [CONVENTIONS.md](CONVENTIONS.md), the same in all the MCloud docker image repositories.

## Support

Feel free to support the development with a [**donation**](https://www.paypal.com/donate/?hosted_button_id=MNHYYCYHAKUVA) for the next improvements.

<p align="center">
  <a href="https://zebrunner.com/"><img alt="Zebrunner" src="https://github.com/zebrunner/zebrunner/raw/master/docs/img/zebrunner_intro.png"></a>
</p>

## License

[Apache License 2.0](LICENSE)
