#!/bin/bash
#Kvm network card, disk, memory, cpu management.
#The implementation of each module of the script, there will be a comment on its function on the code.
#nong-v 2019-03-14

#Disk management function.
#Disks can be see,added and removed, and the added disk local can be customized.
disk(){
[ $1 -eq 3 ] &&  virsh domblklist $name && exit 
qemu-img create -f qcow2 $name_disk $size
cat >/tmp/disk.xml<<-EOF
<disk type='file' device='disk'>
    <driver name='qemu' type='qcow2'/> 
    <source file='$name_disk'/> 
    <target dev='$disk' bus='virtio'/>
</disk>
EOF
if [ $1 -eq 1 ];then
	virsh attach-device $name /tmp/disk.xml --persistent ||rm -rf /tmp/disk.xml
elif [ $1 -eq 2 ];then
	echo -e "You are currently preparing to delete the $disk disk device for the host named $name！...
	\033[31mPlease be cautious！！！\033[0m"
	read -p "Are you sure you want to delete?(yes/no) : " choese
	case $choese in
		yes)
		virsh detach-device $name /tmp/disk.xml --persistent && rm -rf /tmp/disk.xml ||exit
		read -p "Do you want to delete the disk file?(yes/no) " yes
		[[ "$yes" == "yes" ]] && rm -rf $name_disk
		;;
	esac
fi
}

#Network management function
#You can add and remove NICs. The type of custom NIC is network or bridge. The default is network mode.
network(){
cat >/tmp/network.xml<<-EOF
<interface type='network'>
    <mac address='$mac' />
    <source network='default' />
    <model type='virtio' />
</interface>
EOF
[ -n "$mode" ] && sed -i "1,3s/network/$mode/g;s/default/$card/g" /tmp/network.xml
if [ $1 -eq 1 ];then
	virsh attach-device $name /tmp/network.xml --persistent && rm -rf /tmp/network.xml
elif [ $1 -eq 2 ];then
	echo -e "You are currently preparing to delete the mac address of the host named $name as $net NIC device!...
	\033[31mPlease be cautious！！！\033[0m"
	read -p "Are you sure you want to delete?(yes/no) : " choese
	case $choese in
		yes)
		awk "NR>$min_net && NR<$max_net" /etc/libvirt/qemu/$name.xml>/tmp/network.xml
		virsh detach-device $name /tmp/network.xml --persistent
		rm -rf /tmp/network.xml ;;
	esac
fi
}

#CPU management function
#Add and reduce the number of CPUs, the maximum can not exceed the number of CPUs of the physical machine,it is not recommended to reduce after adding
cpu(){
grep -w "auto" /etc/libvirt/qemu/$name.xml &>/dev/null
	if [ $? -eq 0 ];then
		echo -e "This operation requires restarting the KVM virtual machine. 
	If other machines are running,\033[31m please be cautious!!!\033[0m"
		read -p "Are you sure you want to delete?(yes/no) : " choese
		[[ "$choese" != "yes" ]] && exit
		sed -i "/vcpu/c\<vcpu placement='auto' current=\"1\"\>$CPU\</vcpu\>" /etc/libvirt/qemu/$name.xml
		systemctl restart libvirtd
	fi
	virsh setvcpus $name $size --live
}

#Memroy management function
#Memory is divided into current memory usage and maximum memory that can be increased.
#You can increase the amount of memory used, the maximum can not exceed the memory of the physical machine,
#It is not recommended to reduce after adding.
memroy(){
mem=$(echo "1024*$(echo $size|cut -d"M" -f1)"|bc)
	if [ -n $max_mem ];then
		echo -e "This operation requires restarting the KVM virtual machine. 
	If other machines are running,\033[31m please be cautious!!!\033[0m"
		read -p "Are you sure you want to delete?(yes/no) : " choese
		[[ "$choese" != "yes" ]] && exit
		 sed -i "/memory/s/$max_name/$max_mem/g" /etc/libvirt/qemu/$name.xml
		 systemctl restart libvirtd
	fi
	virsh setmem $name $mem
	virsh setmem $name $mem --config && echo "The current memory of the virtual machine $name is modified to $size"
}

#Clone management to create new virtual machines
#You can create two clone types, either full or linked.
#The disk of the new cloned virtual machine can be customized.
clone(){
if [[ "$typ" == "all" ]];then
    virt-clone -o $host -n $name -f $route/$name.qcow2
elif [[ "$typ" == "link" ]];then
    qemu-img create -f qcow2 -b $host_disk $route/$name.qcow2
    virsh dumpxml $host > /etc/libvirt/qemu/$name.xml
fi
sed -i "/name/s/$host/$name/g;s#$uuid#$(uuidgen)#g;/file=/s#$host_disk#$route\/$name.qcow2#g" /etc/libvirt/qemu/$name.xml

#If the clone source has multiple network cards
sum_net=$(virsh domiflist $host|awk '/network/||/bridge/'|wc -l)
for i in `seq $sum_net`;do 
	mac=$(uuidgen|sed 's/../&:/g;s/-//g'|cut -c1-16)
	mac_host=$(virsh domiflist $host|awk '/network/||/bridge/'|awk NR==$i'{print $5}')
	sed -i "s#$mac_host#$mac#g" /etc/libvirt/qemu/$name.xml
done
[[ "$typ" == "link" ]] &&  virsh define /etc/libvirt/qemu/$name.xml
}

#Snapshot management function
#You can create, delete, view, and recover virtual machine snapshots.
snapshot(){
if [ $1 -eq 1 ];then
    virsh snapshot-create-as $host $name
elif [ $1 -eq 2 ];then
    echo -e "\033[31mYou are deleting the snapshot, Please be cautious！！！\033[0m"
    read -p "Whether to confirm the deletion？(yes/no): " choese
    if [ "$choese" == "yes" ];then
        if [ $run -eq 1 ];then
            echo "Your virtual machine is running, you cannot delete the snapshot..."
            read -p "Whether you want to shutdown the running virtual machine first and then delete the snapshot?(yes/no):     " choese1
            [ "$chose1" !== "yes" ] && exit
            virsh destroy $host
        fi
        virsh snapshot-delete $host $name
    fi
elif [ $1 -eq 3 ];then
    virsh snapshot-list $host
elif [ $1 -eq 4 ];then
    virsh snapshot-revert $host $name
fi
}

#Script help information
if [ $# -eq 0 ]||[[ "$1" == "-h" ||"$1" == "--help" ]];then
	echo -e "\t--add	 Add NICs, disks, increase memory, CPU, create clones and snapshots"
	echo -e "\t--del	 Remove NICs, disks, clones and snapshots, reduce memory"
	echo -e "\t--host=	 The original host name of the operation (domain)"
	echo -e "\t--name=	 The target host name of the operation (domain)"
	echo -e "\tclone	 Clone management command"
	echo -e "\t--type=  Create a clone type (all is a full clone/link is a linked clone)"
	echo -e "\tsnapshot Snaphost management command"
	echo -e "\t--revert Recovery snapshot"
	echo -e "\t--see    View a snapshot of a virtual machine"
	echo -e "\tnetwork  Network management command"
	echo -e "\t--net=[device-MAC]	MAC address of the deleted network card "
	echo -e "\t--mode=	 The type of network card you need to add (bridge/network) defaults to network"
	echo -e "\t--card=	 The NIC of the real machine used by the newly added NIC of the virtual machine 
	\033[33m1)If you need to delete the network card, you can enter mac_address to get the mac address of the existing network card
	2)If you choose the default network NIC, you do not need the two parameters \"--mode\" and \"--card\"\033[0m"
	echo -e "\tdisk	 Disk management command"
	echo -e "\t--disk=  Added or deleted disk name"
	echo -e "\t--route= Disk location of the newly cloned host"
	echo -e "\tCPU      cpu management command"
	echo -e "\tmemory   Memory management command"
	echo -e "\t--max=	 Maximum memory, but do not exceed the memory of the physical machine"
	echo -e "\t--size=  The size of the added disk or memory, the number of cpu"
	echo "example
	network --add --name=met --mode=bridge --card=br0
	disk --add --name=met --disk=vdd --size=10G --route=/home/nong/kvm
	CPU --name=met --size=2
	clone --host=met --name=clone --type=all --route=/data/kvm
	snapshot （--add/del） --host=met --name=met_sanp
	snapshot --see --host=met
	--del --host=met   #Delete virtual machine"
	exit
else
	name=$(echo $@|sed -n '/--name/p'|sed '/--name/s/.*name=//'|awk '{print $1}')
	host=$(echo $@|sed -n '/--host/p'|sed 's/.*host=//'|awk '{print $1}')
	net=$(echo $@|sed -n '/--net/p'|sed 's/.*net=//'|awk '{print $1}')
	mode=$(echo $@|sed -n '/--mode/p'|sed 's/.*mode=//'|awk '{print $1}')
	card=$(echo $@|sed 's/.*card=//'|awk '{print $1}')
	disk=$(echo $@|sed -n '/--disk/p'|sed 's/.*disk=//'|awk '{print $1}')
	size=$(echo $@|sed 's/.*size=//'|awk '{print $1}')
	max_mem=$(echo $@|sed -n '/--max/p'|sed 's/.*size=//'|awk '{print $1}')
	route=$(echo $@|sed -n '/--route/p'|sed 's/.*route=//'|awk '{print $1}'|sed 's/\/$//g')
	typ=$(echo $@|sed -n '/--type/p'|sed 's/.*type=//'|awk '{print $1}')
	echo $@|grep -w "mac_address" &>/dev/null && virsh domiflist $name|awk '!/MAC/{print $5}' &&exit
fi

#Set the script's global environment variable
mac=$(uuidgen|sed 's/../&:/g;s/-//g'|cut -c1-16)
CPU=$(lscpu|grep -w "CPU(s):"|awk '{print $2}')
[ -z $route ] && route=/var/lib/libvirt/images
if [[ -n $host ]];then
	uuid=$(virsh domuuid $host|awk 'NR==1')
	host_disk=$(virsh domblklist $host|awk 'NR==3{print $2}')
	virsh list --all|sed -n "/$host/p"|grep -w running && run=1 ||run=2
fi
if [[ -n $net ]];then     #Variables needed to delete a network card
	min_net=$(echo $(cat -n /etc/libvirt/qemu/$name.xml |grep $net|awk '{print $1}')-2|bc)`
	max_net=$(echo $(cat -n /etc/libvirt/qemu/$name.xml |grep $net|awk '{print $1}')+5|bc)`
fi
if [[ -n $name ]];then
	max_name=$(virsh dominfo $name|awk 'NR==7{print $2}')
	name_disk=$route/"$name"_$disk.qcow2
fi

#Control judgment of script execution
echo $@|grep -e "--add" &>/dev/null && style=1
echo $@|grep -e "--del" &>/dev/null && style=2
echo $@|grep -e "--see" &>/dev/null && style=3
echo $@|grep -e "--revert" &>/dev/null && style=4
case $1 in
	disk)
		[ $style -eq 2 ] && name_disk=$(virsh domblklist $name|awk /$disk/'{print $2}')
		disk $style ;;
	network)
		network $style;;
	CPU)
		cpu ;;
	memory)
		memory ;;
	snapshot)
		snapshot $style ;;
	clone)
		clone ;;
	"--del")
		virsh undefine $host ;;
	*)
		echo -e "\033[31mThe parameter you entered is incorrect！\033[0m" ;;
esac
