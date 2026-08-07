# dddkit APT repository

Published at `https://gradyzhuo.github.io/swift-ddd-kit/apt/` by the existing
`pages.yml` GitHub Pages workflow (this directory is under `docs/`, which that
workflow already watches).

Managed by [`reprepro`](https://mirrorer.alioth.debian.org/) — `conf/distributions`
is the only hand-maintained file; `db/`, `dists/`, and `pool/` are reprepro's
generated state and are committed as-is so that `.github/workflows/release.yml`
can add new `.deb`s incrementally on every tagged release instead of rebuilding
the repo from scratch.

`pubkey.gpg` is the repo's public signing key (private half lives only in the
`APT_SIGNING_KEY` repo secret, used by CI to sign `Release`).

## Install (end users)

```bash
curl -fsSL https://gradyzhuo.github.io/swift-ddd-kit/apt/pubkey.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/dddkit.gpg
echo "deb [signed-by=/usr/share/keyrings/dddkit.gpg] https://gradyzhuo.github.io/swift-ddd-kit/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/dddkit.list
sudo apt update && sudo apt install dddkit
```
