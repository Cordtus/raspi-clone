function rpiclone --description 'Simple and reliable Raspberry Pi OS disk cloner with SSH fix'
    # HELP
    if contains -- "--help" $argv; or contains -- "-h" $argv
        echo "rpiclone - Simple and reliable Raspberry Pi SD card cloner"
        echo ""
        echo "USAGE:"
        echo "  rpiclone                # Show available devices"
        echo "  rpiclone list           # List devices in detail"
        echo "  rpiclone SRC DST [flags]  # Clone SRC to DST"
        echo ""
        echo "FLAGS:"
        echo "  --force, -f    Skip confirmations"
        return 0
    end

    # LIST
    if test (count $argv) -eq 0; or test "$argv[1]" = "list"
        echo "Available devices:"
        for d in (lsblk -dpno NAME | grep -E '/dev/sd[a-z]$')
            echo "  $d"
        end
        return 0
    end

    # CLONE
    if string match -q "/dev/*" $argv[1]
        set -l src $argv[1]
        set -l dst $argv[2]
        set -l flags $argv[3..-1]
        
        if test -z "$dst"
            echo "Need both source and destination"
            return 1
        end
        
        if test (id -u) -ne 0
            set -l cmd "rpiclone $src $dst"
            for f in $flags
                set cmd "$cmd $f"
            end
            echo "Restarting with sudo..."
            sudo fish -c "source $HOME/.config/fish/functions/rpiclone.fish; $cmd"
            return $status
        end
        
        set -l force 0
        for f in $flags
            switch $f
                case "-f" "--force"; set force 1
            end
        end

        echo "=== SIMPLE DIRECT CLONING WITH SSH FIX ==="
        # Check if destination exists
        if not test -b $dst
            echo "ERROR: Destination device $dst not found"
            return 1
        end
        
        # Verify source has Raspberry Pi partitions
        if not test -b $src"1"; or not test -b $src"2"
            echo "ERROR: Source doesn't have standard Raspberry Pi partitions"
            return 1
        end
        
        # Confirm data loss
        if test $force -eq 0
            set_color red --bold
            echo "WARNING: All data on $dst will be DESTROYED!"
            set_color normal
            read -P "Are you SURE you want to continue? [yes/NO]: " confirm
            if test "$confirm" != "yes"
                echo "Operation cancelled."
                return 1
            end
        end
        
        # Create unique temporary mount points
        set -l timestamp (date +%s)
        set -l src_boot "/tmp/rpi_src_boot_$timestamp"
        set -l src_root "/tmp/rpi_src_root_$timestamp"
        set -l dst_boot "/tmp/rpi_dst_boot_$timestamp"
        set -l dst_root "/tmp/rpi_dst_root_$timestamp"
        
        # Ensure any previous mounts are cleaned up
        for mp in /tmp/rpi_*
            if mount | grep $mp > /dev/null
                echo "Unmounting previous mount: $mp"
                umount $mp
            end
        end
        
        # Get partition info
        set -l src_boot_size (lsblk -bno SIZE $src"1" | string trim)
        set -l src_boot_mb (echo "$src_boot_size / 1048576" | bc)
        
        # Get root filesystem type
        set -l root_fs "ext4"
        set -l boot_fs "vfat"
        
        echo "Source boot size: $src_boot_mb MB"
        echo "Source filesystem: $root_fs"
        
        # 1. Wipe destination
        echo "Wiping $dst..."
        wipefs -a $dst
        
        # 2. Create partition table
        echo "Creating new partition table..."
        parted --script $dst mklabel msdos
        
        # 3. Create boot partition (100MB buffer)
        set -l boot_mb_size (echo "$src_boot_mb + 100" | bc)
        echo "Creating boot partition of $boot_mb_size MB..."
        parted --script $dst mkpart primary fat32 1MiB "$boot_mb_size"MiB
        
        # 4. Create root partition (fills rest of device)
        echo "Creating root partition to fill device..."
        parted --script $dst mkpart primary ext4 "$boot_mb_size"MiB 100%
        
        # 5. Set boot flag
        parted --script $dst set 1 boot on
        
        # 6. Update partition table
        partprobe $dst
        sleep 2
        
        # 7. Format partitions
        echo "Formatting partitions..."
        mkfs.vfat -n boot $dst"1"
        mkfs.ext4 -L rootfs $dst"2"
        
        # 8. Mount partitions
        echo "Creating mount points..."
        mkdir -p $src_boot $src_root $dst_boot $dst_root
        
        echo "Mounting source partitions..."
        mount $src"1" $src_boot
        mount $src"2" $src_root
        
        echo "Mounting destination partitions..."
        mount $dst"1" $dst_boot
        mount $dst"2" $dst_root
        
        # 9. Copy boot partition
        echo "Copying boot files..."
        cp -av $src_boot/* $dst_boot/
        
        # 10. Copy root partition (excluding some directories)
        echo "Copying root files (this may take a while)..."
        rsync -av --exclude={"/proc/*","/sys/*","/dev/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} $src_root/ $dst_root/
        
        # 11. Get new UUIDs
        set -l boot_uuid (blkid -s UUID -o value $dst"1")
        set -l root_uuid (blkid -s UUID -o value $dst"2")
        set -l boot_partuuid (blkid -s PARTUUID -o value $dst"1")
        set -l root_partuuid (blkid -s PARTUUID -o value $dst"2")
        
        echo "New UUIDs:"
        echo "  Boot: $boot_uuid (PARTUUID: $boot_partuuid)"
        echo "  Root: $root_uuid (PARTUUID: $root_partuuid)"
        
        # 12. Update cmdline.txt
        if test -f "$dst_boot/cmdline.txt"
            echo "Updating cmdline.txt..."
            sed -i "s|root=[^ ]*|root=PARTUUID=$root_partuuid|g" "$dst_boot/cmdline.txt"
            echo "New cmdline.txt: "(cat "$dst_boot/cmdline.txt")
        else
            echo "WARNING: cmdline.txt not found!"
            echo "Creating generic cmdline.txt..."
            echo "console=serial0,115200 console=tty1 root=PARTUUID=$root_partuuid rootfstype=ext4 fsck.repair=yes rootwait" > "$dst_boot/cmdline.txt"
        end
        
        # 13. Create new fstab file from scratch
        echo "Creating new fstab file..."
        mkdir -p "$dst_root/etc"
        echo "# /etc/fstab created by rpiclone" > "$dst_root/etc/fstab"
        echo "proc            /proc           proc    defaults          0       0" >> "$dst_root/etc/fstab"
        echo "PARTUUID=$boot_partuuid  /boot           vfat    defaults          0       2" >> "$dst_root/etc/fstab"
        echo "PARTUUID=$root_partuuid  /               ext4    defaults,noatime  0       1" >> "$dst_root/etc/fstab"
        
        echo "New fstab contents:"
        cat "$dst_root/etc/fstab"
        
        # 14. Fix SSH Configuration (CRITICAL)
        echo "Setting up SSH properly..."
        
        # 14.1 Enable SSH via boot flag
        echo "Adding ssh file to boot partition..."
        touch "$dst_boot/ssh"
        
        # 14.2 Ensure SSH is enabled in systemd
        echo "Enabling SSH service..."
        mkdir -p "$dst_root/etc/systemd/system/multi-user.target.wants"
        
        # Link the SSH service if it exists
        if test -f "$dst_root/lib/systemd/system/ssh.service"
            # Create symlink if it doesn't exist
            if not test -L "$dst_root/etc/systemd/system/multi-user.target.wants/ssh.service"
                ln -sf "/lib/systemd/system/ssh.service" "$dst_root/etc/systemd/system/multi-user.target.wants/ssh.service"
            end
        end
        
        # Also check for sshd.service (some distros use this)
        if test -f "$dst_root/lib/systemd/system/sshd.service"
            # Create symlink if it doesn't exist
            if not test -L "$dst_root/etc/systemd/system/multi-user.target.wants/sshd.service"
                ln -sf "/lib/systemd/system/sshd.service" "$dst_root/etc/systemd/system/multi-user.target.wants/sshd.service"
            end
        end
        
        # 14.3 Configure SSH to start properly
        echo "Configuring sshd_config..."
        if test -f "$dst_root/etc/ssh/sshd_config"
            # Make key additions to sshd_config
            sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/g' "$dst_root/etc/ssh/sshd_config"
            sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/g' "$dst_root/etc/ssh/sshd_config"
            sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' "$dst_root/etc/ssh/sshd_config"
        else
            echo "WARNING: sshd_config not found, creating minimal config..."
            mkdir -p "$dst_root/etc/ssh"
            echo "PermitRootLogin yes" > "$dst_root/etc/ssh/sshd_config"
            echo "PasswordAuthentication yes" >> "$dst_root/etc/ssh/sshd_config"
        end
        
        # 14.4 Remove old host keys so new ones will be generated on first boot
        echo "Removing old SSH host keys..."
        rm -f "$dst_root/etc/ssh/ssh_host_"*
        
        # 14.5 Create marker to regenerate SSH keys on first boot
        mkdir -p "$dst_root/etc/ssh/sshd_config.d"
        echo "Creating SSH key generation script..."
        echo '#!/bin/sh' > "$dst_root/etc/rc.local"
        echo 'test -f /etc/ssh/ssh_host_rsa_key || dpkg-reconfigure openssh-server' >> "$dst_root/etc/rc.local"
        echo 'exit 0' >> "$dst_root/etc/rc.local"
        chmod +x "$dst_root/etc/rc.local"
        
        # 15. Clean up
        echo "Syncing filesystems..."
        sync
        
        echo "Unmounting all partitions..."
        umount $src_boot
        umount $src_root
        umount $dst_boot
        umount $dst_root
        
        echo "Removing mount points..."
        rmdir $src_boot
        rmdir $src_root
        rmdir $dst_boot
        rmdir $dst_root
        
        echo "✅ Clone completed"
        
        return 0
    end

    # If no recognized command
    echo "Unknown command; use --help for usage information"
    return 1
end
