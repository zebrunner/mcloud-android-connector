#!/bin/bash
# Static checks of the repository files, no docker: the pinned versions of the Dockerfile and the Dependabot configuration.
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

# apk_packages: the arguments of the 'apk add' commands of the Dockerfile (every stage), one per line
apk_packages() {
  awk '/apk add --no-cache/ { found = 1 } found { print } found && !/\\$/ { found = 0 }' Dockerfile |
    sed -e 's/^.*apk add --no-cache//' -e 's/&&.*$//' -e 's/\\$//' | tr -s ' ' '\n' | grep -v '^$'
}

section "Dockerfile pins"
# every stage: the image and the build of usbreset
unpinned_from="$(grep '^FROM ' Dockerfile | grep -vE '^FROM alpine:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}( AS [a-z0-9-]+)?$' || true)"
check "every stage is alpine:<version>@sha256:<digest>" "" "$unpinned_from"
check "the image and the build stage of usbreset" "2" "$(grep -c '^FROM ' Dockerfile)"
check_not_contains "no binary of the repository is copied into the image" "COPY bin/" "$(cat Dockerfile)"
check_not_contains "no edge repository of Alpine" "alpine/edge" "$(grep -v '^ *#' Dockerfile)"
check_not_contains "no unpinned latest tag" ":latest" "$(grep -v '^ *#' Dockerfile)"

packages="$(apk_packages)"
check "the apk add command is found" "true" "$([[ -n "$packages" ]] && echo true || echo false)"
unpinned="$(grep -vE '^[a-z0-9][a-z0-9.+_-]*=[0-9][^ =]*-r[0-9]+$' <<< "$packages" || true)"
check "every apk package is pinned as name=version-rN" "" "$unpinned"

if grep -qE 'platform-tools_r[0-9]+(\.[0-9]+)*-linux\.zip' Dockerfile; then
  pass "platform-tools are a pinned release"
else
  fail "platform-tools are a pinned release" "no platform-tools_r<version>-linux.zip" "$(grep platform-tools Dockerfile)"
fi
sums="$(grep -cE '^ *echo "[0-9a-f]{64}  [^"]+" > ' Dockerfile || true)"
check "the downloaded platform-tools archive has a sha256 checksum" "1" "$sums"
check_contains "the checksum is checked" "sha256sum -c" "$(cat Dockerfile)"

section "Dependabot"
config=".github/dependabot.yml"
# the linters of tests/requirements-lint.txt are updated in mcloud-conventions
for ecosystem in github-actions docker; do
  check_contains "${ecosystem} is updated" "package-ecosystem: ${ecosystem}" "$(cat "$config")"
done
check "tests/requirements-lint.txt exists" "true" "$([[ -f tests/requirements-lint.txt ]] && echo true || echo false)"
# the pinned linters: name==version
unpinned="$(grep -vE '^(#|$)' tests/requirements-lint.txt | grep -vE '^[A-Za-z0-9._-]+==[0-9][A-Za-z0-9.]*$' || true)"
check "every linter is pinned as name==version" "" "$unpinned"

finish
