# rpiclone

**rpiclone** is a portable offline tool intended for Raspberry Pi, but should also work for other simple two-partition Linux systems using EXT-4.  
It clones the source disk, handles shrinking if necessary to fit smaller destination drives, and expands the root filesystem after cloning to fill the empty space.

---

## Features

- Written for Fish shell
- Supports native package manager on most Linux systems
- Automatically installs required packages if missing
- Automatically handles root privilege escalation
- Shrinks source filesystem if destination disk is smaller
- Expands root partition and filesystem to fill destination disk
- Uses safe, non-destructive temporary shrinking via `/tmp`
- Wipes destination disk partition tables before cloning

---

## Requirements

- Fish shell 3.x or newer
- Linux system with:
  - `partclone`
  - `parted`
  - `e2fsprogs`
  - `dosfstools`
  - `gptfdisk` (Arch) or `gdisk` (Debian/Fedora)

Missing packages will be installed automatically.

---

## Usage

```shell
rpiclone <source device> <destination device> [options]
```

### Examples

Clone with interactive confirmations:

```shell
rpiclone /dev/sde /dev/sdd
```

Clone automatically without prompts:

```shell
rpiclone /dev/sde /dev/sdd --force
```

Display help:

```shell
rpiclone --help
```

---

## Options

| Option           | Description |
|:-----------------|:------------|
| `-f`, `--force`   | Skip all confirmation prompts and proceed automatically |
| `--help`          | Display help and usage information |

---

## Behavior

- Existing partitions / data on destination disk are destroyed.
- `/boot` partition is cloned without resizing.
- The root (`/`) partition is cloned and expanded to fill the destination disk.
- If destination is smaller than source, the root fs is shrunk using space in `/tmp` on the host machine.
- Source disk is never modified.
- Temp files cleaned up when complete.

---

## Warnings

- Always verify device names before proceeding.
- Only ext4 filesystems are supported for shrinking.
- `/tmp` must have enough free space if shrinking is required.

---

## License

MIT License.
