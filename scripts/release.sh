#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

source ./scripts/test_lib.sh
source ./scripts/release_mod.sh

DRY_RUN=${DRY_RUN:-true}

# Following preparation steps help with the release process: 

# If you use password-protected gpg key, make sure the password is managed
# by agent: 
#
# % gpg-connect-agent reloadagent /bye
# % gpg -s --default-key [git-email]@google.com -o /dev/null -s /dev/null
#
# Refresh your google credentials: 
#  % gcloud auth login
# or
#  % gcloud auth activate-service-account --key-file=gcp-key-etcd-development.json
#
# Make sure gcloud-docker plugin is configured: 
#  % gcloud auth configure-docker


help() {
  echo "$(basename "$0") [version]"
  echo "Release etcd using the same approach as the etcd-release-runbook (https://goo.gl/Gxwysq)"
  echo ""
  echo "WARNING: This does not perform the 'Add API capabilities', 'Performance testing' "
  echo "         or 'Documentation' steps. These steps must be performed manually BEFORE running this tool."
  echo ""
  echo "WARNING: This script does not sign releases, publish releases to github or sent announcement"
  echo "         emails. These steps must be performed manually AFTER running this tool."
  echo ""
  echo "  args:"
  echo "    version: version of etcd to release, e.g. 'v3.2.18'"
  echo "  flags:"
  echo "    --no-upload: skip gs://etcd binary artifact uploads."
  echo "    --no-docker-push: skip docker image pushes."
  echo "    --in-place: build binaries using current branch."
  echo ""
  echo "One can perform a (dry-run) test release from any (uncommitted) branch using:"
  echo "  DRY_RUN=true REPOSITORY=\`pwd\` BRANCH='local-branch-name' ./scripts/release 3.5.0-foobar.2"
}

main() {
  VERSION=$1
  if [[ ! "${VERSION}" =~ [0-9]+.[0-9]+.[0-9]+ ]]; then
    log_error "Expected 'version' param of the form '<major-version>.<minor-version>.<patch-version>' but got '${VERSION}'"
    exit 1
  fi
  RELEASE_VERSION="v${VERSION}"
  MINOR_VERSION=$(echo "${VERSION}" | cut -d. -f 1-2)

  if [ "${IN_PLACE}" == 1 ]; then
      # Trigger release in current branch
      REPOSITORY=$(pwd)
      BRANCH=$(git rev-parse --abbrev-ref HEAD)
  else
      REPOSITORY=${REPOSITORY:-"https://github.com/etcd-io/etcd.git"}
      BRANCH=${BRANCH:-"release-${MINOR_VERSION}"}
  fi

  log_warning "DRY_RUN=${DRY_RUN}"
  log_callout "RELEASE_VERSION=${RELEASE_VERSION}"
  log_callout "MINOR_VERSION=${MINOR_VERSION}"
  log_callout "BRANCH=${BRANCH}"
  log_callout "REPOSITORY=${REPOSITORY}"
  log_callout ""
  
  # Required to enable 'docker manifest ...'
  export DOCKER_CLI_EXPERIMENTAL=enabled

  if ! command -v docker >/dev/null; then
    log_error "cannot find docker"
    exit 1
  fi

  # Expected umask for etcd release artifacts
  umask 022

  # Set up release directory.
  local reldir="/tmp/etcd-release-${VERSION}"
  log_callout "Preparing temporary directory: ${reldir}"
  if [ ! -d "${reldir}/etcd" ] && [ "${IN_PLACE}" == 0 ]; then
    mkdir -p "${reldir}"
    cd "${reldir}"
    run git clone "${REPOSITORY}" --branch "${BRANCH}"
    run cd "${reldir}/etcd" || exit 2
    run git checkout "${BRANCH}" || exit 2
    run git pull origin

    git_assert_branch_in_sync || exit 2
  fi

  # mark local directory as root for test_lib scripts executions
  set_root_dir

  # If a release version tag already exists, use it.
  local remote_tag_exists
  remote_tag_exists=$(run git ls-remote origin "refs/tags/${RELEASE_VERSION}" | grep -c "${RELEASE_VERSION}" || true)

  if [ "${remote_tag_exists}" -gt 0 ]; then
    log_callout "Release version tag exists on remote. Checking out refs/tags/${RELEASE_VERSION}"
    git checkout -q "tags/${RELEASE_VERSION}"
  fi

  # Check go version.
  log_callout "Check go version"
  local go_version current_go_version
  go_version="go$(cat .go-version)"
  current_go_version=$(go version | awk '{ print $3 }')
  if [[ "${current_go_version}" != "${go_version}" ]]; then
    log_error "Current go version is ${current_go_version}, but etcd ${RELEASE_VERSION} requires ${go_version} (see .go-version)."
    exit 1
  fi

  # If the release tag does not already exist remotely, create it.
  log_callout "Create tag if not present"
  if [ "${remote_tag_exists}" -eq 0 ]; then
    # Bump version/version.go to release version.
    local source_version
    source_version=$(grep -E "\s+Version\s*=" api/version/version.go | sed -e "s/.*\"\(.*\)\".*/\1/g")
    if [[ "${source_version}" != "${VERSION}" ]]; then
      source_minor_version=$(echo "${source_version}" | cut -d. -f 1-2)
      if [[ "${source_minor_version}" != "${MINOR_VERSION}" ]]; then
        log_error "Wrong etcd minor version in api/version/version.go. Expected ${MINOR_VERSION} but got ${source_minor_version}. Aborting."
        exit 1
      fi
      log_callout "Updating modules definitions"
      TARGET_VERSION="v${VERSION}" update_versions_cmd

      log_callout "Updating version from ${source_version} to ${VERSION} in api/version/version.go"
      sed -i "s/${source_version}/${VERSION}/g" api/version/version.go
    fi


    log_callout "Building etcd and checking --version output"
    run ./scripts/build.sh
    local etcd_version
    etcd_version=$(bin/etcd --version | grep "etcd Version" | awk '{ print $3 }')
    if [[ "${etcd_version}" != "${VERSION}" ]]; then
      log_error "Wrong etcd version in version/version.go. Expected ${etcd_version} but got ${VERSION}. Aborting."
      exit 1
    fi

    if [[ -n $(git status -s) ]]; then
      log_callout "Committing mods & api/version/version.go update."
      run git add api/version/version.go
      # shellcheck disable=SC2038,SC2046
      run git add $(find . -name go.mod ! -path './release/*'| xargs)
      run git diff --staged | cat
      run git commit -m "version: bump up to ${VERSION}"
      run git diff --staged | cat
    fi

    # Push the version change if it's not already been pushed.
    if [ "${DRY_RUN}" != "true" ] && [ "$(git rev-list --count "origin/${BRANCH}..${BRANCH}")" -gt 0 ]; then
      read -p "Push version bump up to ${VERSION} to '$(git remote get-url origin)' [y/N]? " -r confirm
      [[ "${confirm,,}" == "y" ]] || exit 1
      maybe_run git push
    fi

    # Tag release.
    if [ "$(git tag --list | grep -c "${RELEASE_VERSION}")" -gt 0 ]; then
      log_callout "Skipping tag step. git tag ${RELEASE_VERSION} already exists."
    else
      log_callout "Tagging release..."
      REMOTE_REPO="origin" push_mod_tags_cmd
    fi

    if [ "${IN_PLACE}" == 0 ]; then
      # Tried with `local branch=$(git branch -a --contains tags/"${RELEASE_VERSION}")`
      # so as to work with both current branch and main/release-3.X.
      # But got error below on current branch mode,
      # Error: Git tag v3.6.99 should be on branch '* (HEAD detached at pull/14860/merge)' but is on '* (HEAD detached from pull/14860/merge)'
      #
      # Verify the version tag is on the right branch
      # shellcheck disable=SC2155
      local branch=$(git for-each-ref --contains "${RELEASE_VERSION}" --format="%(refname)" 'refs/heads' | cut -d '/' -f 3)
      if [ "${branch}" != "${BRANCH}" ]; then
        log_error "Error: Git tag ${RELEASE_VERSION} should be on branch '${BRANCH}' but is on '${branch}'"
        exit 1
      fi
    fi
  fi

  log_callout "Verify the latest commit has the version tag"
  # Verify the latest commit has the version tag
  # shellcheck disable=SC2155
  local tag="$(git describe --exact-match HEAD)"
  if [ "${tag}" != "${RELEASE_VERSION}" ]; then
    log_error "Error: Expected HEAD to be tagged with ${RELEASE_VERSION}, but 'git describe --exact-match HEAD' reported: ${tag}"
    exit 1
  fi

  log_callout "Verify the work space is clean"
  # Verify the clean working tree
  # shellcheck disable=SC2155
  local diff="$(git diff HEAD --stat)"
  if [[ "${diff}" != '' ]]; then
    log_error "Error: Expected clean working tree, but 'git diff --stat' reported: ${diff}"
    exit 1
  fi

  # Build release.
  # TODO: check the release directory for all required build artifacts.
  if [ -d release ]; then
    log_warning "Skipping release build step. /release directory already exists."
  else
    log_callout "Building release..."
    REPOSITORY=$(pwd) ./scripts/build-release.sh "${RELEASE_VERSION}"
  fi

  # Sanity checks.
  "./release/etcd-${RELEASE_VERSION}-$(go env GOOS)-amd64/etcd" --version | grep -q "etcd Version: ${VERSION}" || true
  "./release/etcd-${RELEASE_VERSION}-$(go env GOOS)-amd64/etcdctl" version | grep -q "etcdctl version: ${VERSION}" || true
  "./release/etcd-${RELEASE_VERSION}-$(go env GOOS)-amd64/etcdutl" version | grep -q "etcdutl version: ${VERSION}" || true

  # Generate SHA256SUMS
  log_callout "Generating sha256sums of release artifacts."
  pushd ./release
  # shellcheck disable=SC2010
  ls . | grep -E '\.tar.gz$|\.zip$' | xargs shasum -a 256 > ./SHA256SUMS
  popd
  if [ -s ./release/SHA256SUMS ]; then
    cat ./release/SHA256SUMS
  else
    log_error "sha256sums is not valid. Aborting."
    exit 1
  fi

  # Upload artifacts.
  if [ "${DRY_RUN}" == "true" ] || [ "${NO_UPLOAD}" == 1 ]; then
    log_callout "Skipping artifact upload to gs://etcd. --no-upload flat is set."
  else
    read -p "Upload etcd ${RELEASE_VERSION} release artifacts to gs://etcd [y/N]? " -r confirm
    [[ "${confirm,,}" == "y" ]] || exit 1
    maybe_run gsutil -m cp ./release/SHA256SUMS "gs://etcd/${RELEASE_VERSION}/"
    maybe_run gsutil -m cp ./release/*.zip "gs://etcd/${RELEASE_VERSION}/"
    maybe_run gsutil -m cp ./release/*.tar.gz "gs://etcd/${RELEASE_VERSION}/"
    maybe_run gsutil -m acl ch -u allUsers:R -r "gs://etcd/${RELEASE_VERSION}/"
  fi

  # Push images.
  if [ "${DRY_RUN}" == "true" ] || [ "${NO_DOCKER_PUSH}" == 1 ]; then
    log_callout "Skipping docker push. --no-docker-push flat is set."
  else
    read -p "Publish etcd ${RELEASE_VERSION} docker images to quay.io [y/N]? " -r confirm
    [[ "${confirm,,}" == "y" ]] || exit 1
    # shellcheck disable=SC2034
    for i in {1..5}; do
      docker login quay.io && break
      log_warning "login failed, retrying"
    done

    for TARGET_ARCH in "amd64" "arm64" "ppc64le" "s390x" "riscv64"; do
      log_callout "Pushing container images to quay.io ${RELEASE_VERSION}-${TARGET_ARCH}"
      maybe_run docker push "quay.io/coreos/etcd:${RELEASE_VERSION}-${TARGET_ARCH}"
      log_callout "Pushing container images to gcr.io ${RELEASE_VERSION}-${TARGET_ARCH}"
      maybe_run docker push "gcr.io/etcd-development/etcd:${RELEASE_VERSION}-${TARGET_ARCH}"
    done

    log_callout "Creating manifest-list (multi-image)..."

    for TARGET_ARCH in "amd64" "arm64" "ppc64le" "s390x" "riscv64"; do
      maybe_run docker manifest create --amend "quay.io/coreos/etcd:${RELEASE_VERSION}" "quay.io/coreos/etcd:${RELEASE_VERSION}-${TARGET_ARCH}"
      maybe_run docker manifest annotate "quay.io/coreos/etcd:${RELEASE_VERSION}" "quay.io/coreos/etcd:${RELEASE_VERSION}-${TARGET_ARCH}" --arch "${TARGET_ARCH}"

      maybe_run docker manifest create --amend "gcr.io/etcd-development/etcd:${RELEASE_VERSION}" "gcr.io/etcd-development/etcd:${RELEASE_VERSION}-${TARGET_ARCH}"
      maybe_run docker manifest annotate "gcr.io/etcd-development/etcd:${RELEASE_VERSION}" "gcr.io/etcd-development/etcd:${RELEASE_VERSION}-${TARGET_ARCH}" --arch "${TARGET_ARCH}"
    done

    log_callout "Pushing container manifest list to quay.io ${RELEASE_VERSION}"
    maybe_run docker manifest push "quay.io/coreos/etcd:${RELEASE_VERSION}"

    log_callout "Pushing container manifest list to gcr.io ${RELEASE_VERSION}"
    maybe_run docker manifest push "gcr.io/etcd-development/etcd:${RELEASE_VERSION}"

    log_callout "Setting permissions using gsutil..."
    maybe_run gsutil -m acl ch -u allUsers:R -r gs://artifacts.etcd-development.appspot.com
  fi

  ### Release validation
  mkdir -p downloads

  # Check image versions
  for IMAGE in "quay.io/coreos/etcd:${RELEASE_VERSION}" "gcr.io/etcd-development/etcd:${RELEASE_VERSION}"; do
    if [ "${DRY_RUN}" == "true" ] || [ "${NO_DOCKER_PUSH}" == 1 ]; then
      IMAGE="${IMAGE}-amd64"
    fi
    # shellcheck disable=SC2155
    local image_version=$(docker run --rm "${IMAGE}" etcd --version | grep "etcd Version" | awk -F: '{print $2}' | tr -d '[:space:]')
    if [ "${image_version}" != "${VERSION}" ]; then
      log_error "Check failed: etcd --version output for ${IMAGE} is incorrect: ${image_version}"
      exit 1
    fi
  done

  # Check gsutil binary versions
  # shellcheck disable=SC2155
  local BINARY_TGZ="etcd-${RELEASE_VERSION}-$(go env GOOS)-amd64.tar.gz"
  if [ "${DRY_RUN}" == "true" ] || [ "${NO_UPLOAD}" == 1 ]; then
    cp "./release/${BINARY_TGZ}" downloads
  else
    gsutil cp "gs://etcd/${RELEASE_VERSION}/${BINARY_TGZ}" downloads
  fi
  tar -zx -C downloads -f "downloads/${BINARY_TGZ}"
  # shellcheck disable=SC2155
  local binary_version=$("./downloads/etcd-${RELEASE_VERSION}-$(go env GOOS)-amd64/etcd" --version | grep "etcd Version" | awk -F: '{print $2}' | tr -d '[:space:]')
  if [ "${binary_version}" != "${VERSION}" ]; then
    log_error "Check failed: etcd --version output for ${BINARY_TGZ} from gs://etcd/${RELEASE_VERSION} is incorrect: ${binary_version}"
    exit 1
  fi

  # TODO: signing process
  log_warning ""
  log_warning "WARNING: The release has not been signed and published to github. This must be done manually."
  log_warning ""
  log_success "Success."
  exit 0
}

POSITIONAL=()
NO_UPLOAD=0
NO_DOCKER_PUSH=0
IN_PLACE=0

while test $# -gt 0; do
        case "$1" in
          -h|--help)
            shift
            help
            exit 0
            ;;
          --in-place)
            IN_PLACE=1
            shift
            ;;
          --no-upload)
            NO_UPLOAD=1
            shift
            ;;
          --no-docker-push)
            NO_DOCKER_PUSH=1
            shift
            ;;
          *)
            POSITIONAL+=("$1") # save it in an array for later
            shift # past argument
            ;;
        esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

if [[ ! $# -eq 1 ]]; then
  help
  exit 1
fi

# Note that we shouldn't upload artifacts in --in-place mode, so it
# must be called with DRY_RUN=true
if [ "${DRY_RUN}" != "true" ] && [ "${IN_PLACE}" == 1 ]; then
   log_error "--in-place should only be called with DRY_RUN=true"
   exit 1
fi

main "$1"
