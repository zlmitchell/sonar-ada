#!/usr/bin/env bash
# Fetches everything the sonar-ada build would otherwise download into docker-deps/, so the
# Dockerfile reaches nothing but the RPM repos in docker-deps/yum.repos.d:
#
#   yum.repos.d/ubi9.repo                        those repos, written on every run (UBI_REPO_*)
#   bin/alr-<version>-bin-x86_64-linux.zip       Alire, which builds libadalang
#   bin/sonar-scanner-cli-<version>.zip          SonarScanner CLI, for the scanner image
#   src/SonarAdaPlugin-<commit>.tar.gz           the plugin's source
#   seed/alire.tar.gz                            Alire with its settings, index and GNAT toolchain,
#                                                and libadalang with every crate it needs (sources)
#   seed/m2.tar.gz                               every Maven artifact the plugin's build uses
#   VERSIONS.txt                                 what all of the above are; the Dockerfile reads it
#
# The seeds come from seed-deps.sh, which runs Alire and Maven once in the build's own base
# image (the Dockerfile's build stage), with docker-deps' repos, CAs and Maven settings, so a
# mirror set there serves this step too. They're remade when a version below changes.
#
#   ./download-deps.sh             # skips what's already there
#   FORCE=1 ./download-deps.sh     # fetches everything again
#
# Environment:
#   UBI_REPO_BASEURL    a UBI 9 RPM mirror serving <base>/{baseos,appstream,codeready-builder}/os
#                       (default: Red Hat's CDN). UBI_REPO_GPGCHECK: 0 or 1 (default 1, or 0 with
#                       a mirror)
#   DEPS_MIRROR_BASE    fetch bin/ and src/ files as <base>/<file name> instead of upstream
#   CONTAINER_RUNTIME   docker (default) or podman, for the seed
#   UBI_REGISTRY        a mirror for the base image (default registry.access.redhat.com)
#   MAVEN_SETTINGS_CONTENT  a whole settings.xml for the seed's Maven, instead of
#                       docker-deps/maven/settings.xml (written to a temp file, deleted after)
#   ARTIFACTORY_URL, ARTIFACTORY_USER, ARTIFACTORY_TOKEN    passed on to the seed, for a
#                       settings.xml that reads them (${env.ARTIFACTORY_URL}: the committed example)
#   HTTP_PROXY, HTTPS_PROXY, NO_PROXY    passed on to the seed
#   and each version below
set -euo pipefail

# Versions: the one place to change them. The plugin's own pom pins libadalang.
ALR_VERSION="${ALR_VERSION:-2.1.1}"
GNAT_VERSION="${GNAT_VERSION:-15.3.1}"            # Alire's gnat_native
GPRBUILD_VERSION="${GPRBUILD_VERSION:-26.0.1}"
SCANNER_VERSION="${SCANNER_VERSION:-8.5.0.16571}"
PLUGIN_URL="${PLUGIN_URL:-https://github.com/mmartign/SonarAdaPlugin}"
PLUGIN_COMMIT="${PLUGIN_COMMIT:-b49002e8b25b785264cb795298ef51ecab81beaf}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPS="$DIR/docker-deps"
UBI_REGISTRY="${UBI_REGISTRY:-registry.access.redhat.com}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"
FORCE="${FORCE:-0}"

# The seed must match the build stage's image (same paths, same glibc), so read it from there.
BUILD_IMAGE="$UBI_REGISTRY/$(sed -n 's|^FROM ${UBI_REGISTRY}/\([^ ]*\) AS build$|\1|p' "$DIR/Dockerfile")"
[ "$BUILD_IMAGE" != "$UBI_REGISTRY/" ] || { echo "no build stage FROM in $DIR/Dockerfile" >&2; exit 1; }

# fetch <url> <dest>: skip when present, unless FORCE=1
fetch() {
  local url="$1" dest="$2"
  if [ -s "$dest" ] && [ "$FORCE" != 1 ]; then
    echo "have  $(basename "$dest")"
    return
  fi
  [ -z "${DEPS_MIRROR_BASE:-}" ] || url="${DEPS_MIRROR_BASE%/}/$(basename "$dest")"
  echo "fetch $url"
  curl -fsSL --retry 3 -o "$dest.part" "$url"
  mv "$dest.part" "$dest"
}

# a host path the container runtime understands (Git Bash on Windows needs C:\...)
hostpath() { if command -v cygpath >/dev/null; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

mkdir -p "$DEPS/bin" "$DEPS/src" "$DEPS/seed" "$DEPS/yum.repos.d"

# The only repos microdnf reads, in the Dockerfile and the seed. Written rather than committed, so
# a mirror (and any login in its URL) lives in the environment, not in git.
if [ -n "${UBI_REPO_BASEURL:-}" ]; then
  base="${UBI_REPO_BASEURL%/}" gpg="${UBI_REPO_GPGCHECK:-0}" from="UBI_REPO_BASEURL"
else
  base='https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/$basearch'
  gpg="${UBI_REPO_GPGCHECK:-1}" from="Red Hat's CDN"
fi
{
  echo "# written by download-deps.sh ($from); not committed"
  for r in baseos:BaseOS appstream:AppStream "codeready-builder:CodeReady Builder"; do
    printf '\n[ubi-9-%s-rpms]\nname = UBI 9 - %s\nbaseurl = %s/%s/os\nenabled = 1\n' \
      "${r%%:*}" "${r#*:}" "$base" "${r%%:*}"
    printf 'gpgkey = file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release\ngpgcheck = %s\n' "$gpg"
  done
} > "$DEPS/yum.repos.d/ubi9.repo"
echo "wrote yum.repos.d/ubi9.repo ($from, gpgcheck $gpg)"

fetch "https://github.com/alire-project/alire/releases/download/v$ALR_VERSION/alr-$ALR_VERSION-bin-x86_64-linux.zip" \
  "$DEPS/bin/alr-$ALR_VERSION-bin-x86_64-linux.zip"
fetch "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-$SCANNER_VERSION.zip" \
  "$DEPS/bin/sonar-scanner-cli-$SCANNER_VERSION.zip"
fetch "$PLUGIN_URL/archive/$PLUGIN_COMMIT.tar.gz" "$DEPS/src/SonarAdaPlugin-$PLUGIN_COMMIT.tar.gz"

pom="$(tar xzf "$DEPS/src/SonarAdaPlugin-$PLUGIN_COMMIT.tar.gz" --wildcards -O '*/pom.xml')"
PLUGIN_VERSION="$(sed -n '0,/<version>/s:.*<version>\([^<]*\)</version>.*:\1:p' <<<"$pom")"
LIBADALANG_VERSION="$(sed -n 's:.*<libadalang.version>\([0-9.]*\)-.*:\1:p' <<<"$pom")"
[ -n "$PLUGIN_VERSION" ] && [ -n "$LIBADALANG_VERSION" ] || { echo "can't read versions from the plugin's pom.xml" >&2; exit 1; }

versions="ALR_VERSION=$ALR_VERSION
GNAT_VERSION=$GNAT_VERSION
GPRBUILD_VERSION=$GPRBUILD_VERSION
SCANNER_VERSION=$SCANNER_VERSION
PLUGIN_COMMIT=$PLUGIN_COMMIT
PLUGIN_VERSION=$PLUGIN_VERSION
LIBADALANG_VERSION=$LIBADALANG_VERSION
BUILD_IMAGE=${BUILD_IMAGE#"$UBI_REGISTRY/"}"

# New versions mean new seeds.
if [ "$FORCE" = 1 ] || [ "$(cat "$DEPS/VERSIONS.txt" 2>/dev/null)" != "$versions" ] \
   || [ ! -s "$DEPS/seed/alire.tar.gz" ] || [ ! -s "$DEPS/seed/m2.tar.gz" ]; then
  rm -f "$DEPS/seed/alire.tar.gz" "$DEPS/seed/m2.tar.gz" "$DEPS/VERSIONS.txt"
  printf '%s\n' "$versions" > "$DEPS/VERSIONS.txt.new"
  mv "$DEPS/VERSIONS.txt.new" "$DEPS/VERSIONS.txt"
  # the seed's Maven settings: MAVEN_SETTINGS_CONTENT (may hold credentials: a temp file outside
  # docker-deps, gone afterwards), else the committed file
  settings="$DEPS/maven/settings.xml"
  if [ -n "${MAVEN_SETTINGS_CONTENT:-}" ]; then
    settings="$(mktemp)"
    trap 'rm -f "$settings"' EXIT
    printf '%s\n' "$MAVEN_SETTINGS_CONTENT" > "$settings"
  fi
  echo "seed  Alire, libadalang $LIBADALANG_VERSION and Maven in $BUILD_IMAGE (about 8 minutes)"
  MSYS_NO_PATHCONV=1 "$CONTAINER_RUNTIME" run --rm --user 0 --entrypoint bash \
    -v "$(hostpath "$DEPS"):/deps" \
    -v "$(hostpath "$settings"):/root/.m2/settings.xml:ro" \
    -v "$(hostpath "$DIR/seed-deps.sh"):/seed-deps.sh:ro" \
    -e HOME=/root -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -e ARTIFACTORY_URL -e ARTIFACTORY_USER -e ARTIFACTORY_TOKEN \
    -e HTTP_PROXY -e HTTPS_PROXY -e NO_PROXY -e http_proxy -e https_proxy -e no_proxy \
    "$BUILD_IMAGE" /seed-deps.sh
else
  echo "have  seed/alire.tar.gz, seed/m2.tar.gz"
fi

echo "done:"
( cd "$DEPS" && ls -l VERSIONS.txt bin/*.zip src/*.tar.gz seed/*.tar.gz )
