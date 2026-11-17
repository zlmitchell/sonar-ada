#!/usr/bin/env bash
# Runs inside the build stage's base image, for download-deps.sh only (it mounts docker-deps at
# /deps): runs Alire and Maven once, with network, and packs what they fetched into /deps/seed
# for the Dockerfile, which then builds with none.
set -euo pipefail
. /deps/VERSIONS.txt

# CAs for the mirrors, then what Alire and the plugin's scripts need (repos: docker-deps)
cp -a /deps/ca-certs/. /etc/pki/ca-trust/source/anchors/ && rm -f /etc/pki/ca-trust/source/anchors/.gitkeep
update-ca-trust
cp -r /deps/yum.repos.d /tmp/repos   # writable: microdnf's subscription library writes redhat.repo
microdnf --setopt=reposdir=/tmp/repos install -y --nodocs --setopt=install_weak_deps=0 \
  git unzip tar gzip make glibc-devel gmp-devel perl-interpreter which
microdnf clean all

# Alire, its settings and cache in /opt/alire; dependencies next to libadalang (the plugin's
# scripts expect /opt/<crate>_<version>_<hash>); no index refresh when the build runs offline.
mkdir -p /opt/alire
unzip -q "/deps/bin/alr-$ALR_VERSION-bin-x86_64-linux.zip" -d /opt/alire
export ALIRE_SETTINGS_DIR=/opt/alire/settings PATH="/opt/alire/bin:$PATH"
alr -n settings --global --set cache.dir /opt/alire/cache
alr -n settings --global --set dependencies.shared false
alr -n settings --global --set index.auto_update 0
alr -n toolchain --select "gnat_native=$GNAT_VERSION" "gprbuild=$GPRBUILD_VERSION"
cd /opt
alr -n get "libadalang=$LIBADALANG_VERSION"
lal="$(basename /opt/libadalang_"$LIBADALANG_VERSION"_*)"
cd "/opt/$lal" && alr -n update

# Maven: the plugin's build, once, for every artifact it and its tests use. Its script installs
# libadalang's Java bindings first; the image builds those itself, so they're left out.
# which Maven mirror is in effect (none: Maven Central), without any credentials in its URL
sed '/<!--/,/-->/d' /root/.m2/settings.xml | grep -o '<url>[^<]*</url>' \
  | sed -E 's#</?url>##g; s#://[^/@]*@#://#; s#^#maven mirror: #' || echo "maven mirror: none"
mkdir -p /src && tar xzf "/deps/src/SonarAdaPlugin-$PLUGIN_COMMIT.tar.gz" -C /src --strip-components=1
ln -s /opt/"$lal"/alire/cache/dependencies/langkit_support_* /opt/
cd /src && ./scripts/install-local-libadalang.sh
mvn -B -q -P skip-native-tests package

tar czf /deps/seed/m2.tar.gz.part -C /src/.m2/repository --exclude=./com/adacore .
tar czf /deps/seed/alire.tar.gz.part -C / opt/alire "opt/$lal"
mv /deps/seed/m2.tar.gz.part /deps/seed/m2.tar.gz
mv /deps/seed/alire.tar.gz.part /deps/seed/alire.tar.gz
chown "${HOST_UID:-0}:${HOST_GID:-0}" /deps/seed/*.tar.gz
ls -l /deps/seed
