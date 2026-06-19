# Security Policy

This repository publishes an unofficial APT repository for repackaged upstream Pixi Linux binaries. The mirror signs APT metadata with a maintainer-controlled key.

## Scope

- The mirror signature attests to repository metadata and generated Debian packages produced by this repository.
- The mirror signature does not prove that the upstream project authored or endorsed this mirror.
- Users should independently review upstream release information and the corresponding source materials linked from `releases.json`.

## Reporting

Report security issues with this mirror, key compromise concerns, or repository metadata problems to: `lykong@utexas.edu`

Do not report upstream Pixi vulnerabilities here unless they are specific to this mirror or its packaging pipeline.

## Signing Key

- Public key file: `pixi-archive-keyring.gpg`
- Fingerprint: `06D1 6919 2B13 DB4F DB32 2244 7761 F770 091B 2FB0`
- Verification channel: publish the same fingerprint in this repository, the GitHub Pages site, and any release notes for key rotations.

## Key Rotation and Revocation

- Rotate the signing key immediately if compromise is suspected.
- Publish the replacement fingerprint before switching clients.
- Keep the previous public key available long enough for users to evaluate the transition.
- If a key is revoked, document the revocation date and affected repository snapshots in `README.md`.

## Support and Warranty

This mirror is provided as-is, without warranty. Operational issues with the mirror should be reported to the mirror maintainer, not to the upstream Pixi maintainers.
