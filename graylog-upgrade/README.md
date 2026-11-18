# graylog-upgrade

Built by [Samuryann](https://github.com/samuryann), assisted by [Claude](https://claude.com). Part of [shuriken](../README.md). Licence: MIT with Commons Clause, see [LICENSE](../LICENSE).

An interactive script that upgrades Graylog Open one minor version at a time.

## What it does

- Scans the server: installed Graylog server, Data Node, MongoDB and OpenSearch.
- Reads the latest versions live from Graylog's public repo index.
- Builds the upgrade path one minor version at a time.
- Upgrades graylog-server first, then graylog-datanode if installed.
- Simulates each hop with apt before installing anything.
- Gates each hop on a checkpoint, service health, config checks and the MongoDB version range.
- Restores apt holds on any exit.
- Starts in Preview mode by default. Nothing changes until you choose to upgrade.

## Requirements

- Graylog Open 6.0 or newer
- Ubuntu or Debian with apt and systemd
- bash 4 or newer
- Root
- Internet access, for version discovery

## How to run

1. Copy `graylog-upgrade.sh` to the server.
2. Start tmux, so a dropped session does not stop the upgrade.
3. Run it:

```
sudo bash graylog-upgrade.sh
```

No arguments are needed. The log is written to `/var/log/shuriken-graylog-upgrade-<date>.log`.

## Terms prompt

The first screen shows a short notice (MIT with Commons Clause, no warranty, you are responsible, take a snapshot first). Type `accept` to continue. Anything else exits and changes nothing.

The answer is remembered for that script version in `/root/.config/shuriken-graylog-upgrade/accepted`. A new version asks again. With no terminal on stdin and stdout, the script refuses to run unless `SHURIKEN_ACCEPT_TERMS=1` is set.

## Pinned header

On a terminal of at least 80 columns by 30 rows, the banner (or a two-line title on terminals under 45 rows) and a status bar stay at the top while output scrolls below. The bar shows host, graylog-server and datanode versions, service state, Health, current phase and hold state. It is redrawn at phase changes and after service starts, restarts and waits. It is display only and is not written to the log. On smaller terminals, or with `TERM=dumb` or output redirected, the banner prints once as before.

## What it never touches

- MongoDB
- A self-managed OpenSearch backend
- Graylog Sidecar
- The kernel

## Limits

- Tested with stubs, plus one real 6.3 to 7.0 hop on Ubuntu 24.04 with Data Node.
- The MongoDB bounds for 7.2 are inference, not tested.
- Other paths and distributions are untested.
- You run it at your own risk. Take a snapshot first.
