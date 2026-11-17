#!/usr/bin/env bash
# Moves the pins to upstream's newest and prints a Markdown line for each one it moved (nothing
# when all are current):
#
#   PLUGIN_COMMIT     download-deps.sh   the plugin's main branch, once its pom has a new version
#   SCANNER_VERSION   download-deps.sh   SonarScanner CLI's latest release
#   ALR_VERSION       download-deps.sh   Alire's latest release
#   FROM tags         Dockerfile         what each UBI image's :latest is (<version>-<release>)
#
#   ./check-updates.sh && git diff
#
# GNAT_VERSION and GPRBUILD_VERSION stay: they follow libadalang, which the plugin's pom pins, so a
# new libadalang is flagged for them instead. Needs gh (logged in, or GH_TOKEN) and skopeo (or
# Docker, to run it). .github/workflows/check-updates.yml runs this daily.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

command -v skopeo >/dev/null || skopeo() { MSYS_NO_PATHCONV=1 docker run --rm quay.io/skopeo/stable "$@"; }

# pin <name>: the default in download-deps.sh's NAME="${NAME:-value}" line
pin() { sed -n "s/^$1=\"\${$1:-\([^}]*\)}\".*/\1/p" download-deps.sh; }
# repin <name> <new> [note]
repin() {
  local old
  old="$(pin "$1")"
  [ -n "$old" ] || { echo "no $1 default in download-deps.sh" >&2; exit 1; }
  [ "$old" != "$2" ] || return 0
  sed -i "s/^$1=\"\${$1:-$old}\"/$1=\"\${$1:-$2}\"/" download-deps.sh
  echo "- \`$1\`: $old → $2${3:+ ($3)}"
}

# The plugin: main's head, when its version differs from the pinned commit's (download-deps.sh
# reads the same <version> and <libadalang.version>).
repo="$(pin PLUGIN_URL)"; repo="${repo#https://github.com/}"
pom() { gh api "repos/$repo/contents/pom.xml?ref=$1" -H 'Accept: application/vnd.github.raw'; }
version() { sed -n '0,/<version>/s:.*<version>\([^<]*\)</version>.*:\1:p'; }
libadalang() { sed -n 's:.*<libadalang.version>\([0-9.]*\)-.*:\1:p'; }
old_pom="$(pom "$(pin PLUGIN_COMMIT)")"
head="$(gh api "repos/$repo/commits/HEAD" --jq .sha)"
new_pom="$(pom "$head")"
old_version="$(version <<<"$old_pom")" new_version="$(version <<<"$new_pom")"
if [ "$old_version" != "$new_version" ]; then
  repin PLUGIN_COMMIT "$head" "plugin $old_version → $new_version, $repo"
  old_lal="$(libadalang <<<"$old_pom")" new_lal="$(libadalang <<<"$new_pom")"
  [ "$old_lal" = "$new_lal" ] \
    || echo "- libadalang $old_lal → $new_lal: \`GNAT_VERSION\` and \`GPRBUILD_VERSION\` may have to follow (Alire's libadalang=$new_lal)"
fi

# SonarScanner CLI: the release's own zip must be there
scanner="$(gh api repos/SonarSource/sonar-scanner-cli/releases/latest --jq .tag_name)"
if curl -fsI -o /dev/null "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-$scanner.zip"; then
  repin SCANNER_VERSION "$scanner"
else
  echo "SonarScanner CLI $scanner: no zip on binaries.sonarsource.com yet, skipped" >&2
fi

# Alire: the release must have the Linux build download-deps.sh fetches
alr="$(gh api repos/alire-project/alire/releases/latest --jq .tag_name)"; alr="${alr#v}"
if gh api repos/alire-project/alire/releases/latest --jq '.assets[].name' | grep -qx "alr-$alr-bin-x86_64-linux.zip"; then
  repin ALR_VERSION "$alr"
else
  echo "Alire $alr: no alr-$alr-bin-x86_64-linux.zip in its release, skipped" >&2
fi

# UBI base images: :latest's version and release labels name its fixed tag
registry=registry.access.redhat.com
while read -r image tag; do
  latest="$(skopeo inspect --no-tags --format '{{index .Labels "version"}}-{{index .Labels "release"}}' "docker://$registry/$image:latest")"
  [ "$latest" != "$tag" ] || continue
  skopeo inspect --no-tags --format '{{.Digest}}' "docker://$registry/$image:$latest" >/dev/null
  sed -i "s|^\(FROM \${UBI_REGISTRY}/$image\):$tag |\1:$latest |" Dockerfile
  echo "- \`$image\`: $tag → $latest"
done < <(sed -n 's|^FROM ${UBI_REGISTRY}/\([^: ]*\):\([^ ]*\) AS .*|\1 \2|p' Dockerfile)
