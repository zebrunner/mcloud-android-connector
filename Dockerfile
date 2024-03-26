FROM alpine:3.19.1
# In case of any build errors try to use 'FROM --platform=linux/amd64 ...'

LABEL maintainer="Vadim Delendik <vdelendik@zebrunner.com>"

ENV DEBIAN_FRONTEND=noninteractive \
    # Android envs
    ADB_PORT=5037 \
    ANDROID_DEVICE='' \
    ADB_POLLING_SEC=5

WORKDIR /root

RUN apk add --no-cache bash ;\
    apk add --no-cache android-tools --repository=http://dl-cdn.alpinelinux.org/alpine/edge/testing &&\
    adb --version

COPY logger.sh /opt
COPY debug.sh /opt
COPY entrypoint.sh /
COPY healthcheck /usr/local/bin

ENTRYPOINT ["/entrypoint.sh"]

HEALTHCHECK --interval=10s --retries=3 CMD ["healthcheck"]
