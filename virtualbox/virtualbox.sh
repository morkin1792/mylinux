## making virtualbox a bit less visible
VM_NAME="mint1"

### may need to change "pcbios" to "efi" (do not use both, if this happens you will need to wipe the other)
TYPE="pcbios"

VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/$TYPE/0/Config/DmiBIOSVendor" "Dell Inc."         # sudo dmidecode -s bios-vendor
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/$TYPE/0/Config/DmiBIOSVersion" "1.8.2"            # sudo dmidecode -s bios-version
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/$TYPE/0/Config/DmiBIOSReleaseDate" "11/11/2011"   # sudo dmidecode -s bios-release-date
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/$TYPE/0/Config/DmiSystemVendor" "Dell Inc."       # sudo dmidecode -s system-manufacturer
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/$TYPE/0/Config/DmiSystemProduct" "Vostro 5000"    # sudo dmidecode -s system-product-name
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/$TYPE/0/Config/DmiSystemVersion" "Not Specified"  # sudo dmidecode -s system-version 
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/$TYPE/0/Config/DmiSystemSerial" "JXXXX00"         # sudo dmidecode -s system-serial-number
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/$TYPE/0/Config/DmiSystemFamily" "Vostro"          # sudo dmidecode -s system-family
VBoxManage modifyvm $VM_NAME --hardwareuuid 00000000-0000-0000-0000-000000000000                         # sudo dmidecode -s system-uuid
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/$TYPE/0/Config/DmiChassisVendor" "Dell Inc."      # sudo dmidecode -s chassis-manufacturer
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/$TYPE/0/Config/DmiChassisType" "10"               # sudo dmidecode -s chassis-type (convert using table 17 in page 39 from https://www.dmtf.org/sites/default/files/standards/documents/DSP0134_3.2.0.pdf)
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/$TYPE/0/Config/DmiChassisSerial" "JXXXX00"        # sudo dmidecode -s chassis-serial-number
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/$TYPE/0/Config/DmiBoardVendor" "Dell Inc."        # sudo dmidecode -s baseboard-manufacturer
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/$TYPE/0/Config/DmiBoardProduct" "0X9X50"          # sudo dmidecode -s baseboard-product-name
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/$TYPE/0/Config/DmiBoardVersion" "A03"             # sudo dmidecode -s baseboard-version
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/$TYPE/0/Config/DmiOEMVBoxVer" "Dell System"       # sudo dmidecode -s baseboard-manufacturer
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/$TYPE/0/Config/DmiOEMVBoxRev" "27[43086226431]"   # sudo dmidecode -s baseboard-version

VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/ahci/0/Config/Port0/ModelNumber" "WD SN740-512G"  # lsblk -o NAME,MODEL,SERIAL
VBoxManage setextradata $VM_NAME "VBoxInternal/Devices/ahci/0/Config/Port0/SerialNumber" "111111111111A" # lsblk -o NAME,MODEL,SERIAL (trigger error if just numbers)
# change the model and serial number from all storage devices or remove them

VBoxManage modifyvm $VM_NAME --macaddress1 2cea7f1ba96d
VBoxManage modifyvm $VM_NAME --macaddress2 2cea7f1ba96c
VBoxManage modifyvm $VM_NAME --macaddress3 2cea7f1ba96b
VBoxManage modifyvm $VM_NAME --macaddress4 2cea7f1ba96a

VBoxManage setextradata $VM_NAME "VBoxInternal/CPUM/HostCPUID/HypervisorPresent" 0
VBoxManage modifyvm $VM_NAME --paravirtprovider none
VBoxManage modifyvm $VM_NAME --nested-hw-virt off


## optional in the vm
# blaclist box modules 
sudo systemctl stop vboxadd-service
sudo systemctl disable vboxadd-service
sudo apt purge virtualbox-guest-utils virtualbox-guest-dkms
sudo rmmod vboxguest vboxsf vboxvideo
sudo rmmod vboxguest vboxsf vboxvideo

## test 1
sudo dmidecode | grep -iE 'box|virtua|oracle|vmware'
lscpu | grep Hypervisor
systemd-detect-virt
sudo virt-what
lsblk -o NAME,MODEL,SERIAL

## test 2
lspci -v | grep -i 'box|oracle|vmware'
dmesg | grep -iE 'box|virtua|oracle|kvm|vmware'
lsmod | grep -iE 'box|virtua|oracle|kvm|vmware|vmw'
