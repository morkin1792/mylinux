## install
https://wiki.archlinux.org/index.php/Dm-crypt/Encrypting_an_entire_system#Encrypted_boot_partition_(GRUB)

## post-installation
```zsh
pacman -S earlyoom
```

```zsh
# /etc/default/earlyoom
EARLYOOM_ARGS="... -m 4"
```
