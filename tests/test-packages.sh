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
# shellcheck source=/dev/null
source "$REPO_DIR/scripts/sync-apt-repo.sh"

mkdir --parents "$TEST_ROOT/asset"
cat >"$TEST_ROOT/asset/pixi" <<'EOF'
#!/bin/sh
printf 'fixture pixi\n'
EOF
tar --create --gzip --file="$TEST_ROOT/pixi.tar.gz" --directory="$TEST_ROOT/asset" pixi
release="$(jq --null-input --compact-output \
	--arg url "file://$TEST_ROOT/pixi.tar.gz" \
	--argjson size "$(stat --format='%s' "$TEST_ROOT/pixi.tar.gz")" \
	'{id: 1, tag_name: "v1.0.0", published_at: "2024-01-01T00:00:00Z",
	  html_url: "https://example.invalid/release", tarball_url: "https://example.invalid/source.tar.gz",
	  zipball_url: "https://example.invalid/source.zip",
	  assets: [{id: 2, name: "pixi-x86_64-unknown-linux-musl.tar.gz", browser_download_url: $url, size: $size},
	           {id: 3, name: "source.zip", browser_download_url: "file:///unsupported", size: 1}]}')"
manifest="$TEST_ROOT/packages.ndjson"
printf '%s\n' "$release" >"$TEST_ROOT/releases.ndjson"
select_release_candidates "$TEST_ROOT/releases.ndjson" "$TEST_ROOT/candidates.ndjson"
prepare_release_packages "$(<"$TEST_ROOT/candidates.ndjson")" "$manifest"
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

# Exercise real signing both before and after an eviction. Keep all key material
# inside the test directory and count imports/exports across metadata refreshes.
gpg_calls="$TEST_ROOT/gpg-calls"
gpg() {
	printf '%s\n' "$*" >>"$gpg_calls"
	command gpg "$@"
}
signing_fixture_home="$TEST_ROOT/signing-fixture"
mkdir --mode=700 "$signing_fixture_home"
command gpg --homedir "$signing_fixture_home" --batch --passphrase '' \
	--quick-generate-key 'Retention Test <retention@example.invalid>' ed25519 sign 0 >/dev/null 2>&1
APT_GPG_PRIVATE_KEY="$(command gpg --homedir "$signing_fixture_home" --batch --armor --export-secret-keys)"
export APT_GPG_PRIVATE_KEY
verify_repository_signatures() {
	if ! gpg --homedir "$WORK_DIR/gnupg" --batch --verify \
		"$OUT_DIR/dists/$APT_SUITE/Release.gpg" "$OUT_DIR/dists/$APT_SUITE/Release" >/dev/null 2>&1; then
		fail 'detached repository signature is invalid'
	fi
	if ! gpg --homedir "$WORK_DIR/gnupg" --batch --verify \
		"$OUT_DIR/dists/$APT_SUITE/InRelease" >/dev/null 2>&1; then
		fail 'inline repository signature is invalid'
	fi
}
measure_pages_artifact_bytes() {
	verify_repository_signatures
	if [[ ! -e $TEST_ROOT/first-measurement ]]; then
		: >"$TEST_ROOT/first-measurement"
		printf '%s\n' "$MAX_BYTES"
	else
		printf '%s\n' 1
	fi
}
{
	jq --compact-output '.id = 2 | .tag_name = "v2.0.0"' <<<"$release"
	printf '%s\n' "$release"
} >"$TEST_ROOT/releases.ndjson"
select_release_candidates "$TEST_ROOT/releases.ndjson" "$TEST_ROOT/candidates.ndjson"
enforce_pages_size_limit "$TEST_ROOT/candidates.ndjson" "$TEST_ROOT/selected.ndjson" "$manifest"
if [[ $(jq --raw-output '.id' "$TEST_ROOT/selected.ndjson") != 2 ]]; then
	fail 'signed repository did not evict the older release'
fi
if [[ $(rg --count -- ' --import$' "$gpg_calls") != 1 || $(rg --count -- ' --export ' "$gpg_calls") != 1 ]]; then
	fail 'metadata refresh repeated signing-key initialization'
fi
if [[ $(rg --count -- ' --clearsign ' "$gpg_calls") != 2 || $(rg --count -- ' --detach-sign ' "$gpg_calls") != 2 ]]; then
	fail 'repository signatures were not refreshed after eviction'
fi
for signature in Release.gpg InRelease; do
	signature_path="$OUT_DIR/dists/$APT_SUITE/$signature"
	cp -- "$signature_path" "$TEST_ROOT/signature-backup"
	printf 'invalid signature\n' >"$signature_path"
	if (verify_repository_signatures 2>/dev/null); then
		fail "signature verification accepted corrupted $signature"
	fi
	mv -- "$TEST_ROOT/signature-backup" "$signature_path"
done
gpg --homedir "$WORK_DIR/gnupg" --batch --show-keys "$OUT_DIR/pixi-archive-keyring.gpg" >/dev/null 2>&1
for document in LICENSE SECURITY.md THIRD_PARTY_NOTICES.md; do
	cmp -- "$REPO_DIR/$document" "$OUT_DIR/$document"
done
cmp -- "$REPO_DIR/templates/index.html" "$OUT_DIR/index.html"
printf '%s\n' 'package preparation tests passed'
