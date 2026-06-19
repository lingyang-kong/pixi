#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

readonly SCRIPT_NAME
readonly ROOT_DIR
readonly WORK_DIR="${WORK_DIR:-$ROOT_DIR/.build/pixi-apt}"
readonly OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
readonly API_REPO="${API_REPO:-prefix-dev/pixi}"
readonly API_URL="https://api.github.com/repos/$API_REPO/releases"
readonly MAX_BYTES="${MAX_BYTES:-1000000000}"
readonly USER_AGENT='pixi-apt-sync'
readonly INDEX_TEMPLATE="$ROOT_DIR/templates/index.html"
readonly APT_SUITE="${APT_SUITE:-stable}"
readonly APT_COMPONENT="${APT_COMPONENT:-main}"
readonly APT_ORIGIN='Unofficial Pixi Mirror'
readonly APT_LABEL='Unofficial Pixi Mirror'
readonly APT_DESCRIPTION='Unofficial APT repository for repackaged Pixi upstream Linux binaries'
readonly PACKAGE_NAME='pixi'
readonly DEB_MAINTAINER="${DEB_MAINTAINER:-Unofficial Pixi Mirror <noreply@example.invalid>}"
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
	command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

github_api_get() {
	local url=$1
	local args=(
		-fsSL
		-H 'Accept: application/vnd.github+json'
		-H "User-Agent: $USER_AGENT"
	)

	[[ -n ${GITHUB_TOKEN:-} ]] && args+=(-H "Authorization: Bearer $GITHUB_TOKEN")

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

supported_asset_name() {
	local filename=$1

	case $filename in
	pixi-x86_64-unknown-linux-musl.tar.gz | \
		pixi-aarch64-unknown-linux-musl.tar.gz | \
		pixi-riscv64gc-unknown-linux-gnu.tar.gz)
		return 0
		;;
	esac

	return 1
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
	jq -c '.assets[] | select(.name | test("^pixi-(x86_64|aarch64)-unknown-linux-musl\\.tar\\.gz$|^pixi-riscv64gc-unknown-linux-gnu\\.tar\\.gz$"))'
}

release_supported_asset_count() {
	supported_asset_stream | jq -s 'length'
}

validate_release_assets() {
	local release_json=$1

	while IFS= read -r name; do
		[[ -n $name ]] || continue
		supported_asset_name "$name" || fail "unrecognized supported asset naming scheme: $name"
	done < <(supported_asset_stream <<<"$release_json" | jq -r '.name')
}

release_supported_asset_bytes() {
	supported_asset_stream | jq -s '[.[].size] | add // 0'
}

collect_stable_releases() {
	local releases_file=$1
	: >"$releases_file"

	local page=1
	local page_size=100
	while :; do
		local payload
		payload="$(github_api_get "$API_URL?per_page=$page_size&page=$page")"

		local count
		count="$(jq 'length' <<<"$payload")"
		[[ $count -eq 0 ]] && break

		jq -c '.[] | select(.draft | not) | select(.prerelease | not)' <<<"$payload" >>"$releases_file"
		((page += 1))

		[[ $count -lt $page_size ]] && break
	done
}

newest_release_snapshot() {
	jq -S -c '{
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
	local releases_file
	releases_file="$(mktemp)"

	collect_stable_releases "$releases_file"
	[[ -s $releases_file ]] || fail 'no stable releases found'

	local current_snapshot
	current_snapshot="$(head -n 1 "$releases_file" | newest_release_snapshot)"
	rm -f "$releases_file"

	local previous_manifest
	if ! previous_manifest="$(curl -fsSL -H "User-Agent: $USER_AGENT" "$previous_manifest_url")"; then
		printf '%s\n' 'true'
		return
	fi

	local previous_snapshot
	if ! previous_snapshot="$(jq -e -S -c '.newest_release' <<<"$previous_manifest" 2>/dev/null)"; then
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
	[[ ${#releases[@]} -eq 0 ]] && fail 'no stable releases found'
	[[ "$(release_supported_asset_count <<<"${releases[0]}")" -eq 0 ]] && fail 'latest stable release has no supported Linux assets'

	local selected_releases=()
	local selected_bytes=()
	local total_bytes=0
	local idx
	for ((idx = ${#releases[@]} - 1; idx >= 0; idx--)); do
		local release_json=${releases[idx]}
		local asset_count
		asset_count="$(release_supported_asset_count <<<"$release_json")"
		[[ $asset_count -eq 0 ]] && continue

		validate_release_assets "$release_json"

		local asset_bytes
		asset_bytes="$(release_supported_asset_bytes <<<"$release_json")"
		((asset_bytes > MAX_BYTES)) && fail "release $(jq -r '.tag_name' <<<"$release_json") exceeds MAX_BYTES=$MAX_BYTES"

		while ((${#selected_releases[@]} > 0)) && ((MAX_BYTES - total_bytes < asset_bytes)); do
			total_bytes=$((total_bytes - selected_bytes[0]))
			selected_releases=("${selected_releases[@]:1}")
			selected_bytes=("${selected_bytes[@]:1}")
		done

		selected_releases+=("$release_json")
		selected_bytes+=("$asset_bytes")
		total_bytes=$((total_bytes + asset_bytes))
	done

	[[ ${#selected_releases[@]} -eq 0 ]] && fail 'no stable releases selected'

	write_release_list "$selected_file" "${selected_releases[@]}"
}

evict_oldest_release() {
	local selected_file=$1
	local tmp_file
	tmp_file="$(mktemp)"

	if ! tail -n +2 "$selected_file" >"$tmp_file"; then
		rm -f "$tmp_file"
		return 1
	fi

	mv "$tmp_file" "$selected_file"
	[[ ! -s $selected_file ]] && fail 'cannot evict the final retained release'
}

locate_pixi_binary() {
	local extract_dir=$1

	if [[ -f $extract_dir/pixi ]]; then
		printf '%s\n' "$extract_dir/pixi"
		return
	fi

	local binary_path
	binary_path="$(find "$extract_dir" -type f -name 'pixi' | head -n 1)"
	[[ -n $binary_path ]] || fail "unable to locate pixi binary in extracted asset"
	printf '%s\n' "$binary_path"
}

write_control_file() {
	local control_file=$1
	local version=$2
	local arch=$3

	cat >"$control_file" <<EOF
Package: $PACKAGE_NAME
Version: $version
Section: utils
Priority: optional
Architecture: $arch
Maintainer: $DEB_MAINTAINER
Homepage: https://github.com/prefix-dev/pixi
Description: Cross-platform package manager and workflow tool
 Repackaged upstream Pixi Linux release binary from prefix-dev/pixi.
 This package is generated by an unofficial APT repository.
EOF
}

build_deb_from_asset() {
	local asset_path=$1
	local version=$2
	local arch=$3
	local release_id=$4
	local out_deb=$5

	local staging_dir="$WORK_DIR/package-build/$release_id/$arch"
	local extract_dir="$staging_dir/extract"
	local package_root="$staging_dir/root"
	rm -rf "$staging_dir"
	mkdir -p "$extract_dir" "$package_root/DEBIAN" "$package_root/usr/bin"
	chmod 0755 "$package_root" "$package_root/DEBIAN" "$package_root/usr" "$package_root/usr/bin"

	tar -xzf "$asset_path" -C "$extract_dir"
	local pixi_binary
	pixi_binary="$(locate_pixi_binary "$extract_dir")"
	install -m 0755 "$pixi_binary" "$package_root/usr/bin/pixi"
	write_control_file "$package_root/DEBIAN/control" "$version" "$arch"

	dpkg-deb --build --root-owner-group "$package_root" "$out_deb" >/dev/null
}

download_selected_assets() {
	local selected_file=$1
	local manifest_file=$2

	mkdir -p "$WORK_DIR/downloads"
	: >"$manifest_file"

	while IFS= read -r release_json; do
		[[ -n $release_json ]] || continue

		local release_id
		release_id="$(jq -r '.id' <<<"$release_json")"
		local tag_name
		tag_name="$(jq -r '.tag_name' <<<"$release_json")"
		local published_at
		published_at="$(jq -r '.published_at' <<<"$release_json")"
		local release_page_url
		release_page_url="$(jq -r '.html_url' <<<"$release_json")"
		local source_tarball_url
		source_tarball_url="$(jq -r '.tarball_url' <<<"$release_json")"
		local source_zipball_url
		source_zipball_url="$(jq -r '.zipball_url' <<<"$release_json")"

		while IFS= read -r asset_json; do
			[[ -n $asset_json ]] || continue

			local name
			name="$(jq -r '.name' <<<"$asset_json")"
			local arch
			arch="$(deb_arch_from_asset_name "$name")"
			local url
			local size
			url="$(jq -r '.browser_download_url' <<<"$asset_json")"
			size="$(jq -r '.size' <<<"$asset_json")"
			local destination
			destination="$WORK_DIR/downloads/$release_id/$name"

			mkdir -p "$(dirname -- "$destination")"
			[[ -f $destination ]] || curl -fsSL -H "User-Agent: $USER_AGENT" -o "$destination" "$url"

			local version
			version="${tag_name#v}"
			local deb_name="${PACKAGE_NAME}_${version}_${arch}.deb"
			local package_output="$WORK_DIR/generated-debs/$release_id/$deb_name"
			mkdir -p "$(dirname -- "$package_output")"
			build_deb_from_asset "$destination" "$version" "$arch" "$release_id" "$package_output"

			local package_name
			package_name="$(dpkg-deb -f "$package_output" Package)"
			local package_version
			package_version="$(dpkg-deb -f "$package_output" Version)"
			local package_arch
			package_arch="$(dpkg-deb -f "$package_output" Architecture)"

			[[ $package_name == "$PACKAGE_NAME" ]] || fail "unexpected package name in $deb_name: $package_name"
			[[ $package_version == "$version" ]] || fail "unexpected version in $deb_name: $package_version"
			[[ $package_arch == "$arch" ]] || fail "architecture mismatch for $deb_name: expected $arch got $package_arch"

			local out_pool="$OUT_DIR/pool/main/p/pixi/$arch/$release_id"
			mkdir -p "$out_pool"
			cp "$package_output" "$out_pool/$deb_name"

			jq -nc \
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
				--arg upstream_sha256 "$(sha256sum "$destination" | awk '{print $1}')" \
				--arg package_name "$package_name" \
				--arg package_arch "$package_arch" \
				--arg version "$package_version" \
				--arg pool_path "pool/main/p/pixi/$arch/$release_id/$deb_name" \
				--arg sha256 "$(sha256sum "$package_output" | awk '{print $1}')" \
				--argjson upstream_size "$size" \
				--argjson package_size "$(stat -c '%s' "$package_output")" \
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
					upstream_sha256: $upstream_sha256,
					package_name: $package_name,
					package_arch: $package_arch,
					version: $version,
					package_size: $package_size,
					pool_path: $pool_path,
					sha256: $sha256
				}' >>"$manifest_file"
		done < <(supported_asset_stream <<<"$release_json")
	done <"$selected_file"
}

generate_apt_metadata() {
	local manifest_file=$1

	mapfile -t arches < <(jq -r '.arch' "$manifest_file" | sort -u)
	local arch
	for arch in "${arches[@]}"; do
		[[ -n $arch ]] || continue
		local binary_dir="$OUT_DIR/dists/$APT_SUITE/$APT_COMPONENT/binary-$arch"
		local pool_dir="pool/main/p/pixi/$arch"
		mkdir -p "$binary_dir"
		(
			cd "$OUT_DIR"
			apt-ftparchive packages "$pool_dir" >"$binary_dir/Packages"
		)
		gzip -9c "$binary_dir/Packages" >"$binary_dir/Packages.gz"
	done

	local suite_dir="$OUT_DIR/dists/$APT_SUITE"
	local release_raw="$WORK_DIR/${APT_SUITE}.Release.raw"
	apt-ftparchive \
		-o "APT::FTPArchive::Release::Origin=$APT_ORIGIN" \
		-o "APT::FTPArchive::Release::Label=$APT_LABEL" \
		-o "APT::FTPArchive::Release::Suite=$APT_SUITE" \
		-o "APT::FTPArchive::Release::Codename=$APT_SUITE" \
		-o "APT::FTPArchive::Release::Architectures=${arches[*]}" \
		-o "APT::FTPArchive::Release::Components=$APT_COMPONENT" \
		-o "APT::FTPArchive::Release::Description=$APT_DESCRIPTION" \
		release "$suite_dir" >"$release_raw"
	normalize_release_file "$release_raw" "$suite_dir/Release" "$APT_SUITE"
	rm -f "$release_raw"
}

sign_repository_metadata() {
	[[ -n ${APT_GPG_PRIVATE_KEY:-} ]] || fail 'APT_GPG_PRIVATE_KEY is required'

	export GNUPGHOME="$WORK_DIR/gnupg"
	rm -rf "$GNUPGHOME"
	mkdir -p "$GNUPGHOME"
	chmod 700 "$GNUPGHOME"

	gpg --batch --import <<<"$APT_GPG_PRIVATE_KEY" >/dev/null 2>&1

	local key_id
	key_id="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^sec:/ { print $5; exit }')"
	[[ -n $key_id ]] || fail 'no secret key available after import'

	gpg --batch --yes --export "$key_id" >"$OUT_DIR/pixi-archive-keyring.gpg"

	while IFS= read -r release_file; do
		[[ -n $release_file ]] || continue
		local release_dir
		release_dir="$(dirname -- "$release_file")"
		gpg --batch --yes --clearsign -u "$key_id" -o "$release_dir/InRelease" "$release_file"
		gpg --batch --yes --detach-sign -u "$key_id" -o "$release_dir/Release.gpg" "$release_file"
	done < <(find "$OUT_DIR/dists" -name 'Release' -type f | sort)
}

write_release_manifest() {
	local manifest_file=$1
	local selected_file=$2
	local newest_release
	newest_release="$(tail -n 1 "$selected_file" | newest_release_snapshot)"

	jq -s \
		--arg api_repo "$API_REPO" \
		--arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg package_name "$PACKAGE_NAME" \
		--arg suite "$APT_SUITE" \
		--argjson max_bytes "$MAX_BYTES" \
		--argjson newest_release "$newest_release" \
		"$RELEASES_MANIFEST_FILTER" \
		"$manifest_file" >"$OUT_DIR/releases.json"
}

measure_pages_artifact_bytes() {
	local archive="$WORK_DIR/pages-size-check.tar"
	rm -f "$archive"
	tar \
		--dereference --hard-dereference \
		--directory "$OUT_DIR" \
		-cf "$archive" \
		.
	stat -c '%s' "$archive"
	rm -f "$archive"
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

	rm -rf "$OUT_DIR"
	mkdir -p "$OUT_DIR"

	download_selected_assets "$selected_file" "$manifest_file"
	generate_apt_metadata "$manifest_file"
	sign_repository_metadata
	write_release_manifest "$manifest_file" "$selected_file"
	copy_site_documents
}

enforce_pages_size_limit() {
	local selected_file=$1
	local manifest_file=$2

	build_repository "$selected_file" "$manifest_file"
	while (($(measure_pages_artifact_bytes) >= MAX_BYTES)); do
		evict_oldest_release "$selected_file"
		build_repository "$selected_file" "$manifest_file"
	done
}

main() {
	if [[ ${1:-} == '--check-newest-release' ]]; then
		[[ $# -eq 2 ]] || fail "usage: $SCRIPT_NAME --check-newest-release URL"
		require_command curl
		require_command jq
		check_newest_release_changed "$2"
		return
	fi
	[[ $# -eq 0 ]] || fail "usage: $SCRIPT_NAME [--check-newest-release URL]"

	local required_command_name
	for required_command_name in \
		apt-ftparchive \
		curl \
		dpkg-deb \
		find \
		gpg \
		gzip \
		install \
		jq \
		perl \
		sha256sum \
		stat \
		tar; do
		require_command "$required_command_name"
	done

	rm -rf "$WORK_DIR" "$OUT_DIR"
	mkdir -p "$WORK_DIR" "$OUT_DIR"

	local releases_file="$WORK_DIR/releases.ndjson"
	local selected_file="$WORK_DIR/selected.ndjson"
	local manifest_file="$WORK_DIR/manifest.ndjson"

	collect_stable_releases "$releases_file"
	select_retained_releases "$releases_file" "$selected_file"
	enforce_pages_size_limit "$selected_file" "$manifest_file"
}

main "$@"
