function rpiclone --description 'Clones a Pi boot drive using partclone'
    set -l usage "
Usage:
  rpiclone <source device> <destination device> [--force|-f]

Examples:
  rpiclone /dev/sde /dev/sdd
  rpiclone /dev/sde /dev/sdd --force
  rpiclone /dev/sde /dev/sdd -f

Arguments:
  /dev/<device>    Full device path (e.g., /dev/sde)
  --force, -f      Skip confirmation prompt
"

    if test (count $argv) -lt 2
        echo "$usage"
        return 1
    end

    set -l src (string replace '/dev/' '' $argv[1])
    set -l dst (string replace '/dev/' '' $argv[2])
    set -l force_confirm (contains --force $argv; or contains -f $argv)

    if not test -b /dev/$src
        echo "Error: Source /dev/$src not found."
        return 1
    end

    if not test -b /dev/$dst
        echo "Error: Destination /dev/$dst not found."
        return 1
    end

    echo "Preparing to clone:"
    echo "  Source:      /dev/$src"
    echo "  Destination: /dev/$dst"

    if not set -q force_confirm
        read -P "ALL data on /dev/$dst will be erased. Proceed? (yes/no): " confirm
        if test "$confirm" != "yes"
            echo "Aborted."
            return 1
        end
    end

    # Unmount partitions just in case
    sudo umount /dev/{$src}* /dev/{$dst}* 2>/dev/null

    # Clone partition 1 (FAT32 /boot)
    if test -b /dev/{$src}1 -a -b /dev/{$dst}1
        echo "Cloning boot partition (/boot)..."
        sudo partclone.vfat -s /dev/{$src}1 -o /dev/{$dst}1
    else
        echo "Warning: Missing boot partition."
    end

    # Clone partition 2 (ext4 /root)
    if test -b /dev/{$src}2 -a -b /dev/{$dst}2
        echo "Cloning root partition (/)..."
        sudo partclone.ext4 -s /dev/{$src}2 -o /dev/{$dst}2
    else
        echo "Warning: Missing root partition."
    end

    echo "Clone complete."
end
