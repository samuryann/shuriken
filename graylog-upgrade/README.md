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
