#!/bin/bash -e

# Device where system will be installed
DEVICE='/dev/vda'

# If you have an nvme, this might be /dev/nvme0n1p
DEVICE_PARTITION_PREFIX='/dev/vda'

# LUKS passphrase for unlocking the device
DEVICE_PASSPHRASE='123'

# Options to use when mounting btrfs subvolumes
# will not be reflected in /etc/fstab unless genfstab takes care of it
BTRFS_MOUNT_OPTIONS='compress=zstd:1,noatime,'

# Device hostname
HOSTNAME='debian'

# User configuration
USERNAME='user'
USER_PASSWORD='123'
ROOT_PASSWORD='123'

# Debian branch (stable, testing, unstable or release name)
# will be used with debootstrap and /etc/apt/sources.list
DEBIAN_RELEASE='trixie'

# Where system will be mounted to be installed configured
CLEAN_MOUNT_TARGET='/mnt/'

# If you don't know what this is, don't mind changing it
DMNAME='cryptroot'

# --- Don't modify further if you don't wanna change the behaviour of the script

before_chrooting() {
    echo -e '\nChecking internet connectivity...'
    check_internet_connection

    check_required_packages

    echo -e '\n--- Partitioning drive...'
    partition_drive > /dev/null

    echo -e '\n--- Encrypting system partition...'
    encrypt_drive > /dev/null

    echo -e '\n--- Creating btrfs subvolumes...'
    create_subvolumes > /dev/null

    echo -e '\n--- Mounting system...'
    mount_system > /dev/null

    echo -e '\n--- Debootstrap will be executed! ---'
    sleep 1
    debootstrap --arch amd64 "${DEBIAN_RELEASE}" "${CLEAN_MOUNT_TARGET}"

    echo -e '\n--- Generating fstab and chrooting into the system...'
    genfstab -U "${CLEAN_MOUNT_TARGET}" >> "${CLEAN_MOUNT_TARGET}etc/fstab"

    echo -e '\n--- Entering chroot environment...'
    cp $0 "${CLEAN_MOUNT_TARGET}"
    arch-chroot "${CLEAN_MOUNT_TARGET}" /debinstall.sh chroot

    echo -e '\n--- Cleaning up and umounting system...'
    rm -f "/mnt/$0"
    umount -R "${CLEAN_MOUNT_TARGET}"

    echo -e '\n--- Base system installed! Exiting...'
}

inside_chroot() {
    echo -e '\n--- Setting up hostname...'
    setup_hostname > /dev/null

    echo -e '\n--- Updating mirrors...'
    setup_mirrors > /dev/null

    echo -e '\n--- Installing kernel and firmware...'
    install_kernel
    install_firmware

    echo -e '\n--- Setting up users...'
    setup_users > /dev/null

    echo -e '\n--- Setting up bootloader (GRUB)...'
    setup_bootloader

    echo -e '\n--- Installing bootloader (GRUB)...'
    install_bootloader

    echo -e '\n--- Installing some additional packages...'
    apt install -y usbutils locales

    echo
    read -p "--- You'll be prompted to configure timezone and locale (PRESS ENTER)" _
    su -lc "dpkg-reconfigure tzdata"
    su -lc "dpkg-reconfigure locales"
}

check_internet_connection() {
    if ! nc -zw1 google.com 443; then
        echo "internet access is needed to run this script"
        exit 1
    fi
}

check_required_packages() {
    required_packages=(
        "parted"
        "partprobe"
        "mkfs.fat"
        "mkfs.ext4"
        "mkfs.btrfs"
        "cryptsetup"
        "debootstrap"
        "genfstab"
        "arch-chroot"
    )

    not_installed=()
    for u in ${required_packages[@]}; do
        if [ ! "$(command -v $u)" ]; then
            not_installed+=("$u")
        fi
    done

    if [ "${#not_installed[@]}" -gt 0 ]; then
        echo "One or more required packages are not installed: ${not_installed[@]}"
        exit 1
    fi
}

partition_drive() {
    for partition in $(ls ${DEVICE_PARTITION_PREFIX}*); do
        if mount | grep -q "${partition}"; then
            umount "${partition}"
        fi
    done

    parted -s "${DEVICE}" \
        mklabel gpt \
        mkpart primary 1MiB 501MiB \
        set 1 esp on \
        mkpart primary 501MiB 1.5GiB \
        mkpart primary 1.5GiB 100%

    partprobe "${DEVICE}"

    mkfs.fat -I -F 32 "${DEVICE_PARTITION_PREFIX}1"
    mkfs.ext4 -F "${DEVICE_PARTITION_PREFIX}2"
    mkfs.btrfs -f "${DEVICE_PARTITION_PREFIX}3"
}

encrypt_drive() {
    echo -en "${DEVICE_PASSPHRASE}" | cryptsetup luksFormat "${DEVICE_PARTITION_PREFIX}3"
    echo -en "${DEVICE_PASSPHRASE}" | cryptsetup luksOpen "${DEVICE_PARTITION_PREFIX}3" "${DMNAME}"
    mkfs.btrfs -f "/dev/mapper/${DMNAME}"
}

create_subvolumes() {
    mount "/dev/mapper/${DMNAME}" "${CLEAN_MOUNT_TARGET}"
    btrfs subvolume create "${CLEAN_MOUNT_TARGET}@"
    btrfs subvolume create "${CLEAN_MOUNT_TARGET}@home"
    btrfs subvolume create "${CLEAN_MOUNT_TARGET}@var"
    btrfs subvolume create "${CLEAN_MOUNT_TARGET}@log"
    btrfs subvolume create "${CLEAN_MOUNT_TARGET}@.snapshots"
    btrfs subvolume create "${CLEAN_MOUNT_TARGET}@docker"
    btrfs subvolume create "${CLEAN_MOUNT_TARGET}@mysql"
    btrfs subvolume create "${CLEAN_MOUNT_TARGET}@pgsql"
    btrfs subvolume create "${CLEAN_MOUNT_TARGET}@steam"
    umount "${CLEAN_MOUNT_TARGET}"
}

mount_system() {
    mount -o "${BTRFS_MOUNT_OPTIONS}subvol=@" "/dev/mapper/${DMNAME}" "${CLEAN_MOUNT_TARGET}"
    mount --mkdir -o "${BTRFS_MOUNT_OPTIONS}subvol=@home" "/dev/mapper/${DMNAME}" "${CLEAN_MOUNT_TARGET}home"
    mount --mkdir -o "${BTRFS_MOUNT_OPTIONS}subvol=@var" "/dev/mapper/${DMNAME}" "${CLEAN_MOUNT_TARGET}var"
    mount --mkdir -o "${BTRFS_MOUNT_OPTIONS}subvol=@log" "/dev/mapper/${DMNAME}" "${CLEAN_MOUNT_TARGET}var/log"
    mount --mkdir -o "${BTRFS_MOUNT_OPTIONS}subvol=@.snapshots" "/dev/mapper/${DMNAME}" "${CLEAN_MOUNT_TARGET}.snapshots"
    mount --mkdir -o "${BTRFS_MOUNT_OPTIONS}subvol=@docker" "/dev/mapper/${DMNAME}" "${CLEAN_MOUNT_TARGET}var/lib/docker"
    mount --mkdir -o "${BTRFS_MOUNT_OPTIONS}subvol=@mysql" "/dev/mapper/${DMNAME}" "${CLEAN_MOUNT_TARGET}var/lib/mysql"
    mount --mkdir -o "${BTRFS_MOUNT_OPTIONS}subvol=@pgsql" "/dev/mapper/${DMNAME}" "${CLEAN_MOUNT_TARGET}var/lib/pgsql"
    mount --mkdir "${DEVICE_PARTITION_PREFIX}2" "${CLEAN_MOUNT_TARGET}boot"
    mount --mkdir "${DEVICE_PARTITION_PREFIX}1" "${CLEAN_MOUNT_TARGET}boot/efi"
}

setup_hostname() {
    echo "${HOSTNAME}" > /etc/hostname
    echo "127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}" >> /etc/hosts
}

setup_mirrors() {
    echo "deb https://deb.debian.org/debian ${DEBIAN_RELEASE} main contrib non-free non-free-firmware" > /etc/apt/sources.list
    apt update
}

setup_bootloader() {
    local device_basename=$(basename ${DEVICE_PARTITION_PREFIX})
    local command="find /dev/disk/by-uuid -lname \"*/${device_basename}3\" -printf %f"
    local crypt_part_uuid=$(eval $command)

    echo -e "${DMNAME}\tUUID=${crypt_part_uuid}\tnone\tluks" >> /etc/crypttab

    apt install -y efibootmgr btrfs-progs grub-efi cryptsetup-initramfs
    sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\"|&cryptdevice=UUID=${crypt_part_uuid}:${DMNAME} root=/dev/mapper/${DMNAME} |" /etc/default/grub
}

install_bootloader() {
    su -lc "grub-install --target=x86_64-efi --bootloader-id=grub_uefi"
    su -lc "grub-mkconfig -o /boot/grub/grub.cfg"
}

install_kernel() {
    apt install -y linux-image-amd64 linux-headers-amd64
}

install_firmware() {
    apt install -y firmware-iwlwifi firmware-linux firmware-realtek
}

setup_users() {
    echo -en "${ROOT_PASSWORD}\n${ROOT_PASSWORD}" | passwd

    apt install -y zsh sudo
    chsh -s "$(which zsh)"
    su -lc "useradd -m ${USERNAME} -s $(which zsh)"
    echo -en "${USER_PASSWORD}\n${USER_PASSWORD}" | passwd "${USERNAME}"
    su -lc "usermod -aG sudo,video ${USERNAME}"
}

if [ "$EUID" -ne 0 ]; then
    echo "this script must be run as root."
    exit 1
fi

if [ "$1" == "chroot" ]; then
    inside_chroot
else
    before_chrooting
fi
