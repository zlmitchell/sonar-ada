# sonar-ada

Container images for [SonarAdaPlugin](https://github.com/mmartign/SonarAdaPlugin), the SonarQube
plugin for Ada. The plugin publishes no jar, and its analysis runs libadalang (AdaCore's Ada front
end, native code) inside the scanner. This repo builds both halves from one build: the plugin
with the libadalang it needs, and a scanner that can load it.

| image | for | holds |
|---|---|---|
| `ghcr.io/zlmitchell/sonar-ada-plugins` (about 110 MB) | SonarQube's plugin install | the jar, with libadalang's Java bindings, under `/plugins` on UBI 9 minimal |
| `ghcr.io/zlmitchell/sonar-scanner-ada` (about 580 MB) | CI jobs that scan Ada | SonarScanner CLI on Red Hat's OpenJDK 21 runtime (UBI 9), libadalang's native libraries, and the plugin's wrapper as `sonar-scanner-ada` |

Tags: the plugin's version (`1.15.0`, rebuilt in place when a base image or the scanner moves),
`latest`, and `sha-<commit>` of this repo. `/opt/sonar-ada/VERSIONS.txt` in each image says what
it was built from, and `/opt/sonar-ada/src/` holds the plugin's source.

## Use

### SonarQube

With the [SonarQube Helm chart](https://github.com/SonarSource/helm-chart-sonarqube), the plugin
init container runs `plugins.image`, so point it at this image and install the jar from it. Other
plugins in the list still download with its curl.

```yaml
plugins:
  image: ghcr.io/zlmitchell/sonar-ada-plugins:1.15.0
  install:
    - file:///plugins/sonar-ada-plugin-1.15.0.jar
```

Without the chart, copy `/plugins/sonar-ada-plugin-<version>.jar` into
`extensions/plugins/` and restart. Tested on SonarQube Community Build 26.9.

### Scanning

Scan Ada with `sonar-scanner-ada`, the plugin's own wrapper. GNAT's code and HotSpot both handle
SIGSEGV, so it preloads HotSpot's `libjsig.so` with `-XX:+UseSignalChaining`, and puts libadalang
on the library path. Plain `sonar-scanner` fails in the Ada sensor (`UnsatisfiedLinkError: no
adalang_jni`) but works for projects without Ada; SonarQube only sends the plugin to scans of
projects with Ada files.

```yaml
# GitLab CI
ada-scan:
  image: ghcr.io/zlmitchell/sonar-scanner-ada:1.15.0
  script:
    - sonar-scanner-ada -Dsonar.host.url=$SONAR_HOST_URL -Dsonar.token=$SONAR_TOKEN -Dsonar.projectKey=<key>
```

```sh
docker run --rm -v "$PWD:/src" -w /src ghcr.io/zlmitchell/sonar-scanner-ada:1.15.0 \
  sonar-scanner-ada -Dsonar.host.url=https://sonar.example.com -Dsonar.token=... -Dsonar.projectKey=<key>
```

- The image sets `sonar.scanner.skipJreProvisioning`: a JRE downloaded from the server would run
  the analysis in a second JVM, without the wrapper's settings.
- It runs as uid 185 with `SONAR_USER_HOME=/tmp/.sonar`. Behind a private CA, the scanner trusts a
  PKCS12 store at `/tmp/.sonar/ssl/truststore.p12` (password `changeit`), or the one
  `-Dsonar.scanner.truststorePath` names.
- Red Hat's OpenJDK switches to FIPS mode on a FIPS host, and the scan still works there.
- The plugin's optional AdaControl and AdaLang Analyzer integrations run those tools from the
  scanner, which has neither.

## Build

```sh
./download-deps.sh
docker build --target plugins -t sonar-ada-plugins .
docker build --target scanner -t sonar-scanner-ada .
```

`download-deps.sh` fetches everything into `docker-deps/` first, and the build itself downloads
nothing: past the RPM installs, every step runs with `--network=none`. It compiles libadalang and
its closure (GNAT 15 from Alire) as shared libraries, about 20 minutes on 16 cores with 12 GB for
Docker (`--build-arg BUILD_JOBS=6`; each job can take 2 GB), and runs the plugin's tests, the
native ones included. It needs BuildKit (or podman/buildah) for `RUN --mount`.

`download-deps.sh` needs github.com, Alire's index, binaries.sonarsource.com, Maven Central and
the UBI repos, plus Docker or podman to make the seed. On a machine without internet, copy
`docker-deps/` over from one that has it and build there.

| in `docker-deps/` | what it is |
|---|---|
| `yum.repos.d/ubi9.repo` | the only repos `microdnf` reads, written on every run: Red Hat's UBI 9 CDN, or `UBI_REPO_BASEURL` |
| `ca-certs/` (empty) | CAs for your mirrors: trusted by the build, and baked into the scanner image |
| `maven/settings.xml` (empty) | the seed's Maven mirror (an Artifactory example is in its comment) |
| `bin/`, `src/` | Alire, SonarScanner CLI and the plugin's source |
| `seed/` (about 560 MB) | Alire's GNAT toolchain and index with libadalang's crate sources, and the Maven artifacts of the plugin's build. `seed-deps.sh` makes them by running Alire and Maven once in the build's base image |
| `VERSIONS.txt` | what all of it is |

The versions live in `download-deps.sh`, and the seed is remade when one changes. Behind a
firewall:

| variable | for |
|---|---|
| `UBI_REGISTRY` | a mirror of `registry.access.redhat.com` for the base images (also a `--build-arg`) |
| `UBI_REPO_BASEURL`, `UBI_REPO_GPGCHECK` | a UBI 9 RPM mirror serving `baseos/os`, `appstream/os` and `codeready-builder/os`; gpgcheck defaults to 0 with a mirror |
| `DEPS_MIRROR_BASE` | fetch `bin/` and `src/` files as `<base>/<file name>` |
| `MAVEN_SETTINGS_CONTENT` | a whole `settings.xml`, used instead of the committed one; or `ARTIFACTORY_URL`, `ARTIFACTORY_USER`, `ARTIFACTORY_TOKEN` with its example |
| `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` | passed to the seed, which needs github.com (Alire's index and crate sources) whatever the mirrors |
| `CONTAINER_RUNTIME` | `podman` instead of `docker` for the seed |

## CI

- [build.yml](.github/workflows/build.yml) builds both images on every change to the build, and
  pushes them to GHCR from `main`. A build takes about an hour on a hosted runner.
- [check-updates.yml](.github/workflows/check-updates.yml) runs
  [check-updates.sh](check-updates.sh) daily. It moves the pins to upstream's newest (the plugin's
  next version on its main branch, SonarScanner CLI, Alire, and the UBI base images) and keeps one
  pull request open with them, built and tested. Merging it publishes new images. GNAT and gprbuild
  stay put: they follow libadalang, which the plugin pins, so the pull request flags a new
  libadalang instead. Run it locally with `./check-updates.sh && git diff`.
- Dependabot keeps the workflows' actions current.

## Licenses

The plugin is GPL-3.0: each image carries the exact source it was built from in
`/opt/sonar-ada/src/`, and this repo holds the build. The scanner image also holds libadalang's
native closure in `/opt/libadalang-jni-libs` (libadalang, Langkit, AdaSAT, VSS, GNATcoll, XML/Ada,
GPR and GNAT's runtime: Apache-2.0, or GPL-3.0 with the GCC Runtime Library Exception), GMP from
UBI (LGPL-3.0), and SonarScanner CLI (LGPL-3.0). The base images are Red Hat's freely
redistributable [Universal Base Images](https://www.redhat.com/en/blog/introducing-red-hat-universal-base-image).
