FROM alpine:3.19.1

LABEL maintainer "Vadim Delendik <vdelendik@zebrunner.com>"

ENV DEBIAN_FRONTEND=noninteractive

# Android envs
ENV ADB_PORT=5037
ENV ANDROID_DEVICE=
ENV ADB_POLLING_SEC=5

#=============
# Set WORKDIR
#=============
WORKDIR /root

RUN apk add --no-cache \
    bash

# ADB part
RUN apk add \
    android-tools \
    --repository=http://dl-cdn.alpinelinux.org/alpine/edge/testing

RUN adb --version

# Copy entrypoint script
ADD entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]
