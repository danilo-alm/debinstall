# debinstall.sh

The default Debian installer doesn't allow you to use BTRFS and LUKS Disk Encryption together; this installer covers that. It's set up as I like to use it, so you'll have to tweak it if you need anything more.

# How to use it

The script depends on `debootstrap` and arch-specific utilities such as `arch-chroot` and `genfstab`. Before running it, install `debootstrap` through your package manager and if you aren't on arch, install `arch-install-scripts`. The script was tested using [Arch Linux's ISO](https://archlinux.org/download/) on a virtual machine.

First, download the script:
```sh
curl -O https://raw.githubusercontent.com/danilo-alm/debinstall/main/debinstall.sh
```

You're supposed to edit it before running it; choosing your desired device, username, password, etc.

After making the desired changes, give it execution permission and run it:
```sh
chmod +x ./debinstall.sh
./debinstall.sh
```

# What it does

## Partitioning

It will create three partitions in the device:

Mount     | Size
----------|------------
/boot/efi | 500MiB
/boot     | 1GiB
/         | Available space

## Subvolumes

Subvolume   | Mountpoint
------------|-------------
@           | /
@home       | /home
@var        | /var
@log        | /var/log
@.snapshots | /.snapshots
@docker     | /var/lib/docker
@mysql      | /var/lib/mysql
@pgsql      | /var/lib/pgsql

## Repositories

Only the default repository will be added to `/etc/apt/sources.list`. You should add the security and updates repo as well if you're on stable.

## Aditional info

- Non-free software will be enabled in setup_mirrors() and non-free firmware will be installed in instal_firmware();
- Bootloader: GRUB (UEFI);
- Shell: zsh.
- Add the branch-updates and branch-security repos if on stable

If you're not using ethernet, you might want to install [Network Manager](https://wiki.archlinux.org/title/NetworkManager) so you can use your WiFi after reboot.

For more details about the installation, check [this guide](https://gist.github.com/meeas/b574e4bede396783b1898c90afa20a30) or the [Arch Wiki](https://wiki.archlinux.org/) pages on a specific topic (e.g. [Swap](https://wiki.archlinux.org/title/swap)).
