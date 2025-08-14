sudo ip6tables -F
sudo ip6tables -X
sudo ip6tables -P INPUT DROP
sudo ip6tables -P FORWARD DROP
sudo ip6tables -P OUTPUT ACCEPT

sudo iptables -F 
sudo iptables -t nat -F 
sudo iptables -X
sudo iptables -P INPUT DROP
sudo iptables -P FORWARD DROP
sudo iptables -P OUTPUT ACCEPT

# Accept on localhost
sudo ip6tables -A INPUT -i lo -j ACCEPT
sudo iptables -A INPUT -i lo -j ACCEPT

# Allow established sessions to receive traffic
sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# TODO: drop output if not 443, 80, 53 

# docker
#sudo iptables -N DOCKER-USER
#sudo iptables -I DOCKER-USER -i docker0 -j DROP
#sudo iptables -I DOCKER-USER -i docker0 -d 172.16.0.0/12 -p all -j ACCEPT 

###### persistence ######
# iptables-save -f /etc/iptables/iptables.rules
# systemctl enable iptables
# ip6tables-save -f /etc/iptables/ip6tables.rules
# systemctl enable ip6tables


###### gateway setup ######

function set_gateway() {
    deviceAddr="$1"
    sudo sysctl -w net.ipv4.ip_forward=1
    
    sudo arptables-nft -A INPUT -s $deviceAddr -j ACCEPT
    ## allow dns server
    sudo iptables -A INPUT -p udp --source $deviceAddr --dport 53 -j ACCEPT
    ## redirect to http proxy
    sudo iptables -t nat -A PREROUTING -p tcp --source $deviceAddr -j REDIRECT --to-ports 8084
    # or: -j DNAT --to interfaceAddr:8084
    sudo iptables -A INPUT -p tcp --source $deviceAddr --dport 8084  -j ACCEPT

    ## internet without prerouting
    sudo iptables -A FORWARD -p tcp --source $deviceAddr -j ACCEPT
    sudo iptables -A FORWARD -p tcp --destination $deviceAddr -j ACCEPT
    sudo iptables -t nat -A POSTROUTING -p tcp --source $deviceAddr -j MASQUERADE
}

function forward_interface() {
    targetIP=$1
    srcInterface=$2
    dstInterface=$3
    mark="111"
    table="11"
    ## marking target packages
    sudo iptables -t mangle -A PREROUTING -i $srcInterface -s $targetIP -j MARK --set-mark $mark
    ## setting table
    sudo ip route add default dev $dstInterface table $table
    sudo ip rule add fwmark $mark table $table
    sudo ip route flush cache
    ## adding the original destination ip address to response packages
    sudo iptables -t nat -A POSTROUTING -o $dstInterface -j MASQUERADE
}

###### arptables ######
sudo arptables-nft -F
sudo arptables-nft -P INPUT DROP
sudo arptables-nft -A INPUT -s 192.168.X.0/24 -j ACCEPT
sudo arptables-nft -A INPUT --opcode Reply -j ACCEPT
sudo arptables-nft -A INPUT -i docker0 -j ACCEPT
