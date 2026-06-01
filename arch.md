## installing
https://wiki.archlinux.org/index.php/Dm-crypt/Encrypting_an_entire_system#Encrypted_boot_partition_(GRUB)

## fstab
- `/etc/fstab`
```sh
/dev/sdxY /location ntfs-3g rw,auto,users,exec,nls=utf8,umask=007,gid=1002,uid=1001    0   0
/var/swapfile       none swap sw 0 0  
```

## mkinitcpio

- `/etc/mkinitcpio.conf`
```sh
FILES=(/etc/cryptsetup-keys.d/root.key)
HOOKS=(base systemd autodetect microcode modconf kms keyboard keymap sd-vconsole block plymouth sd-encrypt filesystems fsck)

```

## grub
- `/etc/default/grub`
```sh
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet splash vt.global_cursor_default=0 fbcon=nodefer"
GRUB_CMDLINE_LINUX="rd.luks.name=<UUID>=root rd.luks.key=/etc/cryptsetup-keys.d/root.key root=/dev/mapper/root"
# ...
# https://github.com/krypciak/crossgrub
GRUB_THEME="/boot/grub/themes/crossgrub/theme.txt"

```


## earlyoom
```sh
pacman -S earlyoom
systemctl enable --now earlyoom
```

- `/etc/default/earlyoom`
```zsh
EARLYOOM_ARGS="... -m 4"
```

## sysctl 
- `/etc/sysctl.d/sys.conf`
```sh
vm.swappiness=1
kernel.sysrq=1
```