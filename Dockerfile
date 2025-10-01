FROM alpine:3.22.1
# In case of any build errors try to use 'FROM --platform=linux/amd64 ...'

LABEL maintainer="Vadim Delendik <vdelendik@zebrunner.com>"

ENV DEBIAN_FRONTEND=noninteractive \
    # Android envs
    ADB_PORT=5037 \
    ANDROID_DEVICE='' \
    ADB_POLLING_SEC=5

RUN mkdir /opt/zebrunner/

WORKDIR /opt/zebrunner/

RUN apk add --no-cache bash ;\
    apk add --no-cache android-tools --repository=http://dl-cdn.alpinelinux.org/alpine/edge/testing &&\
    adb --version

COPY bin/ /usr/local/bin/
COPY util/ /opt/zebrunner/util/
COPY entrypoint.sh /opt/zebrunner/

ENTRYPOINT ["/opt/zebrunner/entrypoint.sh"]

HEALTHCHECK --interval=20s --timeout=5s --start-period=120s --start-interval=10s --retries=3 \
  CMD sh -c '[ "$(adb get-state 2>&1)" = "device" ]'
