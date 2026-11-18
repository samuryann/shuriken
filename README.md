# shuriken

**Small, sharp scripts for IT professionals.**
Built by [Samuryann](https://github.com/samuryann), assisted by [Claude](https://claude.com).

A shuriken is small and sharp, and you carry several. This repo is a set of single-purpose scripts and MSP tools. Each one does one job, lives in its own folder, and has its own README. Copy the one you need, read it, run it.

Looking for Claude Code add-ons? See the sister repo, [ronin-toolkit](https://github.com/samuryann/ronin-toolkit).

## Licence

MIT with Commons Clause. The full text is in [LICENSE](LICENSE). In plain terms:

- **Free to use**, including at work and for your own clients.
- **Free to change and share.** Keep the licence notice with any copy.
- **Not for sale.** You can't sell these tools, or charge for a product or service that is mostly these tools.
- **No warranty. You use them at your own risk.** You are responsible for what they do on your systems. Test first and take a snapshot or backup before you run anything.

The plain-terms list is a summary. If it and the LICENSE file disagree, the LICENSE file wins.

## Tools

| Tool | What it does |
|---|---|
| [`graylog-upgrade`](#graylog-upgrade) | Walks a Graylog Open server (and Data Node) up to the latest version, one minor at a time, with checks before each hop |

<a id="graylog-upgrade"></a>
## graylog-upgrade

An interactive upgrade script for Graylog Open on Ubuntu or Debian. It scans the server, finds the newest versions, plans the path, and upgrades one minor version at a time.

Folder: [`graylog-upgrade/`](graylog-upgrade/). Full details in its [README](graylog-upgrade/README.md).

Quick start, on the Graylog server, inside tmux:

```
sudo bash graylog-upgrade.sh
```

Take a snapshot first. You run it at your own risk.
