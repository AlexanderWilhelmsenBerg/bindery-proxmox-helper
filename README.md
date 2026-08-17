# Bindery Proxmox Helper

A standalone, Community-Scripts-inspired Proxmox VE helper for installing and managing [Bindery](https://github.com/vavallee/bindery) as a native Debian 13 LXC.

This project is independent of both Bindery and the Proxmox VE Community Scripts project.

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

## Updating

From inside the LXC:

```bash
update
```

The updater downloads the latest official GitHub release, verifies its checksum, shuts Bindery down cleanly, backs up application data, switches releases, and runs Bindery's own healthcheck. If the new version does not become healthy, the updater restores both the previous release and the pre-update data backup. If restoration itself fails, it leaves Bindery stopped rather than risking the database with mismatched application code.

## Media permissions

Bindery runs as UID/GID `1000:1000` inside the LXC. For a standard unprivileged Proxmox LXC this maps to host UID/GID `101000:101000`.

The wizard can add POSIX ACLs for the mapped UID, including default ACLs for new files and optional recursive ACLs for an existing library. It does **not** use `chmod 777` and does not take ownership of the media tree.

Some network/non-POSIX filesystems may not support host ACLs in this way. In that case choose the existing-permissions option or configure permissions on the storage server, and the installer will still verify actual read/write access from the Bindery UID before declaring success.

## Download-client paths

The cleanest layout is for Bindery and qBittorrent/SABnzbd to see the same storage at matching paths. If the download client reports another path, the wizard can seed Bindery's global `BINDERY_DOWNLOAD_PATH_REMAP`, or you can configure a per-client remap later in Bindery.

## Safety notes

- Media choices are **existing mounted host filesystems**, not raw disks. The helper never formats or mounts a disk.
- Bind-mount source paths are canonicalized and unsafe Proxmox option delimiters/control characters are rejected.
- Selected media is not included in Proxmox container backups.
- A failed installation leaves the LXC in place for inspection rather than automatically deleting it.
- A real Proxmox host smoke test is recommended before merging changes that touch LXC creation, storage or permissions. CI validates Bash syntax and testable helper logic but cannot emulate `pct create` end-to-end.

## Development

Run the local smoke tests with:

```bash
bash tests/smoke.sh
```

## License

MIT. Bindery itself has its own upstream license and bundled third-party notices.
