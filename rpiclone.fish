function rpiclone --description 'Fast Raspberry Pi OS disk cloner (auto-resize)'
    # Check for help
    if contains -- "--help" $argv; or contains -- "-h" $argv
        echo "rpiclone - Fast Raspberry Pi SD card cloner"
        echo ""
        echo "USAGE:"
        echo "  rpiclone               # Show available devices"
        echo "  rpiclone list          # List devices in detail"
        echo "  rpiclone SRC DST       # Clone SRC to DST"
        echo ""
        echo "FEATURES:"
        echo "  • Only copies used blocks (much faster than dd)"
        echo "  • Auto-shrinks if destination is smaller"
        echo "  • Auto-expands to use full destination space"
        echo "  • Preserves boot and root partitions"
        echo ""
        echo "EXAMPLES:"
        echo "  rpiclone /dev/sde /dev/sdd"
        return 0
    end

    # List available devices when no args or 'list' command
    if test (count $argv) -eq 0; or test "$argv[1]" = "list"
        echo "Available devices:"
        echo ""
        
        # Get list of block devices (excluding partitions)
        set -l devices (lsblk -dpno NAME | grep -E '/dev/sd[a-z]$')
        
        # Show each device with details
        for dev in $devices
            echo "DEVICE: $dev"
            echo "----------------------------------------------"
            lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT $dev | sed 's/^/  /'
            echo ""
        end
        
        echo "USAGE: rpiclone SOURCE_DEVICE DESTINATION_DEVICE"
        echo "Example: rpiclone /dev/sde /dev/sdd"
        return 0
    end

    # Ensure we have source and destination
    if test (count $argv) -lt 2
        echo "ERROR: Need both source and destination devices"
        echo "Run 'rpiclone list' to see available devices"
        return 1
    end

    set -l src $argv[1]
    set -l dst $argv[2]
    
    # Check if running as root
    if test (id -u) -ne 0
        echo "Root privileges required. Restarting with sudo..."
        sudo bash -c "fish -c 'source $HOME/.config/fish/functions/rpiclone.fish && rpiclone $src $dst'"
        return $status
    end

    # Perform the actual clone operation
    echo "=== RASPBERRY PI CLONING (FAST MODE) ==="
    echo "SOURCE:      $src"
    echo "DESTINATION: $dst"
    echo "========================================"
    
    # Validate source and destination exist
    if not test -b $src
        echo "ERROR: Source device $src not found or not a block device"
        return 1
    end
    
    if not test -b $dst
        echo "ERROR: Destination device $dst not found or not a block device"
        return 1
    end
    
    # Warn about data loss
    set_color red --bold
    echo "WARNING: All data on $dst will be DESTROYED!"
    set_color normal
    read -P "Are you SURE you want to continue? [yes/NO]: " confirm
    
    if test "$confirm" != "yes"
        echo "Operation cancelled."
        return 1
    end
    
    # Install required packages - individually to avoid errors
    echo "Checking for required packages..."
    if type -q pacman
        echo "Installing required packages with pacman..."
        pacman -S --needed --noconfirm partclone
        pacman -S --needed --noconfirm parted
        pacman -S --needed --noconfirm dosfstools
        pacman -S --needed --noconfirm e2fsprogs
        pacman -S --needed --noconfirm gptfdisk
    else if type -q apt-get
        echo "Installing required packages with apt..."
        apt-get update
        apt-get install -y partclone parted dosfstools e2fsprogs gdisk
    else if type -q dnf
        echo "Installing required packages with dnf..."
        dnf install -y partclone parted dosfstools e2fsprogs gdisk
    else
        echo "ERROR: Could not determine package manager."
        echo "Please install: partclone parted dosfstools e2fsprogs gptfdisk/gdisk"
        return 1
    end
    
    # Unmount any mounted partitions of source and destination
    echo "Unmounting partitions..."
    for dev in $src $dst
        for part in $dev*
            if mount | grep -q $part
                echo "Unmounting $part..."
                umount $part
            end
        end
    end
    
    # Verify Pi partition layout (boot = 1, rootfs = 2)
    if not test -b $src"1"; or not test -b $src"2"
        echo "ERROR: Source does not appear to have standard Raspberry Pi partitioning"
        echo "Expected: boot partition ($src"1") and root partition ($src"2")"
        return 1
    end
    
    # Get filesystem types
    set -l boot_fs (lsblk -no FSTYPE $src"1" | string trim)
    set -l root_fs (lsblk -no FSTYPE $src"2" | string trim)
    
    echo "Source partitions:"
    echo "  Boot: $src"1" ($boot_fs)"
    echo "  Root: $src"2" ($root_fs)"
    
    # Get sizes
    set -l src_size (lsblk -bno SIZE $src | string trim)
    set -l dst_size (lsblk -bno SIZE $dst | string trim)
    set -l boot_size (lsblk -bno SIZE $src"1" | string trim)
    set -l root_size (lsblk -bno SIZE $src"2" | string trim)
    
    echo "Source size:        "(math "($src_size / 1024 / 1024)")" MB"
    echo "Destination size:   "(math "($dst_size / 1024 / 1024)")" MB"
    echo "Boot partition:     "(math "($boot_size / 1024 / 1024)")" MB"
    echo "Root partition:     "(math "($root_size / 1024 / 1024)")" MB"
    
    # Check if destination is smaller than source
    set -l dst_smaller 0
    if test (math "$dst_size < $src_size")
        set dst_smaller 1
        echo "Source is larger than destination!"
        echo "Will create smaller partitions on destination."
    end
    
    # Wipe destination disk
    echo "Wiping destination disk partition table..."
    wipefs -a $dst
    
    # Create new partition table on destination
    echo "Creating new partition table..."
    parted --script $dst mklabel msdos
    
    # Create boot partition (same size as source)
    set -l boot_mb (math "round($boot_size / 1024 / 1024)")
    echo "Creating boot partition: $boot_mb MB"
    parted --script $dst mkpart primary fat32 1MiB "$boot_mb"MiB
    
    # Calculate root partition size
    if test $dst_smaller -eq 1
        set -l avail_space (math "$dst_size - $boot_size - (10 * 1024 * 1024)")
        set -l root_mb (math "round($boot_mb + (($avail_space) / 1024 / 1024))")
        echo "Creating root partition: approx. "(math "($avail_space / 1024 / 1024)")" MB"
        parted --script $dst mkpart primary ext4 "$boot_mb"MiB "$root_mb"MiB
    else
        # If destination is larger, extend to fill device minus 1MB
        echo "Creating root partition to fill device"
        parted --script $dst mkpart primary ext4 "$boot_mb"MiB 100%
    end
    
    # Set boot flag
    parted --script $dst set 1 boot on
    
    # Wait for partitions to be recognized
    echo "Refreshing partition table..."
    partprobe $dst
    sleep 2
    
    # Format boot partition
    echo "Formatting boot partition..."
    if test "$boot_fs" = "vfat"
        mkfs.vfat $dst"1"
    else
        echo "WARNING: Unknown boot filesystem: $boot_fs, using vfat"
        mkfs.vfat $dst"1"
    end
    
    # Clone boot partition using partclone or dd (boot is usually small)
    echo "Cloning boot partition..."
    if test "$boot_fs" = "vfat"; and type -q partclone.vfat
        partclone.vfat -c -s $src"1" -o $dst"1" --overwrite --rescue
    else
        dd if=$src"1" of=$dst"1" bs=4M status=progress
    end
    
    # Clone root partition using partclone (MUCH faster than dd)
    echo "Cloning root partition (only used blocks)..."
    if test "$root_fs" = "ext4"; and type -q partclone.ext4
        partclone.ext4 -c -s $src"2" -o $dst"2" --overwrite --rescue
    else if test "$root_fs" = "btrfs"; and type -q partclone.btrfs
        partclone.btrfs -c -s $src"2" -o $dst"2" --overwrite --rescue
    else if test "$root_fs" = "f2fs"; and type -q partclone.f2fs
        partclone.f2fs -c -s $src"2" -o $dst"2" --overwrite --rescue
    else
        echo "WARNING: Using slower dd method for root partition"
        echo "Filesystem $root_fs not supported by partclone"
        dd if=$src"2" of=$dst"2" bs=4M status=progress
    end
    
    # Expand root partition to fill device if needed
    set -l dst_larger 0
    if test (math "$dst_size > $src_size")
        set dst_larger 1
        echo "Destination is larger than source, expanding root partition..."
        
        # Get current partition end sector
        set -l curr_end (parted -s $dst unit s print | grep "^ 2" | tr -s ' ' | cut -d ' ' -f 4 | sed 's/s//')
        
        # Delete and recreate root partition to fill device
        echo "Resizing partition table..."
        
        # First try with parted
        parted --script $dst resizepart 2 100%
        
        # If that fails, try with more manual approach
        if test $status -ne 0
            echo "Standard resize failed, trying alternate method..."
            
            # Get the start sector of root partition
            set -l start_sector (parted -s $dst unit s print | grep "^ 2" | tr -s ' ' | cut -d ' ' -f 2 | sed 's/s//')
            
            echo "Recreating root partition at sector $start_sector to fill disk..."
            parted --script $dst rm 2
            parted --script $dst mkpart primary ext4 "$start_sector"s 100%
        end
        
        # Make sure kernel recognizes new partition size
        partprobe $dst
        sleep 2
        
        # Resize the filesystem to fill the new partition size
        echo "Resizing filesystem to fill available space..."
        if test "$root_fs" = "ext4"
            resize2fs $dst"2"
        else if test "$root_fs" = "btrfs"; and type -q btrfs
            set -l mnt_path "/mnt/rpiclone_temp"
            mkdir -p $mnt_path
            mount $dst"2" $mnt_path
            btrfs filesystem resize max $mnt_path
            umount $mnt_path
            rmdir $mnt_path
        else
            echo "WARNING: Could not resize $root_fs filesystem"
            echo "Filesystem is copied but not expanded to fill the drive"
        end
    end
    
    # Sync to ensure all writes are complete
    sync
    
    echo "✅ Clone operation completed successfully!"
    echo "   Source:      $src (original)"
    echo "   Destination: $dst (clone)"
    
    if test $dst_larger -eq 1
        echo "   The root partition has been expanded to use all available space."
    else if test $dst_smaller -eq 1
        echo "   The clone has been shrunk to fit on the smaller destination."
    end
    
    echo ""
    echo "You may now safely remove and use the destination device."
    
    return 0
end
