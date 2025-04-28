function rpiclone --description 'Offline Raspberry Pi OS disk cloner (portable, safe, auto-shrink, fish shell)'

    set -l usage_text "
rpiclone - Safe Raspberry Pi OS disk cloner (offline)

Usage:
  rpiclone <source device> <destination device> [options]

Examples:
  rpiclone /dev/sde /dev/sdd
  rpiclone /dev/sde /dev/sdd --force
  rpiclone /dev/sde /dev/sdd -f

Options:
  -f, --force   Skip confirmation prompts (DANGEROUS)
  --help        Show this help message and exit

Behavior:
- Clones /boot and / partitions from source to destination
- Automatically shrinks source filesystem if destination is smaller
- Automatically expands root partition to fill destination disk
- Automatically installs required packages if missing
- Root privileges required (auto-sudo if needed)
- Supports Arch, Debian, Ubuntu, Fedora

Notes:
- All data on destination disk will be erased
- Source disk is NEVER modified
- Temporary shrink operations use /tmp if needed
- Only ext4 root partitions are supported for shrinking
"

    if contains -- --help $argv
        echo "$usage_text"
        return 0
    end

    if test (count $argv) -lt 2
        echo "$usage_text"
        return 1
    end

    set -l src (string replace '/dev/' '' $argv[1])
    set -l dst (string replace '/dev/' '' $argv[2])
    set -l args $argv[3..-1]
    set -l force_mode (contains --force $args; or contains -f $args)

    # Ensure running as root
    if test (id -u) -ne 0
        echo "Root privileges required. Re-running with sudo..."
        exec sudo fish -c "rpiclone $argv"
    end

    # Install dependencies
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
            echo "Unsupported Linux distribution. Install: partclone parted dosfstools e2fsprogs gdisk manually."
            exit 1
        end
    end

    install_dependencies

    if not test -b /dev/$src
        echo "Error: Source device /dev/$src not found."
        return 1
    end
    if not test -b /dev/$dst
        echo "Error: Destination device /dev/$dst not found."
        return 1
    end

    # Analyze partition layouts
    set -l src_parts (lsblk -rpno NAME,SIZE,TYPE /dev/$src | grep part)
    set -l dst_parts (lsblk -rpno NAME,SIZE,TYPE /dev/$dst | grep part)

    set -l dst_part_count (count $dst_parts)

    if test $dst_part_count -gt 2
        if not set -q force_mode
            echo "Warning: Destination /dev/$dst has more than two partitions."
            read -P "Proceed and erase all partitions? (yes/no): " confirm
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

    # Unmount anything just in case
    umount /dev/${src}* /dev/${dst}* >/dev/null 2>&1

    # Get partition sizes
    set -l src_size (lsblk -bno SIZE /dev/${src}2)
    set -l dst_size (lsblk -bno SIZE /dev/${dst})

    if test $src_size -gt $dst_size
        echo "Source root partition is larger than destination disk."

        if not set -q force_mode
            read -P "Shrink root filesystem temporarily to fit destination? (yes/no): " shrink_confirm
            if test "$shrink_confirm" != "yes"
                echo "Aborted."
                return 1
            end
        end

        echo "Checking available space in /tmp..."
        set -l tmp_free (df --output=avail /tmp | tail -n 1 | string trim)
        if test (math "$tmp_free * 1024") -lt $src_size
            echo "Error: Not enough free space in /tmp for temporary image."
            return 1
        end

        echo "Creating temporary filesystem image..."
        set -l tmp_image /tmp/rpiclone-rootfs.img
        mkdir -p /tmp/rpiclone-staging
        mount /dev/${src}2 /tmp/rpiclone-staging -o ro

        set -l root_used (du -s --block-size=1 /tmp/rpiclone-staging | awk '{print $1}')
        set -l root_target (math "$root_used + (1024 * 1024 * 512)") # Add 512MB buffer

        echo "Building ext4 filesystem image ($root_target bytes)..."
        truncate -s $root_target $tmp_image
        mkfs.ext4 -F $tmp_image

        echo "Copying files to temp image..."
        set -l loopdev (losetup --find --show $tmp_image)
        mkdir -p /tmp/rpiclone-tmpmnt
        mount $loopdev /tmp/rpiclone-tmpmnt
        rsync -aAXH /tmp/rpiclone-staging/ /tmp/rpiclone-tmpmnt/

        umount /tmp/rpiclone-staging
        umount /tmp/rpiclone-tmpmnt
        losetup -d $loopdev

        echo "Shrinking ready. Proceeding with destination wipe."
    end

    # Zap destination disk
    echo "Wiping destination disk..."
    if type -q sgdisk
        sgdisk --zap-all /dev/$dst
    else
        wipefs -a /dev/$dst
    end

    # Clone boot partition
    echo "Cloning boot partition..."
    partclone.vfat -s /dev/${src}1 -o /dev/${dst}1

    # Clone root partition
    if test -e /tmp/rpiclone-rootfs.img
        echo "Writing temporary shrunken root filesystem to destination..."
        dd if=/tmp/rpiclone-rootfs.img of=/dev/${dst}2 bs=4M status=progress conv=fsync
    else
        echo "Cloning root partition normally..."
        partclone.ext4 -s /dev/${src}2 -o /dev/${dst}2
    end

    # Expand partition
    echo "Expanding root partition to fill destination disk..."
    parted /dev/$dst resizepart 2 100% --script
    partprobe /dev/$dst
    sleep 2

    echo "Resizing ext4 filesystem on root partition..."
    resize2fs /dev/${dst}2

    # Cleanup
    rm -f /tmp/rpiclone-rootfs.img
    rm -rf /tmp/rpiclone-staging /tmp/rpiclone-tmpmnt

    echo "Clone and resize complete."
end
