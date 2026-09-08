#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(
	if ! cd -- "$(dirname -- "${BASH_SOURCE[0]}")"; then
		exit 1
	fi
	pwd
)"

if [[ $# -ne 2 ]]; then
	printf 'usage: %s MANIFEST_URL FORCE_BUILD\n' "$(basename -- "$0")" >&2
	exit 2
fi

manifest_url=$1
force_build=$2
case $force_build in
true | false) ;;
*)
	printf '%s\n' 'FORCE_BUILD must be true or false' >&2
	exit 2
	;;
esac

if ! changed="$("$SCRIPT_DIR/sync-apt-repo.sh" --check-newest-release "$manifest_url")"; then
	printf '%s\n' 'newest release poll failed' >&2
	exit 1
fi

case $changed in
true | false) ;;
*)
	printf 'unexpected newest release poll result: %s\n' "$changed" >&2
	exit 1
	;;
esac

if [[ $force_build == true ]]; then
	changed=true
fi

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
printf 'changed=%s\n' "$changed" >>"$GITHUB_OUTPUT"
