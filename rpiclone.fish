function rpiclone --description 'Offline Raspberry Pi OS disk cloner (portable, safe, fish shell)'

    set -l usage_text "
rpiclone - Safe Raspberry Pi OS disk cloner (offline use)

Usage:
  rpiclone <source device> <destination device> [options]

Examples:
  rpiclone /dev/sde /dev/sdd
  rpiclone /dev/sde /dev/sdd --force
  rpiclone /dev/sde /dev/sdd -f

Options:
  -f, --force   Skip all confirmations (DANGEROUS)
  --help        Show this help message and exit

Functionality:
- Clones Raspberry Pi OS disk partitions from source to destination.
- Automatically adjusts the root partition to fully occupy the destination device.
- Safely expands the filesystem after cloning (ext4 supported).
- Analyzes partition layouts for sanity before proceeding.
- Auto-installs required system packages if missing (Arch, Debian, Ubuntu, Fedora supported).
- Requires root privileges (auto-prompts if necessary).
- Wipes GPT/MBR on destination disk before writing new partitions.
"

    # --help flag
    if contains -- --help $argv
        echo "$usage_text"
        return 0
    end

    if test (count $argv) -lt 2
        echo "$usage_text"
        return 1
    end

    # Variables
    set -l src (string replace '/dev/' '' $argv[1])
    set -l dst (string replace '/dev/' '' $argv[2])
    set -l args $argv[3..-1]
    set -l force_mode (contains --force $args; or contains -f $args)

    # Ensure running as root
    if test (id -u) -ne 0
        echo "Root privileges required. Re-running with sudo..."
        exec sudo fish -c "rpiclone $argv"
    end

    # Distro detection and package install
    function install_dependencies
        set -l required partclone parted dosfstools e2fsprogs
        if test -f /etc/arch-release
            set -a required gptfdisk
            for pkg in $required
                if not pacman -Qq $pkg >/dev/null 2>&1
                    echo "Installing missing package: $pkg"
                    pacman -S --noconfirm $pkg
                end
            end
        else if test -f /etc/debian_version
            set -a required gdisk
            for pkg in $required
                if not dpkg -s $pkg >/dev/null 2>&1
                    echo "Installing missing package: $pkg"
                    apt-get update && apt-get install -y $pkg
                end
            end
        else if test -f /etc/fedora-release
            set -a required gdisk
            for pkg in $required
                if not dnf list installed $pkg >/dev/null 2>&1
                    echo "Installing missing package: $pkg"
                    dnf install -y $pkg
                end
            end
        else
            echo "Unsupported Linux distribution. Install these manually: partclone parted dosfstools e2fsprogs gptfdisk/gdisk"
            exit 1
        end
    end

    install_dependencies

    # Check devices exist
    if not test -b /dev/$src
        echo "Error: Source device /dev/$src not found."
        return 1
    end
    if not test -b /dev/$dst
        echo "Error: Destination device /dev/$dst not found."
        return 1
    end

    # Analyze partitions
    set -l src_parts (lsblk -rpno NAME /dev/$src | grep -v "/dev/$src")
    set -l dst_parts (lsblk -rpno NAME /dev/$dst | grep -v "/dev/$dst")

    set -l dst_part_count (count $dst_parts)

    if test $dst_part_count -gt 2
        if not set -q force_mode
            echo "Warning: Destination device /dev/$dst has $dst_part_count partitions!"
            read -P "All partitions and data will be destroyed. Proceed? (yes/no): " confirm
            if test "$confirm" != "yes"
                echo "Aborted."
                return 1
            end
        end
    end

    echo "Preparing to clone:"
    echo "  Source:      /dev/$src"
    echo "  Destination: /dev/$dst"

    if not set -q force_mode
        read -P "ALL data on /dev/$dst will be ERASED. Proceed? (yes/no): " confirm
        if test "$confirm" != "yes"
            echo "Aborted."
            return 1
        end
    end

    # Unmount everything just in case
    umount /dev/${src}* /dev/${dst}* >/dev/null 2>&1

    # Zap destination disk
    echo "Wiping destination disk /dev/$dst..."
    if type -q sgdisk
        sgdisk --zap-all /dev/$dst
    else
        wipefs -a /dev/$dst
    end

    # Clone partitions
    echo "Cloning boot partition..."
    partclone.vfat -s /dev/${src}1 -o /dev/${dst}1 || begin; echo "Boot partition clone failed!"; exit 1; end

    echo "Cloning root partition..."
    partclone.ext4 -s /dev/${src}2 -o /dev/${dst}2 || begin; echo "Root partition clone failed!"; exit 1; end

    # Resize root partition
    echo "Expanding root partition to fill destination disk..."
    parted /dev/$dst resizepart 2 100% --script
    partprobe /dev/$dst
    sleep 2

    echo "Resizing ext4 filesystem on root partition..."
    resize2fs /dev/${dst}2

    echo "Clone and resize complete!"
end
