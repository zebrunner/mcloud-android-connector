# the platform of the image, set by BuildKit (a default would override it): the stage of its adb
ARG TARGETARCH

# usbreset (tools/usbreset): the connector resets the USB device of its Android device with it (DEVICE_BUS)
FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a AS usbreset

RUN apk add --no-cache \
        build-base=0.5-r4 linux-headers=7.0.0-r1
COPY tools/usbreset/usbreset.c /src/
RUN mkdir -p /out && \
    cc -Wall -Wextra -Werror -O2 /src/usbreset.c -o /out/usbreset

# adb of linux/amd64: the official platform-tools, a glibc build (gcompat, libstdc++ and its libc++.so next to it)
FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a AS base-amd64

RUN apk add --no-cache \
        bash=5.3.9-r1 gcompat=1.1.0-r4 libstdc++=15.2.0-r5

RUN wget -q -O /tmp/platform-tools.zip https://dl.google.com/android/repository/platform-tools_r37.0.1-linux.zip && \
    echo "d230f13842f60f782a8645f9c813f8f845bf36089ea7289f28c48f17979313f1  /tmp/platform-tools.zip" > /tmp/platform-tools.sha256 && \
    sha256sum -c /tmp/platform-tools.sha256 && \
    unzip -q /tmp/platform-tools.zip -d /tmp/ && \
    mv /tmp/platform-tools/adb /usr/local/bin/ && \
    mv /tmp/platform-tools/lib64/libc++.so /usr/local/bin/ && \
    rm -rf /tmp/platform-tools /tmp/platform-tools.zip /tmp/platform-tools.sha256 && \
    adb version

# adb of linux/arm64: Google publishes no platform-tools for it, the adb of Alpine speaks the same protocol (1.0.41);
# the image gets adb and its libraries only, not the dependencies of the package (python3, protoc, ...)
FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a AS adb-arm64

RUN apk add --no-cache \
        android-tools-adb=35.0.2-r21
# the libraries of adb from ldd: a failed ldd fails the build
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
RUN mkdir -p /out/lib && \
    cp /usr/bin/adb /out/ && \
    ldd /usr/bin/adb | awk '$3 ~ /^\/usr\/lib\// { print $3 }' | xargs -I {} cp -L {} /out/lib/

FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a AS base-arm64

RUN apk add --no-cache \
        bash=5.3.9-r1
COPY --from=adb-arm64 /out/lib/ /usr/lib/
COPY --from=adb-arm64 /out/adb /usr/local/bin/adb
RUN adb version

# the image: the adb of its platform (a stage of this file, not an image to pin)
# hadolint ignore=DL3006
FROM base-${TARGETARCH}

ENV ANDROID_DEVICE="" \
    DEVICE_BUS="" \
    ADB_PORT=5037 \
    ADB_POLLING_SEC=5 \
    # The USB device of the adb server of the host (macOS), "host:port"
    ADB_TRANSPORT_SERVER="" \
    ADB_TRANSPORT_SERIAL="" \
    ADB_TRANSPORT_PORT=5555 \
    # Debug mode vars
    DEBUG=false \
    DEBUG_TIMEOUT=3600 \
    VERBOSE=false \
    # Logger
    LOGGER_LEVEL=INFO

WORKDIR /opt/zebrunner/

COPY --from=usbreset /out/usbreset /usr/local/bin/
COPY util/ /opt/zebrunner/util/
COPY entrypoint.sh /opt/zebrunner/

ARG VERSION=dev
LABEL org.opencontainers.image.title="Zebrunner MCloud Android Connector" \
      org.opencontainers.image.description="The adb server of an Android device of Zebrunner MCloud" \
      org.opencontainers.image.source="https://github.com/zebrunner/mcloud-android-connector" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="${VERSION}"

ENTRYPOINT ["/opt/zebrunner/entrypoint.sh"]

HEALTHCHECK --interval=20s --timeout=5s --start-period=120s --start-interval=10s --retries=3 \
    CMD ["sh", "-c", "[ \"$(adb -P \"${ADB_PORT}\" get-state 2>&1)\" = device ]"]
