#!/usr/bin/env bash
#
# Build all release binaries and images to directory ./release.
# Run from repository root.
#
set -euo pipefail

source ./scripts/test_lib.sh

VERSION=${1:-}
if [ -z "${VERSION}" ]; then
  echo "Usage: ${0} VERSION" >> /dev/stderr
  exit 255
fi

if ! command -v docker >/dev/null; then
    echo "cannot find docker"
    exit 1
fi

ETCD_ROOT=$(dirname "${BASH_SOURCE[0]}")/..

pushd "${ETCD_ROOT}" >/dev/null
  log_callout "Building etcd binary..."
  ./scripts/build-binary.sh "${VERSION}"

  for TARGET_ARCH in "amd64" "arm64" "ppc64le" "s390x" "riscv64"; do
    log_callout "Building ${TARGET_ARCH} docker image..."
    GOOS=linux GOARCH=${TARGET_ARCH} BINARYDIR=release/etcd-${VERSION}-linux-${TARGET_ARCH} BUILDDIR=release ./scripts/build-docker.sh "${VERSION}"
  done
popd >/dev/null
