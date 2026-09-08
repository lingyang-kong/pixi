#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
ROOT_DIR="$(
	if ! cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."; then
		exit 1
	fi
	pwd
)"

readonly SCRIPT_NAME
readonly ROOT_DIR
readonly WORK_DIR="${WORK_DIR:-$ROOT_DIR/.build/pixi-apt}"
readonly OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
readonly CACHE_DIR="${CACHE_DIR:-$ROOT_DIR/.build/pixi-cache}"
readonly PACKAGE_CACHE_FORMAT='1'
readonly API_REPO="${API_REPO:-prefix-dev/pixi}"
readonly API_URL="https://api.github.com/repos/$API_REPO/releases"
readonly MAX_BYTES="${MAX_BYTES:-1000000000}"
readonly PACKAGE_CACHE_EXTRA_BYTES="${PACKAGE_CACHE_EXTRA_BYTES:-$MAX_BYTES}"
readonly USER_AGENT='pixi-apt-sync'
readonly INDEX_TEMPLATE="$ROOT_DIR/templates/index.html"
readonly APT_SUITE="${APT_SUITE:-stable}"
readonly APT_COMPONENT="${APT_COMPONENT:-main}"
readonly APT_ORIGIN='Unofficial Pixi Mirror'
readonly APT_LABEL='Unofficial Pixi Mirror'
readonly APT_DESCRIPTION='Unofficial APT repository for repackaged Pixi upstream Linux binaries'
readonly PACKAGE_NAME='pixi'
readonly DEB_MAINTAINER="${DEB_MAINTAINER:-Unofficial Pixi Mirror <noreply@example.invalid>}"
readonly PACKAGE_RECIPE_FILE="$ROOT_DIR/scripts/package-recipe.sh"
# shellcheck source=scripts/package-recipe.sh
source "$PACKAGE_RECIPE_FILE"

# jq expands these variables when serializing the manifest.
# shellcheck disable=SC2016
readonly RELEASES_MANIFEST_FILTER='
{
	source_repo: $api_repo,
	generated_at: $generated_at,
	max_bytes: $max_bytes,
	package_name: $package_name,
	suite: $suite,
	newest_release: $newest_release,
	mirrored_packages: .
}
'

fail() {
	echo "$1" >&2
	exit 1
}

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		fail "missing required command: $1"
	fi
}

github_api_get() {
	local url=$1
	local args=(
		--fail --silent --show-error --location
		--header 'Accept: application/vnd.github+json'
		--header "User-Agent: $USER_AGENT"
	)

	if [[ -n ${GITHUB_TOKEN:-} ]]; then
		args+=(--header "Authorization: Bearer $GITHUB_TOKEN")
	fi

	curl "${args[@]}" "$url"
}

normalize_release_file() {
	local source=$1
	local target=$2
	local suite=$3
	SUITE="$suite" DESCRIPTION="$APT_DESCRIPTION" ORIGIN="$APT_ORIGIN" LABEL="$APT_LABEL" perl -0pe '
		s/^Suite: .*/Suite: $ENV{SUITE}/m;
		s/^Codename: .*/Codename: $ENV{SUITE}/m;
		s/^Origin: .*/Origin: $ENV{ORIGIN}/m;
		s/^Label: .*/Label: $ENV{LABEL}/m;
		s/^Description: .*/Description: $ENV{DESCRIPTION}/m;
	' "$source" >"$target"
}

deb_arch_from_asset_name() {
	local filename=$1

	case $filename in
	pixi-x86_64-unknown-linux-musl.tar.gz)
		printf '%s\n' 'amd64'
		;;
	pixi-aarch64-unknown-linux-musl.tar.gz)
		printf '%s\n' 'arm64'
		;;
	pixi-riscv64gc-unknown-linux-gnu.tar.gz)
		printf '%s\n' 'riscv64'
		;;
	*)
		return 1
		;;
	esac
}

supported_asset_stream() {
	jq --compact-output '.assets[] | select(.name | test("^pixi-(x86_64|aarch64)-unknown-linux-musl\\.tar\\.gz$|^pixi-riscv64gc-unknown-linux-gnu\\.tar\\.gz$"))'
}

release_supported_asset_count() {
	supported_asset_stream | jq --slurp 'length'
}

release_supported_asset_bytes() {
	supported_asset_stream | jq --slurp '[.[].size] | add // 0'
}

collect_stable_releases() {
	local page=1
	local page_size=100
	while :; do
		local payload
		payload="$(github_api_get "$API_URL?per_page=$page_size&page=$page")"

		local count
		count="$(jq 'length' <<<"$payload")"
		if ((count == 0)); then
			break
		fi

		jq --compact-output '.[] | select(.draft | not) | select(.prerelease | not)' <<<"$payload"
		((page += 1))

		if ((count < page_size)); then
			break
		fi
	done
}

newest_release_snapshot() {
	jq --sort-keys --compact-output '{
		release_id: (.id | tostring),
		tag_name,
		assets: [
			.assets[]
			| select(.name | test("^pixi-(x86_64|aarch64)-unknown-linux-musl\\.tar\\.gz$|^pixi-riscv64gc-unknown-linux-gnu\\.tar\\.gz$"))
			| {
				asset_id: (.id | tostring),
				name,
				size,
				browser_download_url,
				content_type,
				state,
				digest
			}
		] | sort_by(.asset_id)
	}'
}

check_newest_release_changed() {
	local previous_manifest_url=$1
	local releases
	if ! releases="$(collect_stable_releases)"; then
		fail 'unable to collect stable releases'
	fi
	if [[ -z $releases ]]; then
		fail 'no stable releases found'
	fi

	local current_snapshot
	current_snapshot="$(newest_release_snapshot <<<"${releases%%$'\n'*}")"

	local previous_manifest
	if ! previous_manifest="$(curl --fail --silent --show-error --location --header "User-Agent: $USER_AGENT" "$previous_manifest_url")"; then
		printf '%s\n' 'true'
		return
	fi

	local previous_snapshot
	if ! previous_snapshot="$(jq --exit-status --sort-keys --compact-output '.newest_release' <<<"$previous_manifest" 2>/dev/null)"; then
		printf '%s\n' 'true'
		return
	fi
	if [[ -z $previous_snapshot || $previous_snapshot != "$current_snapshot" ]]; then
		printf '%s\n' 'true'
		return
	fi

	printf '%s\n' 'false'
}

write_release_list() {
	local selected_file=$1
	shift
	: >"$selected_file"

	local release_json
	for release_json in "$@"; do
		printf '%s\n' "$release_json" >>"$selected_file"
	done
}

select_retained_releases() {
	local releases_file=$1
	local selected_file=$2

	mapfile -t releases <"$releases_file"
	if ((${#releases[@]} == 0)); then
		fail 'no stable releases found'
	fi
	if [[ "$(release_supported_asset_count <<<"${releases[0]}")" -eq 0 ]]; then
		fail 'latest stable release has no supported Linux assets'
	fi

	local selected_releases=()
	local selected_bytes=()
	local total_bytes=0
	local idx
	for ((idx = ${#releases[@]} - 1; idx >= 0; idx--)); do
		local release_json=${releases[idx]}
		local asset_count
		asset_count="$(release_supported_asset_count <<<"$release_json")"
		if ((asset_count == 0)); then
			continue
		fi

		local asset_bytes
		asset_bytes="$(release_supported_asset_bytes <<<"$release_json")"
		if ((asset_bytes > MAX_BYTES)); then
			fail "release $(jq --raw-output '.tag_name' <<<"$release_json") exceeds MAX_BYTES=$MAX_BYTES"
		fi

		while ((${#selected_releases[@]} > 0 && MAX_BYTES - total_bytes < asset_bytes)); do
			total_bytes=$((total_bytes - selected_bytes[0]))
			selected_releases=("${selected_releases[@]:1}")
			selected_bytes=("${selected_bytes[@]:1}")
		done

		selected_releases+=("$release_json")
		selected_bytes+=("$asset_bytes")
		total_bytes=$((total_bytes + asset_bytes))
	done

	if ((${#selected_releases[@]} == 0)); then
		fail 'no stable releases selected'
	fi

	write_release_list "$selected_file" "${selected_releases[@]}"
}

evict_oldest_release() {
	local selected_file=$1
	local tmp_file
	tmp_file="$(mktemp)"

	if ! tail --lines=+2 "$selected_file" >"$tmp_file"; then
		rm --force "$tmp_file"
		return 1
	fi

	mv "$tmp_file" "$selected_file"
	if [[ ! -s $selected_file ]]; then
		fail 'cannot evict the final retained release'
	fi
}

package_recipe_key_for() {
	local recipe_file=$1
	local recipe_digest
	if ! recipe_digest="$(sha256sum "$recipe_file" | awk '{print $1}')"; then
		return 1
	fi
	local dpkg_deb_version
	if ! dpkg_deb_version="$(dpkg-deb --version | sed --quiet '1p')"; then
		return 1
	fi

	printf '%s\0' \
		"$PACKAGE_NAME" \
		"$DEB_MAINTAINER" \
		"$dpkg_deb_version" \
		"$recipe_digest" |
		sha256sum | awk '{print $1}'
}

package_recipe_key() {
	package_recipe_key_for "$PACKAGE_RECIPE_FILE"
}

package_cache_key() {
	local asset_json=$1
	local version=$2
	local arch=$3
	local release_id=$4
	local source_date_epoch=$5
	local recipe_key=$6
	local asset_identity
	# A verified digest identifies the bytes; provenance only identifies assets
	# that do not provide one. Publication metadata still comes from the release.
	if ! asset_identity="$(jq --sort-keys --compact-output --arg release_id "$release_id" '
		if (.digest // "") != "" then
			{sha256: (.digest | ltrimstr("sha256:") | ascii_downcase)}
		else
			{
				release_id: $release_id,
				asset_id: ((.id // "") | tostring),
				size: (.size // ""),
				url: (.browser_download_url // ""),
				updated_at: (.updated_at // "")
			}
		end' <<<"$asset_json")"; then
		return 1
	fi

	printf '%s\0' \
		"$PACKAGE_CACHE_FORMAT" \
		"$recipe_key" \
		"$version" \
		"$arch" \
		"$source_date_epoch" \
		"$asset_identity" |
		sha256sum | awk '{print $1}'
}

normalize_sha256_digest() {
	local digest=${1#sha256:}
	digest=${digest,,}

	if [[ $digest =~ ^[[:xdigit:]]{64}$ ]]; then
		printf '%s\n' "$digest"
		return 0
	fi

	return 1
}

validate_upstream_asset() {
	local asset_path=$1
	local expected_size=$2
	local expected_digest=$3
	if [[ ! -f $asset_path ]]; then
		return 1
	fi
	local actual_size actual_digest
	if ! actual_size="$(stat --format='%s' "$asset_path")"; then
		return 1
	fi
	if [[ $actual_size != "$expected_size" ]]; then
		return 1
	fi
	if ! actual_digest="$(sha256sum "$asset_path" | awk '{print $1}')"; then
		return 1
	fi
	if [[ -n $expected_digest && $actual_digest != "$expected_digest" ]]; then
		return 1
	fi
	printf '%s\n' "$actual_digest"
}

download_upstream_asset() {
	local destination=$1
	local url=$2
	local size=$3
	local digest=$4

	local asset_sha256
	local destination_dir
	if ! destination_dir="$(dirname -- "$destination")"; then
		return 1
	fi
	if ! mkdir --parents "$destination_dir"; then
		return 1
	fi
	local temporary_download
	if ! temporary_download="$(mktemp "$destination_dir/.asset.XXXXXX")"; then
		return 1
	fi
	if ! curl \
		--fail \
		--silent \
		--show-error \
		--location \
		--header "User-Agent: $USER_AGENT" \
		--output "$temporary_download" \
		"$url"; then
		rm --force -- "$temporary_download"
		return 1
	fi
	if ! asset_sha256="$(validate_upstream_asset "$temporary_download" "$size" "$digest")"; then
		rm --force -- "$temporary_download"
		return 1
	fi
	if ! mv -- "$temporary_download" "$destination"; then
		rm --force -- "$temporary_download"
		return 1
	fi
	printf '%s\n' "$asset_sha256"
}

validate_deb_file() {
	local package_path=$1
	local expected_version=$2
	local expected_arch=$3
	local package_fields
	local package_name
	local package_version
	local package_arch

	if [[ ! -s $package_path ]]; then
		return 1
	fi
	# shellcheck disable=SC2016
	if ! package_fields="$(dpkg-deb --show --showformat='${Package}\t${Version}\t${Architecture}' "$package_path" 2>/dev/null)"; then
		return 1
	fi
	if ! IFS=$'\t' read -r package_name package_version package_arch <<<"$package_fields"; then
		return 1
	fi
	if [[ $package_name != "$PACKAGE_NAME" || $package_version != "$expected_version" || $package_arch != "$expected_arch" ]]; then
		return 1
	fi
}

read_cached_package() {
	local cache_key=$1
	local deb_name=$2
	local version=$3
	local arch=$4
	local expected_upstream_sha256=$5
	local entry_dir="$CACHE_DIR/$cache_key"
	local package_path="$entry_dir/$deb_name"
	local metadata_path="$entry_dir/metadata.json"

	if ! validate_deb_file "$package_path" "$version" "$arch"; then
		return 1
	fi
	local package_sha256
	if ! package_sha256="$(sha256sum "$package_path" | awk '{print $1}')"; then
		return 1
	fi
	local package_size
	if ! package_size="$(stat --format='%s' "$package_path")"; then
		return 1
	fi
	local metadata
	if ! metadata="$(jq --exit-status --compact-output \
		--arg cache_key "$cache_key" \
		--arg package_sha256 "$package_sha256" \
		--argjson package_size "$package_size" \
		--arg upstream_sha256 "$expected_upstream_sha256" \
		'select(
			.cache_key == $cache_key and
			.deb_sha256 == $package_sha256 and
			.deb_size == $package_size and
			(.upstream_sha256 | (type == "string" and test("^[0-9a-f]{64}$"))) and
			($upstream_sha256 == "" or .upstream_sha256 == $upstream_sha256)
		)' "$metadata_path" 2>/dev/null)"; then
		return 1
	fi
	if ! touch -- "$metadata_path"; then
		return 1
	fi
	printf '%s\n' "$metadata"
}

record_cached_package() {
	local cache_key=$1
	local deb_name=$2
	local version=$3
	local arch=$4
	local upstream_sha256=$5
	local entry_dir="$CACHE_DIR/$cache_key"
	local package_path="$entry_dir/$deb_name"

	if ! validate_deb_file "$package_path" "$version" "$arch"; then
		return 1
	fi
	local package_sha256 package_size metadata
	if ! package_sha256="$(sha256sum "$package_path" | awk '{print $1}')"; then
		return 1
	fi
	if ! package_size="$(stat --format='%s' "$package_path")"; then
		return 1
	fi
	if ! metadata="$(jq --null-input --compact-output \
		--arg cache_key "$cache_key" \
		--arg upstream_sha256 "$upstream_sha256" \
		--arg deb_sha256 "$package_sha256" \
		--argjson deb_size "$package_size" \
		'{cache_key: $cache_key, upstream_sha256: $upstream_sha256,
		  deb_sha256: $deb_sha256, deb_size: $deb_size}')"; then
		return 1
	fi
	local temporary_metadata
	if ! temporary_metadata="$(mktemp "$entry_dir/.metadata.XXXXXX")"; then
		return 1
	fi
	if ! printf '%s\n' "$metadata" >"$temporary_metadata"; then
		rm --force -- "$temporary_metadata"
		return 1
	fi
	if ! mv -- "$temporary_metadata" "$entry_dir/metadata.json"; then
		rm --force -- "$temporary_metadata"
		return 1
	fi
	printf '%s\n' "$metadata"
}

prune_package_cache() {
	local manifest_file=$1
	local extra_budget=$2
	if [[ ! -d $CACHE_DIR ]]; then
		return 0
	fi
	local -A retained_keys=()
	local cache_key
	local manifest_keys
	if ! manifest_keys="$(jq --raw-output '.cache_key // empty' "$manifest_file")"; then
		return 1
	fi
	while IFS= read -r cache_key; do
		if [[ $cache_key =~ ^[[:xdigit:]]{64}$ ]]; then
			retained_keys[${cache_key,,}]=1
		fi
	done <<<"$manifest_keys"

	local candidates
	candidates="$(
		local entry_dir metadata_path package_path modified_at package_bytes
		for entry_dir in "$CACHE_DIR"/*; do
			if [[ ! -d $entry_dir ]]; then
				continue
			fi
			cache_key=${entry_dir##*/}
			if [[ ! $cache_key =~ ^[[:xdigit:]]{64}$ ]]; then
				continue
			fi
			if [[ -n ${retained_keys[${cache_key,,}]+present} ]]; then
				continue
			fi
			metadata_path="$entry_dir/metadata.json"
			if [[ ! -f $metadata_path ]]; then
				rm --recursive --force -- "$entry_dir"
				continue
			fi
			if ! jq --exit-status 'type == "object"' "$metadata_path" >/dev/null 2>&1; then
				rm --recursive --force -- "$entry_dir"
				continue
			fi
			package_path="$(find "$entry_dir" -maxdepth 1 -type f -name '*.deb' -print -quit)"
			if [[ ! -f $package_path ]]; then
				rm --recursive --force -- "$entry_dir"
				continue
			fi
			if ! package_bytes="$(stat --format='%s' "$package_path")"; then
				return 1
			fi
			if ! modified_at="$(stat --format='%Y' "$metadata_path")"; then
				return 1
			fi
			printf '%s\t%s\t%s\n' "$modified_at" "$package_bytes" "$entry_dir"
		done | sort --numeric-sort --reverse --key=1,1
	)"

	local extra_bytes=0
	local modified_at package_size entry_dir
	while IFS=$'\t' read -r modified_at package_size entry_dir; do
		if [[ -z $entry_dir ]]; then
			continue
		fi
		if ((extra_bytes + package_size <= extra_budget)); then
			extra_bytes=$((extra_bytes + package_size))
			continue
		fi
		if ! rm --recursive --force -- "$entry_dir"; then
			return 1
		fi
	done <<<"$candidates"
}

prepare_release_packages() {
	local release_json=$1
	local manifest_file=$2
	local recipe_key=$3

	mkdir --parents "$WORK_DIR/downloads" "$CACHE_DIR"
	: >"$manifest_file"

	local release_id
	release_id="$(jq --raw-output '.id' <<<"$release_json")"
	local tag_name
	tag_name="$(jq --raw-output '.tag_name' <<<"$release_json")"
	local published_at
	published_at="$(jq --raw-output '.published_at' <<<"$release_json")"
	local release_page_url
	release_page_url="$(jq --raw-output '.html_url' <<<"$release_json")"
	local source_tarball_url
	source_tarball_url="$(jq --raw-output '.tarball_url' <<<"$release_json")"
	local source_zipball_url
	source_zipball_url="$(jq --raw-output '.zipball_url' <<<"$release_json")"
	local source_date_epoch
	if ! source_date_epoch="$(source_date_epoch_for_release "$published_at")"; then
		fail "invalid published_at timestamp for release $release_id: $published_at"
	fi
	local version
	version="${tag_name#v}"

	while IFS= read -r asset_json; do
		if [[ -z $asset_json ]]; then
			continue
		fi

		local name
		name="$(jq --raw-output '.name' <<<"$asset_json")"
		local arch
		arch="$(deb_arch_from_asset_name "$name")"
		local url
		local size
		url="$(jq --raw-output '.browser_download_url' <<<"$asset_json")"
		size="$(jq --raw-output '.size' <<<"$asset_json")"
		if [[ ! $size =~ ^[0-9]+$ ]]; then
			fail "invalid upstream asset size for $name: $size"
		fi
		if [[ -z $url || $url == 'null' ]]; then
			fail "missing upstream asset URL for $name"
		fi
		local expected_digest
		expected_digest="$(jq --raw-output '.digest // empty' <<<"$asset_json")"
		if [[ -n $expected_digest ]]; then
			if ! expected_digest="$(normalize_sha256_digest "$expected_digest")"; then
				fail "unsupported upstream digest for $name: $expected_digest"
			fi
		fi
		local destination
		destination="$WORK_DIR/downloads/$release_id/$name"
		local deb_name="${PACKAGE_NAME}_${version}_${arch}.deb"
		local cache_key
		cache_key="$(package_cache_key "$asset_json" "$version" "$arch" "$release_id" "$source_date_epoch" "$recipe_key")"
		local package_output="$CACHE_DIR/$cache_key/$deb_name"
		local package_metadata upstream_sha256
		if ! package_metadata="$(read_cached_package "$cache_key" "$deb_name" "$version" "$arch" "$expected_digest")"; then
			if ! upstream_sha256="$(download_upstream_asset "$destination" "$url" "$size" "$expected_digest")"; then
				fail "unable to download a valid upstream asset: $name"
			fi
			if ! build_deb_from_asset "$destination" "$version" "$arch" "$release_id" "$package_output" "$source_date_epoch"; then
				fail "unable to build package from upstream asset: $name"
			fi
			if ! rm --force -- "$destination"; then
				fail "unable to remove downloaded upstream asset: $name"
			fi
			if ! package_metadata="$(record_cached_package "$cache_key" "$deb_name" "$version" "$arch" "$upstream_sha256")"; then
				fail "unable to record package cache entry: $deb_name"
			fi
		fi

		jq --null-input --compact-output \
			--arg release_id "$release_id" \
			--arg tag_name "$tag_name" \
			--arg published_at "$published_at" \
			--arg release_page_url "$release_page_url" \
			--arg source_tarball_url "$source_tarball_url" \
			--arg source_zipball_url "$source_zipball_url" \
			--arg suite "$APT_SUITE" \
			--arg arch "$arch" \
			--arg upstream_asset_name "$name" \
			--arg upstream_browser_download_url "$url" \
			--argjson cache_metadata "$package_metadata" \
			--arg package_name "$PACKAGE_NAME" \
			--arg package_arch "$arch" \
			--arg version "$version" \
			--arg package_path "$package_output" \
			--arg pool_path "pool/main/p/pixi/$arch/$release_id/$deb_name" \
			--arg cache_key "$cache_key" \
			--argjson upstream_size "$size" \
			'{
				release_id: $release_id,
				tag_name: $tag_name,
				published_at: $published_at,
				release_page_url: $release_page_url,
				source_tarball_url: $source_tarball_url,
				source_zipball_url: $source_zipball_url,
				suite: $suite,
				arch: $arch,
				upstream_asset_name: $upstream_asset_name,
				upstream_browser_download_url: $upstream_browser_download_url,
				upstream_size: $upstream_size,
				upstream_sha256: $cache_metadata.upstream_sha256,
				package_name: $package_name,
				package_arch: $package_arch,
				version: $version,
				package_size: $cache_metadata.deb_size,
				package_path: $package_path,
				pool_path: $pool_path,
				cache_key: $cache_key,
				sha256: $cache_metadata.deb_sha256
			}' >>"$manifest_file"
	done < <(supported_asset_stream <<<"$release_json")
}

publish_manifest_packages() {
	local manifest_file=$1
	local package_path pool_path
	while IFS=$'\t' read -r package_path pool_path; do
		mkdir --parents "$(dirname -- "$OUT_DIR/$pool_path")"
		cp -- "$package_path" "$OUT_DIR/$pool_path"
	done < <(jq --raw-output '[.package_path, .pool_path] | @tsv' "$manifest_file")
}

generate_apt_metadata() {
	local manifest_file=$1

	mapfile -t arches < <(jq --raw-output '.arch' "$manifest_file" | sort --unique)
	local arch
	for arch in "${arches[@]}"; do
		if [[ -z $arch ]]; then
			continue
		fi
		local binary_dir="$OUT_DIR/dists/$APT_SUITE/$APT_COMPONENT/binary-$arch"
		local pool_dir="pool/main/p/pixi/$arch"
		mkdir --parents "$binary_dir"
		(
			cd "$OUT_DIR"
			apt-ftparchive packages "$pool_dir" >"$binary_dir/Packages"
		)
		gzip --best --stdout "$binary_dir/Packages" >"$binary_dir/Packages.gz"
	done

	local suite_dir="$OUT_DIR/dists/$APT_SUITE"
	local release_raw="$WORK_DIR/${APT_SUITE}.Release.raw"
	apt-ftparchive \
		--option "APT::FTPArchive::Release::Origin=$APT_ORIGIN" \
		--option "APT::FTPArchive::Release::Label=$APT_LABEL" \
		--option "APT::FTPArchive::Release::Suite=$APT_SUITE" \
		--option "APT::FTPArchive::Release::Codename=$APT_SUITE" \
		--option "APT::FTPArchive::Release::Architectures=${arches[*]}" \
		--option "APT::FTPArchive::Release::Components=$APT_COMPONENT" \
		--option "APT::FTPArchive::Release::Description=$APT_DESCRIPTION" \
		release "$suite_dir" >"$release_raw"
	normalize_release_file "$release_raw" "$suite_dir/Release" "$APT_SUITE"
	rm --force "$release_raw"
}

sign_repository_metadata() {
	if [[ -z ${APT_GPG_PRIVATE_KEY:-} ]]; then
		fail 'APT_GPG_PRIVATE_KEY is required'
	fi

	export GNUPGHOME="$WORK_DIR/gnupg"
	rm --recursive --force "$GNUPGHOME"
	mkdir --parents "$GNUPGHOME"
	chmod 700 "$GNUPGHOME"

	gpg --batch --import <<<"$APT_GPG_PRIVATE_KEY" >/dev/null 2>&1

	local key_id
	key_id="$(gpg --batch --list-secret-keys --with-colons | awk -F ':' '/^sec:/ { print $5; exit }')"
	if [[ -z $key_id ]]; then
		fail 'no secret key available after import'
	fi

	gpg --batch --yes --export "$key_id" >"$OUT_DIR/pixi-archive-keyring.gpg"

	while IFS= read -r release_file; do
		if [[ -z $release_file ]]; then
			continue
		fi
		local release_dir
		release_dir="$(dirname -- "$release_file")"
		gpg --batch --yes --clearsign --local-user "$key_id" --output "$release_dir/InRelease" "$release_file"
		gpg --batch --yes --detach-sign --local-user "$key_id" --output "$release_dir/Release.gpg" "$release_file"
	done < <(find "$OUT_DIR/dists" -name 'Release' -type f | sort)
}

write_release_manifest() {
	local manifest_file=$1
	local selected_file=$2
	local newest_release
	newest_release="$(tail --lines=1 "$selected_file" | newest_release_snapshot)"

	jq --slurp \
		--arg api_repo "$API_REPO" \
		--arg generated_at "$(date --utc '+%Y-%m-%dT%H:%M:%SZ')" \
		--arg package_name "$PACKAGE_NAME" \
		--arg suite "$APT_SUITE" \
		--argjson max_bytes "$MAX_BYTES" \
		--argjson newest_release "$newest_release" \
		'map(del(.package_path, .cache_key)) | '"$RELEASES_MANIFEST_FILTER" \
		"$manifest_file" >"$OUT_DIR/releases.json"
}

measure_pages_artifact_bytes() {
	local archive="$WORK_DIR/pages-size-check.tar"
	rm --force "$archive"
	tar \
		--dereference --hard-dereference \
		--directory "$OUT_DIR" \
		--create --file="$archive" \
		.
	stat --format='%s' "$archive"
	rm --force "$archive"
}

copy_site_documents() {
	cp "$INDEX_TEMPLATE" "$OUT_DIR/index.html"
	cp "$ROOT_DIR/LICENSE" "$OUT_DIR/LICENSE"
	cp "$ROOT_DIR/SECURITY.md" "$OUT_DIR/SECURITY.md"
	cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$OUT_DIR/THIRD_PARTY_NOTICES.md"
}

build_repository() {
	local selected_file=$1
	local manifest_file=$2
	local recipe_key=$3

	rm --recursive --force "$OUT_DIR"
	mkdir --parents "$OUT_DIR"

	local release_json
	local release_manifest="$WORK_DIR/release-packages.ndjson"
	: >"$manifest_file"
	while IFS= read -r release_json; do
		prepare_release_packages "$release_json" "$release_manifest" "$recipe_key"
		cat -- "$release_manifest" >>"$manifest_file"
	done <"$selected_file"
	publish_manifest_packages "$manifest_file"
	generate_apt_metadata "$manifest_file"
	sign_repository_metadata
	write_release_manifest "$manifest_file" "$selected_file"
	copy_site_documents
}

enforce_pages_size_limit() {
	local selected_file=$1
	local manifest_file=$2
	local recipe_key=$3

	build_repository "$selected_file" "$manifest_file" "$recipe_key"
	while (($(measure_pages_artifact_bytes) >= MAX_BYTES)); do
		evict_oldest_release "$selected_file"
		build_repository "$selected_file" "$manifest_file" "$recipe_key"
	done
}

main() {
	if [[ ${1:-} == '--check-newest-release' ]]; then
		if (($# != 2)); then
			fail "usage: $SCRIPT_NAME --check-newest-release URL"
		fi
		require_command curl
		require_command jq
		check_newest_release_changed "$2"
		return
	fi
	if (($# != 0)); then
		fail "usage: $SCRIPT_NAME [--check-newest-release URL]"
	fi

	local required_command_name
	for required_command_name in \
		apt-ftparchive \
		awk \
		curl \
		date \
		dpkg-deb \
		find \
		gpg \
		gzip \
		install \
		jq \
		mktemp \
		mv \
		perl \
		sed \
		sha256sum \
		stat \
		tar \
		touch; do
		require_command "$required_command_name"
	done
	if [[ ! $PACKAGE_CACHE_EXTRA_BYTES =~ ^[0-9]+$ ]]; then
		fail "PACKAGE_CACHE_EXTRA_BYTES must be a non-negative integer: $PACKAGE_CACHE_EXTRA_BYTES"
	fi

	rm --recursive --force "$WORK_DIR" "$OUT_DIR"
	mkdir --parents "$WORK_DIR" "$OUT_DIR" "$CACHE_DIR"

	local releases_file="$WORK_DIR/releases.ndjson"
	local selected_file="$WORK_DIR/selected.ndjson"
	local manifest_file="$WORK_DIR/manifest.ndjson"
	local recipe_key
	if ! recipe_key="$(package_recipe_key)"; then
		fail 'unable to fingerprint package recipe'
	fi

	collect_stable_releases >"$releases_file"
	select_retained_releases "$releases_file" "$selected_file"
	enforce_pages_size_limit "$selected_file" "$manifest_file" "$recipe_key"
	prune_package_cache "$manifest_file" "$PACKAGE_CACHE_EXTRA_BYTES"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
