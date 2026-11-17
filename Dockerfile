# SonarAdaPlugin (github.com/mmartign/SonarAdaPlugin, GPL-3.0), which publishes no jar, built
# with the libadalang it needs. Two images from one build:
#
#   ./download-deps.sh
#   docker build --target plugins -t sonar-ada-plugins .
#   docker build --target scanner -t sonar-scanner-ada .
#
# plugins: the plugin jar under /plugins on ubi-minimal (sh, curl) for the SonarQube Helm chart's
#   plugins.image: its plugin init container runs it and installs
#   file:///plugins/sonar-ada-plugin-<version>.jar with the rest. The jar carries libadalang's
#   Java bindings; the server needs nothing else.
# Both carry the plugin's source they were built from in /opt/sonar-ada/src (GPL-3.0).
# scanner: a CI image to analyze Ada. SonarScanner CLI on Red Hat's OpenJDK 21 runtime (UBI 9),
#   libadalang's native library and its dependencies in /opt/libadalang-jni-libs, and the
#   plugin's wrapper as `sonar-scanner-ada`, which preloads HotSpot's libjsig (GNAT and HotSpot
#   both handle SIGSEGV) and puts that folder on the library path. Plain `sonar-scanner` works
#   for projects without Ada. Red Hat's OpenJDK follows the host's FIPS mode.
#
# docker-deps/: download-deps.sh puts every download there
# first (the versions live in that script), and after the RPM installs every step here runs
# with --network=none. The RPM repos are docker-deps/yum.repos.d, which download-deps.sh writes
# (Red Hat's CDN, or UBI_REPO_BASEURL), the only repos microdnf reads; docker-deps/ca-certs are
# trusted by the build and baked into the scanner image. Base images: registry.access.redhat.com, or
# UBI_REGISTRY. RUN --mount needs BuildKit, or podman/buildah (privileged in a pod). No
# `# syntax=` line: BuildKit would fetch that frontend image from docker.io.
#
# The build compiles libadalang and its closure (GNAT 15 from Alire) as shared libraries: about
# 20 minutes with 16 cores and 12G for Docker (BUILD_JOBS=6). It runs the plugin's tests, the
# native ones included. Build new tags after changing a version in download-deps.sh.
# In GitHub Actions: .github/workflows/build.yml.

ARG UBI_REGISTRY=registry.access.redhat.com

FROM ${UBI_REGISTRY}/ubi9/openjdk-21:1.24-3.1794341133 AS build
# parallel compiles: libadalang's largest units need several GB each
ARG BUILD_JOBS=6
USER 0
# the seed's paths: Alire's settings and cache in /opt/alire (download-deps.sh, seed-deps.sh)
ENV HOME=/root ALIRE_SETTINGS_DIR=/opt/alire/settings PATH=/opt/alire/bin:$PATH MAVEN_ARGS=-o

COPY docker-deps/ca-certs/ /etc/pki/ca-trust/source/anchors/
RUN update-ca-trust
# RPMs only from docker-deps/yum.repos.d: microdnf reads that folder alone (reposdir), a copy
# made writable for the redhat.repo its subscription library writes, gone with the step.
RUN --mount=type=bind,source=docker-deps/yum.repos.d/,target=/tmp/repos.d/,ro \
    cp -r /tmp/repos.d /tmp/repos \
 && microdnf --setopt=reposdir=/tmp/repos install -y --nodocs --setopt=install_weak_deps=0 \
      unzip tar gzip make glibc-devel gmp-devel file perl-interpreter which \
 && microdnf clean all && rm -rf /tmp/repos

# From here on, only docker-deps: Alire with libadalang's sources, the plugin's source and its
# Maven artifacts, the scanner.
RUN --network=none --mount=type=bind,source=docker-deps/,target=/deps/,ro \
    . /deps/VERSIONS.txt \
 && tar xzf /deps/seed/alire.tar.gz -C / \
 && ln -s /opt/libadalang_${LIBADALANG_VERSION}_* /opt/libadalang \
 && ln -s /opt/libadalang/alire/cache/dependencies/langkit_support_* /opt/ \
 && mkdir -p /src/.m2/repository \
 && tar xzf /deps/src/SonarAdaPlugin-${PLUGIN_COMMIT}.tar.gz -C /src --strip-components=1 \
 && tar xzf /deps/seed/m2.tar.gz -C /src/.m2/repository \
 && unzip -q /deps/bin/sonar-scanner-cli-${SCANNER_VERSION}.zip -d /opt \
 && mv /opt/sonar-scanner-${SCANNER_VERSION} /opt/sonar-scanner \
 && mkdir -p /opt/sonar-ada/src \
 && cp /deps/VERSIONS.txt /opt/sonar-ada/ \
 && cp /deps/src/SonarAdaPlugin-${PLUGIN_COMMIT}.tar.gz /opt/sonar-ada/src/

# Shared libraries, the whole closure: a JNI library can't link static Ada libraries.
WORKDIR /opt/libadalang
RUN --network=none LIBRARY_TYPE=relocatable XMLADA_BUILD=relocatable LIBADALANG_LIBRARY_TYPE=relocatable \
    alr -n build --release -- -j${BUILD_JOBS} \
 && ls lib/relocatable/prod/libadalang.so

# The Java bindings target Java 24: the plugin's own script retargets them to 21 and installs
# them for its build. The JNI bridge includes the header javac -h writes for the same source.
RUN --network=none cd /src && ./scripts/install-local-libadalang.sh
RUN --network=none cp -r java/src/main/java /tmp/lal-src \
 && perl -pi -e 's/StandardCharsets\.UTF_32BE/Charset.forName("UTF-32BE")/g; s/StandardCharsets\.UTF_32LE/Charset.forName("UTF-32LE")/g' \
    /tmp/lal-src/com/adacore/libadalang/Libadalang.java \
 && javac -J-Xmx4g --release 21 -nowarn -h java/jni -d /tmp/lal-classes \
    -cp "$(find /src/.m2/repository -name '*.jar' ! -name 'libadalang-*' | paste -sd:)" $(find /tmp/lal-src -name '*.java') \
 && alr -n exec -- make -C java LIBADALANG_BUILD_MODE=prod JAVA_HOME=$JAVA_HOME \
    C_OPT="-fPIC -g -Wall -O2 -I$JAVA_HOME/include -I$JAVA_HOME/include/linux -I/opt/libadalang/src" \
 && rm -rf /tmp/lal-src /tmp/lal-classes

# libadalang_jni.so and every library it loads but glibc's, stripped (167M to 80M). The folder
# must be complete on its own: the wrapper's LD_LIBRARY_PATH is all that finds them.
RUN --network=none mkdir /opt/libadalang-jni-libs && cp java/jni/libadalang_jni.so /opt/libadalang-jni-libs/ \
 && LD_LIBRARY_PATH=$(find /opt/libadalang/ /opt/alire/cache/ -name '*.so*' -printf '%h\n' | sort -u | paste -sd:) \
    ldd /opt/libadalang-jni-libs/libadalang_jni.so | tee /tmp/ldd.txt && ! grep 'not found' /tmp/ldd.txt \
 && awk '$3 ~ /^\// {print $3}' /tmp/ldd.txt \
    | grep -v -E '/(libc|libm|libdl|librt|libpthread|ld-linux[^/]*)\.so' \
    | xargs -r cp -L -t /opt/libadalang-jni-libs/ \
 && $(ls /opt/alire/cache/toolchains/gnat_native_*/bin/strip) --strip-unneeded /opt/libadalang-jni-libs/*.so* \
 && ! LD_LIBRARY_PATH=/opt/libadalang-jni-libs ldd /opt/libadalang-jni-libs/libadalang_jni.so | grep 'not found' \
 && ls /opt/libadalang-jni-libs

# the plugin, with every test: the native one loads libadalang_jni.so from there
WORKDIR /src
RUN --network=none LD_PRELOAD=$JAVA_HOME/lib/libjsig.so MAVEN_OPTS=-XX:+UseSignalChaining mvn -B -q package \
 && ls target/sonar-ada-plugin-*.jar

FROM ${UBI_REGISTRY}/ubi9/ubi-minimal:9.9-1794467051 AS plugins
ARG VERSION=dev
LABEL org.opencontainers.image.title="sonar-ada-plugins" \
      org.opencontainers.image.description="SonarAdaPlugin (github.com/mmartign/SonarAdaPlugin) for SonarQube's plugin init container (the Helm chart's plugins.image)" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"
COPY --from=build --chown=1000:0 /src/target/sonar-ada-plugin-*.jar /plugins/
# what it was built from: download-deps.sh's versions and the plugin's source
COPY --from=build /opt/sonar-ada/ /opt/sonar-ada/
USER 1000

FROM ${UBI_REGISTRY}/ubi9/openjdk-21-runtime:1.24-3.1794341129 AS scanner
ARG VERSION=dev
LABEL org.opencontainers.image.title="sonar-scanner-ada" \
      org.opencontainers.image.description="SonarScanner CLI with libadalang for SonarAdaPlugin (sonar-scanner-ada)" \
      org.opencontainers.image.version="${VERSION}"
USER 0
COPY docker-deps/ca-certs/ /etc/pki/ca-trust/source/anchors/
RUN update-ca-trust
# git: the scanner's SCM data (blame, new code)
RUN --mount=type=bind,source=docker-deps/yum.repos.d/,target=/tmp/repos.d/,ro \
    cp -r /tmp/repos.d /tmp/repos \
 && microdnf --setopt=reposdir=/tmp/repos install -y --nodocs --setopt=install_weak_deps=0 git \
 && microdnf clean all && rm -rf /tmp/repos
COPY --from=build /opt/sonar-scanner /opt/sonar-scanner
COPY --from=build /opt/libadalang-jni-libs /opt/libadalang-jni-libs
COPY --from=build /src/scripts/sonar-scanner-linux.sh /src/scripts/ensure-libiconv-linux.sh /opt/sonar-ada/
COPY --from=build /opt/sonar-ada/ /opt/sonar-ada/
COPY --from=build /src/target/sonar-ada-plugin-*.jar /plugins/
# The engine runs in this JVM, with the wrapper's libjsig and library path; a JRE downloaded
# from the server would start a second JVM without them. A launcher, not a symlink: the wrapper
# finds its helper script next to the path it was started by.
RUN --network=none printf '#!/bin/sh\nexec /opt/sonar-ada/sonar-scanner-linux.sh "$@"\n' > /usr/local/bin/sonar-scanner-ada \
 && chmod 755 /usr/local/bin/sonar-scanner-ada \
 && ln -s /opt/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner \
 && echo 'sonar.scanner.skipJreProvisioning=true' >> /opt/sonar-scanner/conf/sonar-scanner.properties
ENV SONAR_USER_HOME=/tmp/.sonar
# the image's own non-root user
USER 185
