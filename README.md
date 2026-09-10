# Pixi APT Repository

Independent, signed APT repository for upstream [prefix-dev/pixi](https://github.com/prefix-dev/pixi) Linux releases.

This repository is unofficial. It is not operated, sponsored, or endorsed by prefix.dev or the Pixi project.

## Layout

- `scripts/sync-apt-repo.sh`: downloads upstream release assets, repackages them into `.deb` files, and builds the APT archive.
- `templates/`: checked-in site template.
- `dist/`: generated GitHub Pages site.
- `dist/dists/` and `dist/pool/`: conventional APT metadata and package storage.

## What It Publishes

- Stable upstream releases only.
- Debian packages generated from supported upstream Linux release tarballs.
- Version-specific corresponding source links for each mirrored package via `releases.json` and the GitHub Pages index.
- The newest stable releases that fit within the 1,000,000,000-byte GitHub Pages site limit.

Retained releases coexist under `pool/main/p/pixi/<arch>/` without overwriting each other.

The publisher keeps reproducible package outputs in `.build/pixi-cache` between runs. Published packages are retained, and recently used packages that were rejected by the Pages-size limit may use up to `PACKAGE_CACHE_EXTRA_BYTES` additional bytes; it defaults to the `MAX_BYTES` limit. Set that variable to reduce or disable the extra cache budget.

## Compliance and Provenance

- Original automation and templates in this repository are licensed under the MIT License in [LICENSE](LICENSE).
- Third-party licensing and attribution notes live in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- Repository signing-key handling, support boundaries, and key-rotation guidance live in [SECURITY.md](SECURITY.md).

The mirror signature attests to this repository's generated APT metadata. It does not imply that prefix.dev or the Pixi maintainers signed, reviewed, or endorsed this mirror.

## Client Install

Example for `amd64`:

```sh
curl -fsSL 'https://lingyang-kong.github.io/apt-pixi/pixi-archive-keyring.gpg' \
  | sudo tee /usr/share/keyrings/pixi-archive-keyring.gpg >/dev/null

echo 'deb [signed-by=/usr/share/keyrings/pixi-archive-keyring.gpg] https://lingyang-kong.github.io/apt-pixi stable main' \
  | sudo tee /etc/apt/sources.list.d/pixi.list

sudo apt update
sudo apt install pixi
```

## Support

Operational problems with this mirror should be reported to the mirror maintainer. Upstream Pixi issues should be reported to the upstream project unless they are specific to this mirror's packaging or repository metadata.
