## making virtualbox a bit less visible
VM_NAME="mint1"

### may need to adapt "pcbios" to "efi" 

function getInfo() { if [ -z $2 ]; then RES=$(sudo dmidecode) ; else RES=$(sudo dmidecode -t $2); fi; echo $RES | grep -i "$1" | head -1 | cut -d: -f2 | sed 's/.//' }

VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/pcbios/0/Config/DmiBIOSVendor" "Dell Inc."        # getInfo vendor
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/pcbios/0/Config/DmiBIOSVersion" "1.8.2"           # getInfo version
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/pcbios/0/Config/DmiSystemVendor" "Dell Inc."      # getInfo vendor
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/pcbios/0/Config/DmiSystemProduct" "Vostro 5000"   # getInfo prod
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/pcbios/0/Config/DmiSystemVersion" "Not Specified" 
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/pcbios/0/Config/DmiSystemSerial" "JXXXX00"        # getInfo 'serial num'
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/pcbios/0/Config/DmiSystemFamily" "Vostro"         # getInfo family
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/pcbios/0/Config/DmiChassisVendor" "Dell Inc."     # getInfo vendor
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/pcbios/0/Config/DmiChassisType" "10"              # getInfo Type: 3 (convert using table 17 in page 39 from https://www.dmtf.org/sites/default/files/standards/documents/DSP0134_3.2.0.pdf)
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/pcbios/0/Config/DmiChassisSerial" "JXXXX00"       # getInfo 'serial num'
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/pcbios/0/Config/DmiOEMVBoxVer" "Dell System"      # getInfo 'String 1'
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/pcbios/0/Config/DmiOEMVBoxRev" "27[43086226431]"  # getInfo 'String 2'
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/pcbios/0/Config/DmiBoardVendor" "Dell Inc."       # getInfo vendor
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/pcbios/0/Config/DmiBoardProduct" "0X9X50"         # getInfo prod 2
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/pcbios/0/Config/DmiBoardVersion" "A03"            # getInfo ver 2
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/pcbios/0/Config/DmiBIOSReleaseDate" "11/11/2011"  # getInfo date
VBoxManage modifyvm $VM_NAME --macaddress1 2cea7f1ba96d
VBoxManage modifyvm $VM_NAME --macaddress2 2cea7f1ba96c
VBoxManage modifyvm $VM_NAME --macaddress3 2cea7f1ba96b
VBoxManage modifyvm $VM_NAME --macaddress4 2cea7f1ba96a

VBoxManage modifyvm $VM_NAME --paravirtprovider none
VBoxManage modifyvm $VM_NAME --nested-hw-virt off

## optional in the vm
sudo systemctl stop vboxadd-service
sudo systemctl disable vboxadd-service
sudo apt purge virtualbox-guest-utils virtualbox-guest-dkms
sudo rmmod vboxguest vboxsf vboxvideo
sudo rmmod vboxguest vboxsf vboxvideo

## test 1
sudo dmidecode | grep -iE 'vbox|virtua|oracle|vmware'
lscpu | grep Hypervisor
sudo virt-what

## test 2
dmesg | grep -iE 'vbox|virtua|oracle|kvm|vmware'
lsmod | grep -iE 'vbox|virtua|oracle|kvm|vmware'
