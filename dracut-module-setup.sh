#!/bin/bash

. $dracutfunctions

check() {
    [[ $debug ]] && set -x
    #kdumpctl sets this explicitly
    if [ -z "$IN_KDUMP" ] || [ ! -f /etc/kdump.conf ]
    then
        return 1
    fi
    return 0
}

depends() {
    echo "base shutdown"
    return 0
}

kdump_to_udev_name() {
    local dev="$1"

    case "$dev" in
    UUID=*)
        dev=`blkid -U "${dev#UUID=}"`
        ;;
    LABEL=*)
        dev=`blkid -L "${dev#LABEL=}"`
        ;;
    esac
    echo ${dev#/dev/}
}

kdump_is_bridge() {
     [ -d /sys/class/net/"$1"/bridge ]
}

kdump_is_bond() {
     [ -d /sys/class/net/"$1"/bonding ]
}

#$1: netdev name
#checking /etc/sysconfig/network-scripts/ifcfg-$1,
#if it use static ip echo it, or echo null
kdump_static_ip() {
    . /etc/sysconfig/network-scripts/ifcfg-$1
    if [ -n "$IPADDR" ]; then
       [ -z "$NETMASK" -a -n "$PREFIX" ] && \
           NETMASK=$(ipcalc -m $IPADDR/$PREFIX | cut -d'=' -f2)
       echo -n "${IPADDR}::${GATEWAY}:${NETMASK}::"
    fi
}

# Setup dracut to bringup a given network interface
kdump_setup_netdev() {
    local _netdev=$1
    local _static _proto

    _netmac=`ip addr show $_netdev 2>/dev/null|awk '/ether/{ print $2 }'`
    _static=$(kdump_static_ip $_netdev)
    if [ -n "$_static" ]; then
        _proto=none
    else
        _proto=dhcp
    fi

    echo " ip=${_static}$_netdev:${_proto} ifname=$_netdev:$_netmac rd.neednet=1" > ${initdir}/etc/cmdline.d/40ip.conf

    if kdump_is_bridge "$_netdev"; then
        echo " bridge=$_netdev:$(cd /sys/class/net/$_netdev/brif/; echo *)" > ${initdir}/etc/cmdline.d/41bridge.conf
    elif kdump_is_bond "$_netdev"; then
        echo " bond=$_netdev:\"$(cat /sys/class/net/$_netdev/bonding/slaves)\"" > ${initdir}/etc/cmdline.d/42bond.conf
        #TODO
        #echo "bondoptions=\"$bondoptions\"" >> /tmp/$$-bond
    else
        :
    fi
}

#Function:kdump_install_net
#$1: config values of net line in kdump.conf
kdump_install_net() {
    local _server _netdev
    local config_val="$1"

    if strstr "$config_val" "@"; then
        _server=`echo $config_val | sed 's/.*@//' | cut -d':' -f1`
        else
            _server=$(echo $config_val | sed -e 's#\(.*\):.*#\1#')
        fi

    _need_dns=`echo $_server|grep "[a-zA-Z]"`
    [ -n "$_need_dns" ] && _server=`getent hosts $_server|cut -d' ' -f1`

    _netdev=`/sbin/ip route get to $_server 2>&1`
    [ $? != 0 ] && echo "Bad kdump location: $config_val" && exit 1

    #the field in the ip output changes if we go to another subnet
    if [ -n "`echo $_netdev | grep via`" ]
    then
        # we are going to a different subnet
        _netdev=`echo $_netdev|awk '{print $5;}'|head -n 1`
    else
        # we are on the same subnet
        _netdev=`echo $_netdev|awk '{print $3}'|head -n 1`
    fi

    kdump_setup_netdev "${_netdev}"
}

#install kdump.conf and what user specifies in kdump.conf
kdump_install_conf() {
    sed -ne '/^#/!p' /etc/kdump.conf > /tmp/$$-kdump.conf

    while read config_opt config_val;
    do
        case "$config_opt" in
        ext[234]|xfs|btrfs|minix|raw)
            sed -i -e "s#$config_val#/dev/$(kdump_to_udev_name $config_val)#" /tmp/$$-kdump.conf
            ;;
        net)
            kdump_install_net "$config_val"
            ;;
        esac
    done < /etc/kdump.conf

    inst "/tmp/$$-kdump.conf" "/etc/kdump.conf"
}

kdump_iscsi_get_rec_val() {

    local result

    # The open-iscsi 742 release changed to using flat files in
    # /var/lib/iscsi.

    result=$(/sbin/iscsiadm --show -m session -r ${1} | grep "^${2} = ")
    result=${result##* = }
    echo $result
}

kdump_get_iscsi_initiator() {
    local _initiator
    local initiator_conf="/etc/iscsi/initiatorname.iscsi"

    [ -f "$initiator_conf" ] || return 1

    while read _initiator; do
        [ -z "${_initiator%%#*}" ] && continue # Skip comment lines

        case $_initiator in
            InitiatorName=*)
                initiator=${_initiator#InitiatorName=}
                echo "rd.iscsi.initiator=${initiator}"
                return 0;;
            *) ;;
        esac
    done < ${initiator_conf}

    return 1
}

# No ibft handling yet.
kdump_setup_iscsi_device() {
    local path=$1
    local tgt_name; local tgt_ipaddr;
    local username; local password; local userpwd_str;
    local username_in; local password_in; local userpwd_in_str;
    local netdev
    local idev
    local netroot_str ; local initiator_str;
    local netroot_conf="${initdir}/etc/cmdline.d/50iscsi.conf"
    local initiator_conf="/etc/iscsi/initiatorname.iscsi"

    dinfo "Found iscsi component $1"

    # Check once before getting explicit values, so we can output a decent
    # error message.

    if ! /sbin/iscsiadm -m session -r ${path} >/dev/null ; then
        derror "Unable to find iscsi record for $path"
        return 1
    fi

    tgt_name=$(kdump_iscsi_get_rec_val ${path} "node.name")
    tgt_ipaddr=$(kdump_iscsi_get_rec_val ${path} "node.conn\[0\].address")

    # get and set username and password details
    username=$(kdump_iscsi_get_rec_val ${path} "node.session.auth.username")
    [ "$username" == "<empty>" ] && username=""
    password=$(kdump_iscsi_get_rec_val ${path} "node.session.auth.password")
    [ "$password" == "<empty>" ] && password=""
    username_in=$(kdump_iscsi_get_rec_val ${path} "node.session.auth.username_in")
    [ -n "$username" ] && userpwd_str="$username:$password"

    # get and set incoming username and password details
    [ "$username_in" == "<empty>" ] && username_in=""
    password_in=$(kdump_iscsi_get_rec_val ${path} "node.session.auth.password_in")
    [ "$password_in" == "<empty>" ] && password_in=""

    [ -n "$username_in" ] && userpwd_in_str=":$username_in:$password_in"

    netdev=$(/sbin/ip route get to ${tgt_ipaddr} | \
        sed 's|.*dev \(.*\).*|\1|g' | awk '{ print $1; exit }')

    kdump_setup_netdev $netdev

    # prepare netroot= command line
    # FIXME: IPV6 addresses require explicit [] around $tgt_ipaddr
    # FIXME: Do we need to parse and set other parameters like protocol, port
    #        iscsi_iface_name, netdev_name, LUN etc.

    netroot_str="netroot=iscsi:${userpwd_str}${userpwd_in_str}@$tgt_ipaddr::::$tgt_name"

    [[ -f $netroot_conf ]] || touch $netroot_conf

    # If netroot target does not exist already, append.
    if ! grep -q $netroot_str $netroot_conf; then
         echo $netroot_str >> $netroot_conf
         dinfo "Appended $netroot_str to $netroot_conf"
    fi

    # Setup initator
    initiator_str=$(kdump_get_iscsi_initiator)
    [ $? -ne "0" ] && derror "Failed to get initiator name" && return 1

    # If initiator details do not exist already, append.
    if ! grep -q "$initiator_str" $netroot_conf; then
         echo "$initiator_str" >> $netroot_conf
         dinfo "Appended "$initiator_str" to $netroot_conf"
    fi
}

kdump_check_iscsi_targets () {
    # If our prerequisites are not met, fail anyways.
    type -P iscsistart >/dev/null || return 1

    kdump_check_setup_iscsi() (
        local _dev
        _dev=$(get_maj_min $1)

        [[ -L /sys/dev/block/$_dev ]] || return
        cd "$(readlink -f /sys/dev/block/$_dev)"
        until [[ -d sys || -d iscsi_session ]]; do
            cd ..
        done
        [[ -d iscsi_session ]] && kdump_setup_iscsi_device "$PWD"
    )

    [[ $hostonly ]] || [[ $mount_needs ]] && {
        for_each_host_dev_fs kdump_check_setup_iscsi
    }
}


install() {
    kdump_install_conf
    inst "$moddir/monitor_dd_progress" "/kdumpscripts/monitor_dd_progress"
    chmod +x ${initdir}/kdumpscripts/monitor_dd_progress
    inst "/bin/dd" "/bin/dd"
    inst "/bin/tail" "/bin/tail"
    inst "/bin/date" "/bin/date"
    inst "/bin/sync" "/bin/sync"
    inst "/bin/cut" "/bin/cut"
    inst "/sbin/makedumpfile" "/sbin/makedumpfile"
    inst_hook pre-pivot 9999 "$moddir/kdump.sh"

    # Check for all the devices and if any device is iscsi, bring up iscsi
    # target. Ideally all this should be pushed into dracut iscsi module
    # at some point of time.
    kdump_check_iscsi_targets
}