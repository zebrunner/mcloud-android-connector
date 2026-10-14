FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
# In case of any build errors try to use 'FROM --platform=linux/amd64 ...'

ENV ANDROID_DEVICE="" \
    DEVICE_BUS="" \
    ADB_PORT=5037 \
    ADB_POLLING_SEC=5 \
    # Debug mode vars
    DEBUG=false \
    DEBUG_TIMEOUT=3600 \
    VERBOSE=false \
    # Logger
    LOGGER_LEVEL=INFO

WORKDIR /opt/zebrunner/

# gcompat and libstdc++ are needed by adb of platform-tools, it is built for glibc
RUN apk add --no-cache \
        bash=5.3.9-r1 gcompat=1.1.0-r4 libstdc++=15.2.0-r5

# Grab adb of platform-tools, libc++.so is looked up next to the adb binary
RUN wget -q -O /tmp/platform-tools.zip https://dl.google.com/android/repository/platform-tools_r37.0.1-linux.zip && \
    echo "d230f13842f60f782a8645f9c813f8f845bf36089ea7289f28c48f17979313f1  /tmp/platform-tools.zip" > /tmp/platform-tools.sha256 && \
    sha256sum -c /tmp/platform-tools.sha256 && \
    unzip -q /tmp/platform-tools.zip -d /tmp/ && \
    mv /tmp/platform-tools/adb /usr/local/bin/ && \
    mv /tmp/platform-tools/lib64/libc++.so /usr/local/bin/ && \
    rm -rf /tmp/platform-tools /tmp/platform-tools.zip /tmp/platform-tools.sha256 && \
    adb version

COPY bin/ /usr/local/bin/
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
