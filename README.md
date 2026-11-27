# HashForge for Umbrel

[![Lint and test](https://github.com/owenashurst/HashForge-Umbrel/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/owenashurst/HashForge-Umbrel/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

An [Umbrel](https://umbrel.com) app that runs [HashForge](https://github.com/owenashurst/HashForge), the
open-source Bitcoin mining pool, on your own node. This repository is an Umbrel Community App Store: add
it to your Umbrel and HashForge appears in the store, ready to install.

## Installing

1. Install the **Bitcoin Node** app from the Umbrel App Store if you have not already. HashForge uses it.
2. In umbrelOS, open the **App Store**, open the **⋯** menu in the top right and choose
   **Community App Stores**.
3. Add `https://github.com/owenashurst/HashForge-Umbrel`.
4. Open the HashForge store that appears, and install **HashForge**.

The app opens to the pool's home page. Its **Connect** page shows the address to point your miners at.
Mining begins once your Bitcoin node has finished synchronising.

## What you get

| Part | What it does |
|---|---|
| HashForge pool | The Stratum server miners connect to, the payout logic and the web interface |
| PostgreSQL | Keeps the permanent records: blocks found, payouts and miner statistics |
| Redis | Keeps snapshots of the pool's live state so a restart loses nothing |

The Bitcoin node is the one your Umbrel already runs; the app does not download the blockchain again.

- **Solo pool on port 3342**, with no fee, running as soon as the app is installed. Use your own Bitcoin
  address as the miner's user name; anything after a dot is the worker's name.
- **Ports 3337 to 3341** are free for shared pools (PPLNS, proportional, finder bonus), which you add
  from the pool's admin page at `/admin`.
- **The web interface** is behind your Umbrel login, like any other Umbrel app. The read-only JSON API
  under `/api` is the exception, so that other apps (a phone app following the pool, say) can read the
  pool's statistics without signing in to Umbrel.

## Differences from HashForge on plain Docker

- **A shared pool pays at most ten addresses per block.** Every payout takes block space that the
  Bitcoin node must have kept free. HashForge's own Docker stack starts its node with a large
  reservation; the Bitcoin Node app's reservation is not ours to change, so the package caps payouts at
  what fits within Bitcoin Core's default. The ten with the most work are paid; in a PPLNS pool the
  others stay in the window for later blocks.
- **Settings are changed from the admin page**, not from a settings file.
- **The admin page asks for a password.** Umbrel's login protects the whole app from other people, but
  other apps installed on the same Umbrel share a network with the pool. So the admin page also asks
  for the app's own password, which umbrelOS creates for each install: right-click the app's icon and
  choose **Show default credentials**. Any user name works.

## Releasing an update

1. Tag a release in [HashForge](https://github.com/owenashurst/HashForge), for example `v0.2.0`. Its
   Publish workflow builds the pool image and prints the image's digest in the run summary.
2. In [`hashforge-pool/docker-compose.yml`](hashforge-pool/docker-compose.yml), change the pool image's
   tag and digest together.
3. In [`hashforge-pool/umbrel-app.yml`](hashforge-pool/umbrel-app.yml), raise `version` to match and
   describe the change in `releaseNotes`.
4. Push to `main`. Umbrels that have this store added are offered the update.

A change to the package alone, with the same pool image, still needs a new `version` or nobody is
offered it: add a revision to the current one, as in `0.1.7-1`.

## The official Umbrel App Store

The package is written to the official store's rules. `tools/official-package.sh <folder>` writes it
in the form that store expects (the app's ID becomes `hashforge`), ready to copy into a fork of
[getumbrel/umbrel-apps](https://github.com/getumbrel/umbrel-apps) for a pull request.

## Project layout

```
umbrel-app-store.yml            Tells umbrelOS this is a community app store
hashforge-pool/
  umbrel-app.yml                The app's listing: name, version, description, port
  docker-compose.yml            The pool, PostgreSQL and Redis
  exports.sh                    Passwords for the database and cache, derived per Umbrel
  data/                         Empty folders umbrelOS creates for the app's data
tests/
  smoke.sh                      Starts the package with stand-ins for what umbrelOS provides
  umbrel-stand-in.yml           Those stand-ins: a proxy placeholder and a regtest Bitcoin node
tools/
  official-package.sh           Writes the package in the official store's form
```

## Testing

```bash
tests/smoke.sh
```

This needs Docker and an image called `hashforge-bitcoind`, built from `docker/bitcoind` in the
HashForge repository. It starts the package with stand-ins for umbrelOS's variables, proxy and Bitcoin
Node app, then checks that the pool answers, a miner can connect, the databases need their passwords
and the data survives a restart. Pass an image name as the first argument to test a pool build that has
not been published.

The smoke test catches mistakes in the package early. It is not a test on umbrelOS: install, update,
the login proxy and backups can only be checked on a real Umbrel.

## License

[MIT](LICENSE)
