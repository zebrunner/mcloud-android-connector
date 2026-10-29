# Zebrunner Device Connector

The Zebrunner Device Connector is a lightweight Docker image that exposes an Android device over adb. It starts an adb server with remote access, connects a remote device (Wi-Fi, an emulator by its adb address or the USB device of the adb server of a macOS host) when needed, waits until the device is fully booted and monitors the device state. Its adb server is the only one of the device: the Appium and STF containers use it (`connector:5037`).

The image is based on Alpine and runs on `linux/amd64` only (it contains the amd64 build of `adb` from the Android [platform-tools](https://developer.android.com/tools/releases/platform-tools) 37.0.1). `usbreset` is built from `tools/usbreset/usbreset.c` in the image build.

Everything the image build downloads is pinned: the base image by version and digest, the Alpine packages by version, and the platform-tools archive by its SHA-256. Alpine drops the old revisions of a package from its release repositories, so a failing `apk add` after a security update means the pinned versions in the `Dockerfile` need a bump (the installed ones are checked by `make docker`).

## Build

Build the image from the repository root:

```bash
docker build --platform linux/amd64 --tag mcloud-android-connector:local .
```

## Configuration

Set these environment variables when starting the container. The entrypoint validates the numeric variables (`ADB_PORT` and `ADB_POLLING_SEC` must be non-negative integers) before anything is started.

| Variable | Default | Description |
| --- | --- | --- |
| `ANDROID_DEVICE` | empty | Remote device to connect with `adb connect` in `host:port` form (for example a Wi-Fi device or an emulator). If empty, the device is expected on USB. |
| `DEVICE_BUS` | empty | USB device path (for example `/dev/bus/usb/001/002`) that is reset with `usbreset` when the USB device is lost (the `USBDEVFS_RESET` ioctl; `usbreset -h` shows the other strategies: `-u` driver unbind/bind, `-a` the `authorized` toggle). |
| `ADB_PORT` | `5037` | Port of the adb server; the entrypoint and the healthcheck use the same port. |
| `ADB_POLLING_SEC` | `5` | Delay in seconds between the connection, boot and device state checks. |
| `ADB_TRANSPORT_SERVER` | empty | The adb server (`host:port`, e.g. `host.docker.internal:5037`) that has the USB device: Docker of macOS has no USB, see [USB device of a macOS host](#usb-device-of-a-macos-host). |
| `ADB_TRANSPORT_SERIAL` | empty | The serial of the USB device on `ADB_TRANSPORT_SERVER` (required with it). |
| `ADB_TRANSPORT_PORT` | `5555` | The port of the host that `ADB_TRANSPORT_SERVER` forwards to adbd of the device, unique for every device of the host. |
| `LOGGER_LEVEL` | `INFO` | Minimum log level: `DEBUG`, `INFO`, `WARN`, or `ERROR`. |
| `DEBUG` | `false` | Intercept script exit and wait for `DEBUG_TIMEOUT` seconds. |
| `DEBUG_TIMEOUT` | `3600` | Debug exit pause duration in seconds. |
| `VERBOSE` | `false` | Enable Bash command tracing. |

A USB device must be passed into the container (for example with `--device`). The adb keys are kept in `/root/.android`, mount a volume there to keep the device authorized over the container recreations.

## USB device of a macOS host

Docker of macOS has no USB, so a USB device stays on the adb server of the host (`adb -a -P 5037 server nodaemon`, mcloud-agent runs it as a launch agent) and the container takes it from there, the host runs no device commands itself. With `ADB_TRANSPORT_SERVER` the entrypoint waits for `ADB_TRANSPORT_SERIAL` on that server (an unauthorized device exits with `0`: authorize the host on the device), switches adbd of the device to `tcp:5555` when it is not there yet (`adb tcpip 5555`, it is reset by a reboot of the device and done again by the restart), forwards `ADB_TRANSPORT_PORT` of the host to it and connects `<host>:<ADB_TRANSPORT_PORT>` as a remote device. The adb server of the container is the only one of the device for the other containers, the forwards of Appium are in the container as on Linux. The serial of the device in the container (`DEVICE_UDID` of Appium and STF) is `<host>:<ADB_TRANSPORT_PORT>`; the device also authorizes the key of the container (`/root/.android`) on the first connection.

## Startup

1. The adb server starts with remote access (`adb -a -P ${ADB_PORT} server nodaemon`).
2. With `ADB_TRANSPORT_SERVER` set, the USB device of the host server is forwarded and becomes `ANDROID_DEVICE` (see above).
3. With `ANDROID_DEVICE` set, the device is connected with `adb connect` (10 attempts).
4. The entrypoint waits until `adb shell dumpsys display` returns the display info, so the device is fully booted (60 attempts, `ADB_POLLING_SEC` apart), and prints the filesystem usage of the device.
5. Every 33 seconds the device state (`adb get-state`) is checked.

## Exit codes and health

- Exit code `0` means a problem that a restart does not fix: invalid configuration, an unauthorized device (authorize it manually, also the adb server of the host with `ADB_TRANSPORT_SERVER`), a device in a state that needs troubleshooting (`recovery`, `rescue`, `sideload`, no permissions, ...), or a device that stays in a temporary state (`authorizing`, `connecting`, `unknown`, `bootloader`) for 10 checks.
- Exit code `1` asks for a restart: the USB device is missing on `ADB_TRANSPORT_SERVER` or its port can't be forwarded, the adb server is not running (an adb client call would start a new one without remote access, so it is checked during the startup and before every device check), the remote device can't be connected or is lost, the device is not fully booted, or the USB device is lost and its port can't be reset with `usbreset`.
- An `offline` device is reconnected with `adb reconnect`, a lost USB device gets its `DEVICE_BUS` port reset, the checks go on after that.
- The image healthcheck expects `adb -P ${ADB_PORT} get-state` to return `device`.
- Set `DEBUG=true` to keep the container alive for `DEBUG_TIMEOUT` seconds after the entrypoint exits, and `LOGGER_LEVEL=DEBUG` or `VERBOSE=true` for more output.

## Development

`make help` lists the targets, `make check` runs all of them as CI does (every step runs, the failed ones fail the target):

| Target | What it checks |
| --- | --- |
| `make lint` | `tests/lint.sh`: yamllint, actionlint, hadolint, pymarkdown, `bash -n`, ShellCheck and shfmt (style of `.editorconfig`), every env var of the `Dockerfile` documented in this README, the text file checks of CONVENTIONS.md. The tools are installed into `.venv` from `tests/requirements-lint.txt`; hadolint comes from `brew install hadolint` on macOS. |
| `make test` | The static checks of the repository (`tests/repo_test.sh`: the pins of the `Dockerfile`, the Dependabot configuration) and the tests of `util/logger.sh`, `util/debug.sh` and `entrypoint.sh`: configuration validation, the adb server port and its liveness, USB and remote devices, the boot wait, every device state of the holder with its retry limits, the `DEBUG` and `VERBOSE` modes. The tools are stubs (`adb`, `usbreset`, `sleep`), so no docker and no Android device are needed, but bash 4+ is (on macOS `brew install bash`). |
| `make docker` | `tests/image_test.sh`: builds the image (`linux/amd64`, `IMAGE` overrides its tag, `REBUILD=true` rebuilds it), checks its contents, the installed versions of the pinned packages, configuration, configuration validation and the entrypoint startup without a device, also with a stopped adb server. |

Every test script prints its checks and writes JUnit XML into `JUNIT_DIR` when it is set.

The GitHub Actions workflow `.github/workflows/ci.yml` runs the same `lint`, `test` and `docker` jobs on pushes and pull requests to `develop`, `main` and `master`.

Dependabot (`.github/dependabot.yml`) opens weekly pull requests for the GitHub Actions, the base image of the `Dockerfile` and the linters of `tests/requirements-lint.txt`. The Alpine packages and platform-tools (its URL and SHA-256) are updated by hand.

The conventions of the style, the formatting and the tooling of this repository are in [CONVENTIONS.md](CONVENTIONS.md), the same in all the MCloud docker image repositories.

## Support

Feel free to support the development with a [**donation**](https://www.paypal.com/donate/?hosted_button_id=MNHYYCYHAKUVA) for the next improvements.

<p align="center">
  <a href="https://zebrunner.com/"><img alt="Zebrunner" src="https://github.com/zebrunner/zebrunner/raw/master/docs/img/zebrunner_intro.png"></a>
</p>

## License

[Apache License 2.0](LICENSE)
