FROM alpine:3.24.1
# In case of any build errors try to use 'FROM --platform=linux/amd64 ...'

ENV ADB_PORT=5037 \
    ANDROID_DEVICE='' \
    ADB_POLLING_SEC=5

WORKDIR /opt/zebrunner/

RUN apk add --no-cache bash gcompat libstdc++

RUN wget https://dl.google.com/android/repository/platform-tools_r37.0.1-linux.zip && \
  unzip platform-tools_r37.0.1-linux.zip -d /tmp/platform-tools && \
  mv /tmp/platform-tools/adb /usr/local/bin/ && \
  mv /tmp/platform-tools/libc++.so /usr/local/bin/ && \
  rm -rf /tmp/platform-tools platform-tools-latest-linux.zip && \
  adb version

COPY bin/ /usr/local/bin/
COPY util/ /opt/zebrunner/util/
COPY entrypoint.sh /opt/zebrunner/

ENTRYPOINT ["/opt/zebrunner/entrypoint.sh"]

HEALTHCHECK --interval=20s --timeout=5s --start-period=120s --start-interval=10s --retries=3 \
  CMD sh -c '[ "$(adb get-state 2>&1)" = "device" ]'
