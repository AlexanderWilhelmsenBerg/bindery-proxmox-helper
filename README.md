# Bindery Proxmox Helper

A standalone, Community-Scripts-inspired Proxmox VE helper for installing and managing [Bindery](https://github.com/vavallee/bindery) as a native Debian 13 LXC.

This project is independent of both Bindery and the Proxmox VE Community Scripts project.

## Privacy and telemetry

[Upstream Bindery telemetry](https://github.com/vavallee/bindery/blob/main/PRIVACY.md) normally contacts `https://api.getbindery.dev/api/ping` on first start and then about once per day. Its documented payload categories are a persistent random installation ID; Bindery version, OS, architecture and deployment method; numeric/boolean feature and setup counts; and coarse recent warning/error counts plus frequent fixed developer-written message strings. Consult Bindery's linked `PRIVACY.md` for the authoritative current field list and retention details.

The installation wizard presents this disclosure before Bindery is installed and asks whether to allow it. **Disable before first start** is the privacy-first default; it writes `BINDERY_TELEMETRY_DISABLED=true` before the first service start, so Bindery never sends an initial telemetry ping. The helper itself does not collect telemetry.

This opt-out only concerns Bindery telemetry. Installation and updates still contact Debian mirrors and GitHub over HTTPS to download packages, release metadata, checksums and the Bindery binary.

## Install

Run on the **Proxmox VE host as root**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/AlexanderWilhelmsenBerg/bindery-proxmox-helper/main/bindery-lxc.sh)"
```

The same command can later be used to open the host-side management menu.

## Storage model

The wizard deliberately treats these as three independent choices:

1. **LXC root disk** — selected from active Proxmox storage that supports `rootdir` (`local-lvm`, ZFS, directory storage, etc.).
2. **Downloads** — select a filesystem already mounted on the Proxmox host, then browse to or create a folder.
3. **Audiobooks** — independently select a mounted host filesystem, then browse to or create a folder.

The root disk never has to live on the same storage as downloads or audiobooks.

When downloads and audiobooks are on the same host filesystem and share a safe common parent, the helper exposes that parent as a single `/data` bind mount. That allows Bindery to hardlink imports rather than copy them. When that is not possible, it creates two narrow bind mounts and Bindery can fall back to copying.

The helper will not expose the Proxmox host `/` as the common media mount.

## What the installer does

- Debian 13 LXC
- Default and Advanced setup modes
- Separate Proxmox `rootdir` storage picker
- DHCP or validated static IPv4 configuration
- Explicit IPv6 choice (SLAAC, DHCPv6 or no automatic address)
- Optional VLAN and SSH
- Unprivileged LXC by default
- Mounted-drive and folder browser for media
- Optional POSIX ACL setup for Bindery UID 1000
- Optional qBittorrent/download-client path remap
- Native official Bindery Linux release, not Docker
- Official SHA-256 checksum verification
- systemd service running as the dedicated `bindery` user
- Built-in Bindery healthcheck after install/update
- `/usr/bin/update` updater with pre-upgrade data backup and automatic rollback
- Manual `bindery-backup` command
- Host management menu for update, backup, status, logs and shell
- Media bind mounts marked `backup=0`
- Explicit Bindery telemetry choice before the first service start

## Updating

From inside the LXC:

```bash
update
```

The updater downloads the latest official GitHub release, verifies its checksum, shuts Bindery down cleanly, backs up application data, switches releases, and runs Bindery's own healthcheck. If the new version does not become healthy, the updater restores both the previous release and the pre-update data backup. If restoration itself fails, it leaves Bindery stopped rather than risking the database with mismatched application code.

Updates and manual backups use the same maintenance lock. If one maintenance operation is already running, a second one exits instead of stopping the service or changing files concurrently.

## Media permissions

Bindery runs as UID/GID `1000:1000` inside the LXC. For a standard unprivileged Proxmox LXC this maps to host UID/GID `101000:101000`.

The wizard can add POSIX ACLs for the mapped UID, including default ACLs for new files and optional recursive ACLs for an existing library. It does **not** use `chmod 777` and does not take ownership of the media tree.

Some network/non-POSIX filesystems may not support host ACLs in this way. In that case choose the existing-permissions option or configure permissions on the storage server, and the installer will still verify actual read/write access from the Bindery UID before declaring success.

## Download-client paths

The cleanest layout is for Bindery and qBittorrent/SABnzbd to see the same storage at matching paths. If the download client reports another path, the wizard can seed Bindery's global `BINDERY_DOWNLOAD_PATH_REMAP`, or you can configure a per-client remap later in Bindery.

## Safety notes

- Media choices are **existing mounted host filesystems**, not raw disks. The helper never formats or mounts a disk.
- The host root (`/`) and protected operating-system/Proxmox paths cannot be selected as media. The selected folder must still belong to the exact mounted filesystem chosen in the wizard; nested or replaced mounts are rejected.
- Bind-mount source paths are canonicalized and unsafe Proxmox option delimiters/control characters are rejected.
- Selected media is not included in Proxmox container backups.
- A host-side pre-start guard verifies that each selected filesystem is still mounted with the identity recorded at installation. It blocks container startup if media is missing or a different filesystem is mounted at that path, avoiding accidental writes into the underlying host directory. Restore the expected mount, then start the container again.
- The media paths and generated pre-start guard are local to the Proxmox node. Treat the LXC as node-pinned unless a migration destination has equivalent host mounts and the guard is deliberately recreated there.
- During installation, the helper also checks the container-side paths as Bindery's unprivileged service user before it starts Bindery for the first time.
- A failed installation leaves the LXC in place for inspection rather than automatically deleting it.
- CI validates Bash syntax, embedded scripts and units, static analysis, and testable helper logic. It cannot emulate Proxmox storage, LXC id-mapping, hook execution, or `pct create` end-to-end. A disposable real Proxmox VE host remains the required acceptance test before relying on changes to container creation, storage, mounts or permissions.

## Development

Run the local smoke tests with:

```bash
bash tests/smoke.sh
```

The complete CI check also uses ShellCheck and `systemd-analyze verify`; install the `shellcheck`, `systemd` and `jq` packages to run those checks locally.

## License

MIT. Bindery itself has its own upstream license and bundled third-party notices.
