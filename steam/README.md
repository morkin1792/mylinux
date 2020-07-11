# /etc/sudoers
%sudo ALL=(user) NOPASSWD:ALL

# exec in .desktop
xhost +SI:localuser:user && sudo -u user dbus-launch /usr/bin/steam-runtime %U 

# keep login
sudo chattr +i /home/user/.steam/registry.vdf 
