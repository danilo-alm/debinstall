#!/bin/bash -e

DEVICE='/dev/vda'
DEVICE_PASSPHRASE='123'
DMNAME='cryptroot'

CLEAN_MOUNT_TARGET='/mnt/'
BTRFS_MOUNT_OPTIONS='compress=zstd:1,noatime,'

HOSTNAME='debian'
USERNAME='user'

ROOT_PASSWORD='123'
USER_PASSWORD='123'

DEBIAN_RELEASE='bookworm'

before_chrooting() {
    echo -e '\nChecking internet connectivity...'
    check_internet_connection

    check_required_packages

    echo -e '\n--- Partitioning drive...'
    partition_drive "${DEVICE}" > /dev/null

    echo -e '\n--- Encrypting system partition...'
    encrypt_drive "${DEVICE}" "${DEVICE_PASSPHRASE}" "${DMNAME}" > /dev/null

    echo -e '\n--- Creating btrfs subvolumes...'
    create_subvolumes "/dev/mapper/${DMNAME}" "${CLEAN_MOUNT_TARGET}" > /dev/null

    echo -e '\n--- Mounting system...'
    mount_system "${DEVICE}" "/dev/mapper/${DMNAME}" "${BTRFS_MOUNT_OPTIONS}" "${CLEAN_MOUNT_TARGET}" > /dev/null

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
    setup_hostname "${HOSTNAME}" > /dev/null

    echo -e '\n--- Updating mirrors...'
    setup_mirrors "${DEBIAN_RELEASE}" > /dev/null

    echo -e '\n--- Installing kernel and firmware...'
    install_kernel
    install_firmware

    echo -e '\n--- Setting up users...'
    setup_users "${ROOT_PASSWORD}" "${USERNAME}" "${USER_PASSWORD}" > /dev/null

    echo -e '\n--- Setting up bootloader (GRUB)...'
    setup_bootloader "${DEVICE}" "${DMNAME}"

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
    local dev="$1"; shift
    
    for partition in $(ls ${dev}*); do
        if mount | grep -q "${partition}"; then
            umount "${partition}"
        fi
    done

    # Partition 1: EFI, 500MB
    # Partition 2: Ext4, 1G
    # Partition 3: btrfs, remaining space
    parted -s "${dev}" \
        mklabel gpt \
        mkpart primary 1MiB 501MiB \
        set 1 esp on \
        mkpart primary 501MiB 1.5GiB \
        mkpart primary 1.5GiB 100%
    
    partprobe "${dev}"

    mkfs.fat -I -F 32 "${dev}1"
    mkfs.ext4 -F "${dev}2"
    mkfs.btrfs -f "${dev}3"
}

encrypt_drive() {
    local dev="$1"; shift
    local passphrase="$1"; shift
    local dmname="$1"; shift

    echo -en "${passphrase}" | cryptsetup luksFormat "${dev}3"
    echo -en "${passphrase}" | cryptsetup luksOpen "${dev}3" "$dmname"

    mkfs.btrfs -f "/dev/mapper/${dmname}"
}

create_subvolumes() {
    local mapper="$1"; shift
    local mount_target="$1"; shift

    mount "${mapper}" "${mount_target}"
    btrfs subvolume create "${mount_target}@"
    btrfs subvolume create "${mount_target}@home"
    btrfs subvolume create "${mount_target}@var"
    btrfs subvolume create "${mount_target}@log"
    umount "${mount_target}"
}

mount_system() {
    local device="$1"; shift
    local mapper="$1"; shift
    local btrfs_mount_options="$1"; shift
    local mount_target="$1"; shift

    mount -o "${btrfs_mount_options}subvol=@" "${mapper}" "${mount_target}"

    mount --mkdir -o "${btrfs_mount_options}subvol=@home" "${mapper}" "${mount_target}home"
    mount --mkdir -o "${btrfs_mount_options}subvol=@var" "${mapper}" "${mount_target}var"
    mount --mkdir -o "${btrfs_mount_options}subvol=@log" "${mapper}" "${mount_target}var/log"

    mount --mkdir "${device}2" "${mount_target}boot"
    mount --mkdir "${device}1" "${mount_target}boot/efi"
}

setup_hostname() {
    local hostname="$1"; shift

    echo "${hostname}" > /etc/hostname
    echo "127.0.1.1 ${hostname}.localdomain ${hostname}" >> /etc/hosts
}

setup_mirrors() {
    local release="$1"; shift
    echo "deb https://deb.debian.org/debian ${release} main contrib non-free non-free-firmware" > /etc/apt/sources.list
    apt update
}

setup_bootloader() {
    local device="$1"; shift
    local dmname="$1"; shift

    local device_basename=$(basename ${device})
    local command="find /dev/disk/by-uuid -lname \"*/${device_basename}3\" -printf %f"
    local crypt_part_uuid=$(eval $command)

    echo -e "cryptroot\tUUID=${crypt_part_uuid}\tnone\tluks" >> /etc/crypttab

    apt install -y efibootmgr btrfs-progs grub-efi cryptsetup-initramfs
    sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\"|&cryptdevice=UUID=${crypt_part_uuid}:${dmname} root=/dev/mapper/${dmname} |" /etc/default/grub
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
    local root_password="$1"; shift
    local username="$1"; shift
    local user_password="$1"; shift

    echo -en "${root_password}\n${root_password}" | passwd

    apt install -y zsh sudo
    chsh -s $(which zsh)
    su -lc "useradd -m ${username} -s $(which zsh)"
    echo -en "${user_password}\n${user_password}" | passwd "${username}"
    su -lc "usermod -aG sudo ${username}"
}

if [ "$EUID" -ne 0 ]; then
  echo "this script must be run as root."
  exit 1
fi

if [ "$1" == "chroot" ]
then
    inside_chroot
else
    before_chrooting
fi
