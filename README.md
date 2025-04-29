# rpiclone
**rpiclone** is a portable offline tool intended for Raspberry Pi, but should also work for other simple two-partition Linux systems using EXT-4.  
It clones the source disk, handles shrinking if necessary to fit smaller destination drives, and expands the root filesystem after cloning to fill the empty space.
---
## Features
- Written for Fish shell
- Supports native package manager on most Linux systems (Arch, Debian, Ubuntu, Fedora)
- Automatically installs required packages if missing
- Automatically handles root privilege escalation
- Only copies used blocks for faster cloning (using partclone)
- Shrinks source filesystem if destination disk is smaller
- Expands root partition and filesystem to fill destination disk
- Provides interactive device listing with detailed information
- Wipes destination disk partition tables before cloning
---
## Requirements
- Fish shell 3.x or newer
- Linux system with:
  - `partclone` (for efficient block-by-block copying)
  - `parted` (for partition management)
  - `e2fsprogs` (for ext4 filesystem operations)
  - `dosfstools` (for FAT filesystem operations)
  - `gptfdisk` (Arch) or `gdisk` (Debian/Fedora)

Missing packages will be installed automatically.
---
## Usage
```shell
# List available devices
rpiclone

# Display detailed device information
rpiclone list

# Clone a device
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
| `list`            | Display detailed information about available devices |
---
## Behavior
- Existing partitions / data on destination disk are destroyed
- `/boot` partition is cloned without resizing
- The root (`/`) partition is cloned and expanded to fill the destination disk
- If destination is smaller than source, the root filesystem is shrunk
- Only used blocks are copied, making the process much faster than full disk copying
- Source disk is never modified
- Partclone is used for efficient copying when possible
- Temporary files are cleaned up when complete
---
## Warnings
- Always verify device names before proceeding
- All data on the destination device will be destroyed
- Multiple filesystems are supported (ext4, btrfs, f2fs), but ext4 is recommended
- Only filesystems supported by partclone will use efficient block copying
- Falls back to full copying (slower) for unsupported filesystems
---
## License
MIT License.
