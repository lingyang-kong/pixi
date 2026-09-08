#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

REPO_DIR="$(
	if ! cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."; then
		exit 1
	fi
	pwd
)"
TEST_ROOT="$(mktemp --directory)"
trap 'rm --recursive --force -- "$TEST_ROOT"' EXIT
export WORK_DIR="$TEST_ROOT/work"
export OUT_DIR="$TEST_ROOT/out"
export CACHE_DIR="$TEST_ROOT/cache"
# shellcheck source=/dev/null
source "$REPO_DIR/scripts/sync-apt-repo.sh"

recipe_key="$(package_recipe_key)"

mkdir --parents "$TEST_ROOT/asset"
printf '#!/bin/sh\nprintf "fixture pixi\\n"\n' >"$TEST_ROOT/asset/pixi"
tar --create --gzip --file="$TEST_ROOT/pixi.tar.gz" --directory="$TEST_ROOT/asset" pixi
release="$(jq --null-input --compact-output \
	--arg url "file://$TEST_ROOT/pixi.tar.gz" \
	--argjson size "$(stat --format='%s' "$TEST_ROOT/pixi.tar.gz")" \
	'{id: 1, tag_name: "v1.0.0", published_at: "2024-01-01T00:00:00Z",
	  html_url: "https://example.invalid/release", tarball_url: "https://example.invalid/source.tar.gz",
	  zipball_url: "https://example.invalid/source.zip",
	  assets: [{id: 2, name: "pixi-x86_64-unknown-linux-musl.tar.gz", browser_download_url: $url, size: $size}]}')"
manifest="$TEST_ROOT/packages.ndjson"
prepare_release_packages "$release" "$manifest" "$recipe_key"
if [[ -e $OUT_DIR ]]; then
	fail 'package preparation wrote into the publication directory'
fi
package_path="$(jq --raw-output '.package_path' "$manifest")"
if [[ $(dpkg-deb --field "$package_path" Version) != '1.0.0' ]]; then
	fail 'prepared package has the wrong version'
fi

publish_manifest_packages "$manifest"
pool_path="$(jq --raw-output '.pool_path' "$manifest")"
cmp -- "$package_path" "$OUT_DIR/$pool_path"
generate_apt_metadata "$manifest"
if ! rg --quiet '^Package: pixi$' "$OUT_DIR/dists/stable/main/binary-amd64/Packages"; then
	fail 'published package is absent from the APT index'
fi

printf '%s\n' "$release" >"$TEST_ROOT/selected.ndjson"
write_release_manifest "$manifest" "$TEST_ROOT/selected.ndjson"
if ! jq --exit-status '.mirrored_packages | length == 1 and all(.[]; (has("package_path") or has("cache_key")) | not)' "$OUT_DIR/releases.json" >/dev/null; then
	fail 'public manifest exposes internal package storage'
fi

github_api_get() {
	jq --null-input --argjson release "$release" '[$release + {draft: false, prerelease: false}]'
}
collect_stable_releases >"$TEST_ROOT/releases.ndjson"
if [[ $(jq --raw-output '.id' "$TEST_ROOT/releases.ndjson") != '1' ]]; then
	fail 'release collection did not emit NDJSON'
fi
if [[ $(check_newest_release_changed "file://$OUT_DIR/releases.json") != 'false' ]]; then
	fail 'polling did not match the published snapshot'
fi
printf '%s\n' 'package preparation tests passed'
