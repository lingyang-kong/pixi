#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

REPO_DIR="$(
	if ! cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."; then
		exit 1
	fi
	pwd
)"
TEST_ROOT="$(mktemp --directory)"

cleanup() {
	rm --recursive --force -- "$TEST_ROOT"
}
trap cleanup EXIT

export WORK_DIR="$TEST_ROOT/work"
export OUT_DIR="$TEST_ROOT/out"
export CACHE_DIR="$TEST_ROOT/cache"
export SOURCE_DATE_EPOCH='1704067200'

# shellcheck source=/dev/null
source "$REPO_DIR/scripts/sync-apt-repo.sh"

RECIPE_KEY="$(package_recipe_key)"

fail_test() {
	printf 'test-cache: %s\n' "$1" >&2
	exit 1
}

assert_equal() {
	local expected=$1
	local actual=$2
	local description=$3
	if [[ $expected != "$actual" ]]; then
		fail_test "$description: expected $expected, got $actual"
	fi
}

assert_different() {
	local first=$1
	local second=$2
	local description=$3
	if [[ $first == "$second" ]]; then
		fail_test "$description: values match unexpectedly"
	fi
}

assert_file() {
	if [[ ! -f $1 ]]; then
		fail_test "expected file is missing: $1"
	fi
}

assert_missing() {
	if [[ -e $1 ]]; then
		fail_test "unexpected path exists: $1"
	fi
}

make_asset() {
	local asset_path=$1
	local payload=$2
	local asset_dir="$TEST_ROOT/asset-source"

	rm --recursive --force -- "$asset_dir"
	mkdir --parents "$asset_dir"
	printf '#!/usr/bin/env sh\n# %s\nexit 0\n' "$payload" >"$asset_dir/pixi"
	chmod 0755 "$asset_dir/pixi"
	tar --create --gzip --file="$asset_path" --directory="$asset_dir" pixi
}

SELECTED_FILE="$TEST_ROOT/selected.ndjson"
MANIFEST_FILE="$TEST_ROOT/manifest.ndjson"

write_release() {
	local asset_path=$1
	local digest=$2
	local updated_at=$3
	local release_id=$4
	local tag_name=$5
	local url=${6:-"file://$asset_path"}
	local asset_id=${7:-asset-1}
	local size
	size="$(stat --format='%s' "$asset_path")"
	local asset_digest=''
	if [[ -n $digest ]]; then
		asset_digest="sha256:$digest"
	fi

	jq --null-input --compact-output \
		--arg release_id "$release_id" \
		--arg tag_name "$tag_name" \
		--arg digest "$asset_digest" \
		--arg updated_at "$updated_at" \
		--arg url "$url" \
		--arg asset_id "$asset_id" \
		--argjson size "$size" \
		'{
			id: $release_id,
			tag_name: $tag_name,
			published_at: "2024-01-01T00:00:00Z",
			html_url: "https://example.invalid/release",
			tarball_url: "https://example.invalid/source.tar.gz",
			zipball_url: "https://example.invalid/source.zip",
			assets: [{
				id: $asset_id,
				name: "pixi-x86_64-unknown-linux-musl.tar.gz",
				size: $size,
				digest: (if $digest == "" then null else $digest end),
				browser_download_url: $url,
				updated_at: $updated_at
			}]
		}' >"$SELECTED_FILE"
}

current_asset_json() {
	jq --compact-output '.assets[0]' "$SELECTED_FILE"
}

current_cache_key() {
	local release_id
	release_id="$(jq --raw-output '.id' "$SELECTED_FILE")"
	local version
	version="$(jq --raw-output '.tag_name | ltrimstr("v")' "$SELECTED_FILE")"
	local published_at
	published_at="$(jq --raw-output '.published_at' "$SELECTED_FILE")"
	local source_date_epoch
	source_date_epoch="$(source_date_epoch_for_release "$published_at")"
	local arch
	arch="$(deb_arch_from_asset_name "$(jq --raw-output '.assets[0].name' "$SELECTED_FILE")")"
	package_cache_key "$(current_asset_json)" "$version" "$arch" "$release_id" "$source_date_epoch" "$RECIPE_KEY"
}

current_deb_name() {
	jq --raw-output '.tag_name | ltrimstr("v")' "$SELECTED_FILE" |
		awk '{printf "pixi_%s_amd64.deb", $1}'
}

clear_outputs() {
	rm --recursive --force -- "$WORK_DIR" "$OUT_DIR"
}

prepare_current_release() {
	local release_json
	release_json="$(<"$SELECTED_FILE")"
	prepare_release_packages "$release_json" "$MANIFEST_FILE" "$RECIPE_KEY"
	publish_manifest_packages "$MANIFEST_FILE"
}

CURL_LOG="$TEST_ROOT/curl-calls"
: >"$CURL_LOG"
curl() {
	printf '%s\n' call >>"$CURL_LOG"
	command curl "$@"
}

build_count=0
install() {
	build_count=$((build_count + 1))
	command install "$@"
}

ASSET="$TEST_ROOT/pixi.tar.gz"
make_asset "$ASSET" 'first build'
DIGEST_ONE="$(sha256sum "$ASSET" | awk '{print $1}')"
write_release "$ASSET" "$DIGEST_ONE" '2024-01-01T00:00:00Z' 'release-1' 'v1.0.0'

HASH_LOG="$TEST_ROOT/hash-calls"
COPY_LOG="$TEST_ROOT/copy-calls"
: >"$HASH_LOG"
: >"$COPY_LOG"
sha256sum() {
	if (($# > 0)); then
		printf '%s\n' "$1" >>"$HASH_LOG"
	fi
	command sha256sum "$@"
}
cp() {
	printf '%s\n' "$*" >>"$COPY_LOG"
	command cp "$@"
}

prepare_current_release
FIRST_KEY="$(current_cache_key)"
DEB_NAME="$(current_deb_name)"
assert_equal '1' "$(wc --lines <"$CURL_LOG")" 'first build downloads the asset'
assert_equal '1' "$build_count" 'first build runs dpkg-deb packaging'
assert_file "$OUT_DIR/pool/main/p/pixi/amd64/release-1/$DEB_NAME"
assert_equal 'pixi' "$(dpkg-deb --field "$OUT_DIR/pool/main/p/pixi/amd64/release-1/$DEB_NAME" Package)" 'generated package name'
assert_equal '1.0.0' "$(dpkg-deb --field "$OUT_DIR/pool/main/p/pixi/amd64/release-1/$DEB_NAME" Version)" 'generated package version'
assert_equal 'amd64' "$(dpkg-deb --field "$OUT_DIR/pool/main/p/pixi/amd64/release-1/$DEB_NAME" Architecture)" 'generated package architecture'
assert_file "$CACHE_DIR/$FIRST_KEY/$DEB_NAME"
assert_file "$CACHE_DIR/$FIRST_KEY/metadata.json"
assert_equal '2' "$(wc --lines <"$HASH_LOG")" 'cold build hashes upstream and package once each'
assert_equal '1' "$(wc --lines <"$COPY_LOG")" 'cold build copies the package only into the pool'
assert_missing "$WORK_DIR/generated-debs"
assert_missing "$WORK_DIR/downloads/release-1/pixi-x86_64-unknown-linux-musl.tar.gz"

clear_outputs
: >"$HASH_LOG"
: >"$COPY_LOG"
prepare_current_release
assert_equal '1' "$(wc --lines <"$CURL_LOG")" 'cache hit does not download'
assert_equal '1' "$build_count" 'cache hit does not rebuild'
assert_equal '1' "$(wc --lines <"$HASH_LOG")" 'cache hit verifies the package hash once'
assert_equal '1' "$(wc --lines <"$COPY_LOG")" 'cache hit copies directly into the pool'
assert_missing "$WORK_DIR/generated-debs"
unset -f sha256sum cp

PROVENANCE_URL="file://$TEST_ROOT/unavailable-renamed-asset.tar.gz"
write_release "$ASSET" "${DIGEST_ONE^^}" '2024-02-01T00:00:00Z' 'release-renamed' 'v1.0.0' "$PROVENANCE_URL" 'asset-renamed'
clear_outputs
prepare_current_release
assert_equal "$FIRST_KEY" "$(current_cache_key)" 'same digest reuses the package across provenance changes'
assert_equal '1' "$(wc --lines <"$CURL_LOG")" 'provenance-only change does not download from the unavailable URL'
assert_equal '1' "$build_count" 'provenance-only change does not rebuild'
assert_equal "$PROVENANCE_URL" "$(jq --raw-output '.upstream_browser_download_url' "$MANIFEST_FILE")" 'reused package records the current asset URL'
assert_equal 'release-renamed' "$(jq --raw-output '.release_id' "$MANIFEST_FILE")" 'reused package records the current release ID'
assert_equal "$DIGEST_ONE" "$(jq --raw-output '.upstream_sha256' "$MANIFEST_FILE")" 'reused package preserves the normalized archive checksum'
assert_file "$OUT_DIR/pool/main/p/pixi/amd64/release-renamed/$DEB_NAME"
write_release_manifest "$MANIFEST_FILE" "$SELECTED_FILE"
assert_equal "$PROVENANCE_URL" "$(jq --raw-output '.mirrored_packages[0].upstream_browser_download_url' "$OUT_DIR/releases.json")" 'public manifest records the current URL'
assert_equal 'asset-renamed' "$(jq --raw-output '.newest_release.assets[0].asset_id' "$OUT_DIR/releases.json")" 'public snapshot records the current asset ID'

make_asset "$ASSET" 'changed upstream payload'
DIGEST_TWO="$(sha256sum "$ASSET" | awk '{print $1}')"
write_release "$ASSET" "$DIGEST_TWO" '2024-01-02T00:00:00Z' 'release-1' 'v1.0.0'
clear_outputs
prepare_current_release
DIGEST_CHANGED_KEY="$(current_cache_key)"
assert_different "$FIRST_KEY" "$DIGEST_CHANGED_KEY" 'changed digest changes the cache key'
assert_equal '2' "$(wc --lines <"$CURL_LOG")" 'changed digest downloads again'
assert_equal '2' "$build_count" 'changed digest rebuilds'

RECIPE_FIXTURE="$TEST_ROOT/package-recipe.sh"
cp "$PACKAGE_RECIPE_FILE" "$RECIPE_FIXTURE"
sed --in-place \
	's/^Description: Cross-platform package manager and workflow tool$/Description: Fixture package manager and workflow tool/' \
	"$RECIPE_FIXTURE"
RECIPE_CHANGED_FINGERPRINT="$(package_recipe_key_for "$RECIPE_FIXTURE")"
RECIPE_KEY="$RECIPE_CHANGED_FINGERPRINT"
RECIPE_CHANGED_KEY="$(current_cache_key)"
assert_different "$DIGEST_CHANGED_KEY" "$RECIPE_CHANGED_KEY" 'changed recipe changes the cache key'

build_recipe_fixture() {
	local recipe_file=$1
	local package_path=$2
	env \
		"WORK_DIR=$WORK_DIR" \
		"PACKAGE_NAME=$PACKAGE_NAME" \
		"DEB_MAINTAINER=$DEB_MAINTAINER" \
		"SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
		bash --noprofile --norc -s -- "$recipe_file" "$ASSET" "$package_path" <<'BASH'
set -o errexit -o nounset -o pipefail
source "$1"
build_deb_from_asset "$2" '1.0.0' 'amd64' 'recipe-fixture' "$3" "$SOURCE_DATE_EPOCH"
BASH
}

BASE_RECIPE_PACKAGE="$TEST_ROOT/base-recipe.deb"
CHANGED_RECIPE_PACKAGE="$TEST_ROOT/changed-recipe.deb"
build_recipe_fixture "$PACKAGE_RECIPE_FILE" "$BASE_RECIPE_PACKAGE"
build_recipe_fixture "$RECIPE_FIXTURE" "$CHANGED_RECIPE_PACKAGE"
assert_different \
	"$(sha256sum "$BASE_RECIPE_PACKAGE" | awk '{print $1}')" \
	"$(sha256sum "$CHANGED_RECIPE_PACKAGE" | awk '{print $1}')" \
	'changed recipe changes the package'

clear_outputs
prepare_current_release
assert_equal '3' "$(wc --lines <"$CURL_LOG")" 'changed recipe downloads again'
assert_equal '3' "$build_count" 'changed recipe rebuilds'

EXPECTED_RECIPE_DEB_SHA="$(sha256sum "$CACHE_DIR/$RECIPE_CHANGED_KEY/$DEB_NAME" | awk '{print $1}')"
cp "$CHANGED_RECIPE_PACKAGE" "$CACHE_DIR/$RECIPE_CHANGED_KEY/$DEB_NAME"
assert_different \
	"$EXPECTED_RECIPE_DEB_SHA" \
	"$(sha256sum "$CACHE_DIR/$RECIPE_CHANGED_KEY/$DEB_NAME" | awk '{print $1}')" \
	'valid cache corruption changes the package checksum'
clear_outputs
prepare_current_release
assert_equal '4' "$(wc --lines <"$CURL_LOG")" 'corrupt cache does not skip download'
assert_equal '4' "$build_count" 'corrupt cache does not skip build'
assert_equal \
	"$EXPECTED_RECIPE_DEB_SHA" \
	"$(sha256sum "$CACHE_DIR/$RECIPE_CHANGED_KEY/$DEB_NAME" | awk '{print $1}')" \
	'corrupt cache rebuild is reproducible'

make_asset "$ASSET" 'asset without an upstream digest'
write_release "$ASSET" '' '2024-01-03T00:00:00Z' 'release-no-digest' 'v3.0.0'
clear_outputs
prepare_current_release
NO_DIGEST_KEY="$(current_cache_key)"
assert_equal '5' "$(wc --lines <"$CURL_LOG")" 'digest-less asset downloads on a cache miss'
assert_equal '5' "$build_count" 'digest-less asset builds on a cache miss'
clear_outputs
prepare_current_release
assert_equal '5' "$(wc --lines <"$CURL_LOG")" 'digest-less cache entry restores without downloading'
assert_equal '5' "$build_count" 'digest-less cache entry restores without rebuilding'
write_release "$ASSET" '' '2024-01-04T00:00:00Z' 'release-no-digest' 'v3.0.0'
clear_outputs
prepare_current_release
NO_DIGEST_UPDATED_KEY="$(current_cache_key)"
assert_different "$NO_DIGEST_KEY" "$NO_DIGEST_UPDATED_KEY" 'updated_at changes a digest-less cache key'
assert_equal '6' "$(wc --lines <"$CURL_LOG")" 'updated digest-less asset downloads again'
assert_equal '6' "$build_count" 'updated digest-less asset rebuilds'

BAD_DIGEST="$(printf '%064d' 0)"
write_release "$ASSET" "$BAD_DIGEST" '2024-01-05T00:00:00Z' 'release-bad-digest' 'v2.0.0'
BAD_DIGEST_KEY="$(current_cache_key)"
clear_outputs
if (prepare_current_release >/dev/null 2>&1); then
	fail_test 'mismatched download unexpectedly succeeded'
fi
assert_missing "$CACHE_DIR/$BAD_DIGEST_KEY"
assert_missing "$OUT_DIR/pool"

write_release "$ASSET" "$DIGEST_TWO" '2024-01-06T00:00:00Z' 'release-download-failure' 'v2.0.0' "file://$TEST_ROOT/missing.tar.gz"
FAILED_DOWNLOAD_KEY="$(current_cache_key)"
clear_outputs
if (prepare_current_release >/dev/null 2>&1); then
	fail_test 'failed download unexpectedly succeeded'
fi
assert_missing "$CACHE_DIR/$FAILED_DOWNLOAD_KEY"
assert_missing "$OUT_DIR/pool"

INVALID_ASSET="$TEST_ROOT/invalid.tar.gz"
printf '%s\n' 'not a tar archive' >"$INVALID_ASSET"
INVALID_DIGEST="$(sha256sum "$INVALID_ASSET" | awk '{print $1}')"
write_release "$INVALID_ASSET" "$INVALID_DIGEST" '2024-01-07T00:00:00Z' 'release-invalid-archive' 'v2.0.0'
INVALID_KEY="$(current_cache_key)"
clear_outputs
if (prepare_current_release >/dev/null 2>&1); then
	fail_test 'invalid archive unexpectedly built a package'
fi
assert_missing "$CACHE_DIR/$INVALID_KEY"
assert_missing "$OUT_DIR/pool"

FINAL_MANIFEST="$TEST_ROOT/final.ndjson"
printf '{"cache_key":"%s"}\n' "$RECIPE_CHANGED_KEY" >"$FINAL_MANIFEST"
for cache_key in "$FIRST_KEY" "$DIGEST_CHANGED_KEY" "$NO_DIGEST_KEY"; do
	touch --date='@100' "$CACHE_DIR/$cache_key/metadata.json"
done
touch --date='@200' "$CACHE_DIR/$NO_DIGEST_UPDATED_KEY/metadata.json"
write_release "$ASSET" '' '2024-01-04T00:00:00Z' 'release-no-digest' 'v3.0.0'
NO_DIGEST_DEB_NAME="$(current_deb_name)"
EXTRA_CACHE_BUDGET="$(stat --format='%s' "$CACHE_DIR/$NO_DIGEST_UPDATED_KEY/$NO_DIGEST_DEB_NAME")"
prune_package_cache "$FINAL_MANIFEST" "$EXTRA_CACHE_BUDGET"
assert_file "$CACHE_DIR/$RECIPE_CHANGED_KEY/$DEB_NAME"
assert_file "$CACHE_DIR/$NO_DIGEST_UPDATED_KEY/$NO_DIGEST_DEB_NAME"
assert_missing "$CACHE_DIR/$FIRST_KEY"
assert_missing "$CACHE_DIR/$DIGEST_CHANGED_KEY"
assert_missing "$CACHE_DIR/$NO_DIGEST_KEY"

write_release "$ASSET" '' '2024-01-04T00:00:00Z' 'release-no-digest' 'v3.0.0'
CURL_COUNT_BEFORE_REUSE="$(wc --lines <"$CURL_LOG")"
BUILD_COUNT_BEFORE_REUSE="$build_count"
clear_outputs
prepare_current_release
assert_equal "$CURL_COUNT_BEFORE_REUSE" "$(wc --lines <"$CURL_LOG")" 'recent non-published cache entry avoids download'
assert_equal "$BUILD_COUNT_BEFORE_REUSE" "$build_count" 'recent non-published cache entry avoids rebuild'

# Output-affecting inputs must still build distinct packages with one digest.
INPUT_DIGEST="$(sha256sum "$ASSET" | awk '{print $1}')"
write_release "$ASSET" "$INPUT_DIGEST" '2024-01-01T00:00:00Z' 'release-inputs' 'v4.0.0'
prepare_current_release
INPUT_KEY="$(current_cache_key)"
INPUT_PACKAGE="$(jq --raw-output '.package_path' "$MANIFEST_FILE")"
INPUT_BUILD_COUNT=$build_count

write_release "$ASSET" "$INPUT_DIGEST" '2024-01-01T00:00:00Z' 'release-inputs' 'v4.1.0'
prepare_current_release
assert_different "$INPUT_KEY" "$(current_cache_key)" 'version changes the cache key with the same digest'
assert_equal "$((INPUT_BUILD_COUNT + 1))" "$build_count" 'changed version builds a new package'
assert_equal '4.1.0' "$(dpkg-deb --field "$(jq --raw-output '.package_path' "$MANIFEST_FILE")" Version)" 'rebuilt package has the changed version'

write_release "$ASSET" "$INPUT_DIGEST" '2024-01-01T00:00:00Z' 'release-inputs' 'v4.0.0'
jq '.assets[0].name = "pixi-aarch64-unknown-linux-musl.tar.gz"' "$SELECTED_FILE" >"$TEST_ROOT/arm-release.ndjson"
mv -- "$TEST_ROOT/arm-release.ndjson" "$SELECTED_FILE"
prepare_current_release
assert_different "$INPUT_KEY" "$(current_cache_key)" 'architecture changes the cache key with the same digest'
assert_equal "$((INPUT_BUILD_COUNT + 2))" "$build_count" 'changed architecture builds a new package'
assert_equal 'arm64' "$(dpkg-deb --field "$(jq --raw-output '.package_path' "$MANIFEST_FILE")" Architecture)" 'rebuilt package has the changed architecture'

write_release "$ASSET" "$INPUT_DIGEST" '2024-01-01T00:00:00Z' 'release-inputs' 'v4.0.0'
SOURCE_DATE_EPOCH='1704067201' prepare_current_release
assert_different "$INPUT_KEY" "$(SOURCE_DATE_EPOCH='1704067201' current_cache_key)" 'epoch changes the cache key with the same digest'
assert_equal "$((INPUT_BUILD_COUNT + 3))" "$build_count" 'changed epoch builds a new package'
assert_different \
	"$(sha256sum "$INPUT_PACKAGE" | awk '{print $1}')" \
	"$(sha256sum "$(jq --raw-output '.package_path' "$MANIFEST_FILE")" | awk '{print $1}')" \
	'rebuilt package reflects the changed epoch'

printf '%s\n' 'test-cache: ok'
