#!/bin/sh

#set -x

check_repo() {
    printf "\033[32;1mChecking OpenWrt repo availability...\033[0m\n"
    opkg update | grep -q "Failed to download" && printf "\033[32;1mopkg failed. Check internet or date. Command for force ntp sync: ntpd -p ptbtime1.ptb.de\033[0m\n" && exit 1
}

route_vpn () {
cat << EOF > /etc/hotplug.d/iface/30-vpnroute
#!/bin/sh

ip route add table vpn default dev awg0
EOF
}

add_mark() {
    grep -q "99 vpn" /etc/iproute2/rt_tables || echo '99 vpn' >> /etc/iproute2/rt_tables
    
    if ! uci show network | grep -q mark0x1; then
        printf "\033[32;1mConfigure mark rule\033[0m\n"
        uci add network rule
        uci set network.@rule[-1].name='mark0x1'
        uci set network.@rule[-1].mark='0x1'
        uci set network.@rule[-1].priority='100'
        uci set network.@rule[-1].lookup='vpn'
        uci commit
    fi
}

add_tunnel() {
    TUNNEL=awg
    printf "\033[32;1mConfigure Amnezia WireGuard\033[0m\n"

    install_awg_packages

    route_vpn

    CONFIG_URL="https://raw.githubusercontent.com/stesh0ff/OWRT/refs/heads/main/One/amnezia_for_awg.conf"
    CONFIG_CONTENT=$(curl -s "$CONFIG_URL")
    echo "$CONFIG_CONTENT"

    AWG_PRIVATE_KEY=$(echo "$CONFIG_CONTENT" | grep PrivateKey | cut -d '=' -f2 | tr -d ' ')
    AWG_IP=$(echo "$CONFIG_CONTENT" | grep Address | cut -d '=' -f2 | tr -d ' ')
    AWG_JC=$(echo "$CONFIG_CONTENT" | grep Jc | cut -d '=' -f2 | tr -d ' ')
    AWG_JMIN=$(echo "$CONFIG_CONTENT" | grep Jmin | cut -d '=' -f2 | tr -d ' ')
    AWG_JMAX=$(echo "$CONFIG_CONTENT" | grep Jmax | cut -d '=' -f2 | tr -d ' ')
    AWG_S1=$(echo "$CONFIG_CONTENT" | grep S1 | cut -d '=' -f2 | tr -d ' ')
    AWG_S2=$(echo "$CONFIG_CONTENT" | grep S2 | cut -d '=' -f2 | tr -d ' ')
    AWG_H1=$(echo "$CONFIG_CONTENT" | grep H1 | cut -d '=' -f2 | tr -d ' ')
    AWG_H2=$(echo "$CONFIG_CONTENT" | grep H2 | cut -d '=' -f2 | tr -d ' ')
    AWG_H3=$(echo "$CONFIG_CONTENT" | grep H3 | cut -d '=' -f2 | tr -d ' ')
    AWG_H4=$(echo "$CONFIG_CONTENT" | grep H4 | cut -d '=' -f2 | tr -d ' ')
    AWG_PUBLIC_KEY=$(echo "$CONFIG_CONTENT" | grep PublicKey | cut -d '=' -f2 | tr -d ' ')
    AWG_PRESHARED_KEY=$(echo "$CONFIG_CONTENT" | grep PresharedKey | cut -d '=' -f2 | tr -d ' ')
    AWG_ENDPOINT=$(echo "$CONFIG_CONTENT" | grep Endpoint | cut -d '=' -f2 | tr -d ' ' | cut -d ':' -f1)
    AWG_ENDPOINT_PORT=$(echo "$CONFIG_CONTENT" | grep Endpoint | cut -d '=' -f2 | tr -d ' ' | cut -d ':' -f2)
    
    uci set network.awg0=interface
    uci set network.awg0.proto='amneziawg'
    uci set network.awg0.private_key=$AWG_PRIVATE_KEY
    uci set network.awg0.listen_port='51820'
    uci set network.awg0.addresses=$AWG_IP

    uci set network.awg0.awg_jc=$AWG_JC
    uci set network.awg0.awg_jmin=$AWG_JMIN
    uci set network.awg0.awg_jmax=$AWG_JMAX
    uci set network.awg0.awg_s1=$AWG_S1
    uci set network.awg0.awg_s2=$AWG_S2
    uci set network.awg0.awg_h1=$AWG_H1
    uci set network.awg0.awg_h2=$AWG_H2
    uci set network.awg0.awg_h3=$AWG_H3
    uci set network.awg0.awg_h4=$AWG_H4

    if ! uci show network | grep -q amneziawg_awg0; then
        uci add network amneziawg_awg0
    fi

    uci set network.@amneziawg_awg0[0]=amneziawg_awg0
    uci set network.@amneziawg_awg0[0].name='awg0_client'
    uci set network.@amneziawg_awg0[0].public_key=$AWG_PUBLIC_KEY
    uci set network.@amneziawg_awg0[0].preshared_key=$AWG_PRESHARED_KEY
    uci set network.@amneziawg_awg0[0].route_allowed_ips='0'
    uci set network.@amneziawg_awg0[0].persistent_keepalive='25'
    uci set network.@amneziawg_awg0[0].endpoint_host=$AWG_ENDPOINT
    uci set network.@amneziawg_awg0[0].allowed_ips='0.0.0.0/0'
    uci set network.@amneziawg_awg0[0].endpoint_port=$AWG_ENDPOINT_PORT
    uci commit
}

dnsmasqfull() {
    if opkg list-installed | grep -q dnsmasq-full; then
        printf "\033[32;1mdnsmasq-full already installed\033[0m\n"
    else
        printf "\033[32;1mInstalled dnsmasq-full\033[0m\n"
        cd /tmp/ && opkg download dnsmasq-full
        opkg remove dnsmasq && opkg install dnsmasq-full --cache /tmp/

        [ -f /etc/config/dhcp-opkg ] && cp /etc/config/dhcp /etc/config/dhcp-old && mv /etc/config/dhcp-opkg /etc/config/dhcp
fi
}

remove_forwarding() {
    if [ ! -z "$forward_id" ]; then
        while uci -q delete firewall.@forwarding[$forward_id]; do :; done
    fi
}

add_zone() {
    TUNNEL=awg0
    if uci show firewall | grep -q "@zone.*name='$TUNNEL'"; then
        printf "\033[32;1mZone already exist\033[0m\n"
    else
        printf "\033[32;1mCreate zone\033[0m\n"

        # Delete exists zone
        zone_awg_id=$(uci show firewall | grep -E '@zone.*awg0' | awk -F '[][{}]' '{print $2}' | head -n 1)
        if [ "$zone_awg_id" == 0 ] || [ "$zone_awg_id" == 1 ]; then
            printf "\033[32;1mawg0 zone has an identifier of 0 or 1. That's not ok. Fix your firewall. lan and wan zones should have identifiers 0 and 1. \033[0m\n"
            exit 1
        fi
        if [ ! -z "$zone_awg_id" ]; then
            while uci -q delete firewall.@zone[$zone_awg_id]; do :; done
        fi

        uci add firewall zone
        uci set firewall.@zone[-1].name="$TUNNEL"
        uci set firewall.@zone[-1].network='awg0'
        uci set firewall.@zone[-1].forward='REJECT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].input='REJECT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci set firewall.@zone[-1].family='ipv4'
        uci commit firewall
    
    if uci show firewall | grep -q "@forwarding.*name='$TUNNEL-lan'"; then
        printf "\033[32;1mForwarding already configured\033[0m\n"
    else
        printf "\033[32;1mConfigured forwarding\033[0m\n"
        # Delete exists forwarding
        forward_id=$(uci show firewall | grep -E "@forwarding.*dest='awg'" | awk -F '[][{}]' '{print $2}' | head -n 1)
        remove_forwarding

        uci add firewall forwarding
        uci set firewall.@forwarding[-1]=forwarding
        uci set firewall.@forwarding[-1].name="$TUNNEL-lan"
        uci set firewall.@forwarding[-1].dest="$TUNNEL"
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].family='ipv4'
        uci commit firewall
    fi
}

# add_zone() {
#     TUNNEL=awg0
    
#     printf "\033[32;1mCreate zone\033[0m\n"

#     # Delete exists zone
#     zone_awg_id=$(uci show firewall | grep -E '@zone.*awg0' | awk -F '[][{}]' '{print $2}' | head -n 1)
#     if [ "$zone_awg_id" == 0 ] || [ "$zone_awg_id" == 1 ]; then
#         printf "\033[32;1mawg0 zone has an identifier of 0 or 1. That's not ok. Fix your firewall. lan and wan zones should have identifiers 0 and 1. \033[0m\n"
#         exit 1
#     fi
#     if [ ! -z "$zone_awg_id" ]; then
#         while uci -q delete firewall.@zone[$zone_awg_id]; do :; done
#     fi

#     uci add firewall zone
#     uci set firewall.@zone[-1].name="$TUNNEL"
#     uci set firewall.@zone[-1].network='awg0'
#     uci set firewall.@zone[-1].forward='REJECT'
#     uci set firewall.@zone[-1].output='ACCEPT'
#     uci set firewall.@zone[-1].input='REJECT'
#     uci set firewall.@zone[-1].masq='1'
#     uci set firewall.@zone[-1].mtu_fix='1'
#     uci set firewall.@zone[-1].family='ipv4'
#     uci commit firewall
    
#     if uci show firewall | grep -q "@forwarding.*name='$TUNNEL-lan'"; then
#         printf "\033[32;1mForwarding already configured\033[0m\n"
#     else
#         printf "\033[32;1mConfigured forwarding\033[0m\n"
#         # Delete exists forwarding
#         forward_id=$(uci show firewall | grep -E "@forwarding.*dest='awg'" | awk -F '[][{}]' '{print $2}' | head -n 1)
#         remove_forwarding

#         uci add firewall forwarding
#         uci set firewall.@forwarding[-1]=forwarding
#         uci set firewall.@forwarding[-1].name="$TUNNEL-lan"
#         uci set firewall.@forwarding[-1].dest="$TUNNEL"
#         uci set firewall.@forwarding[-1].src='lan'
#         uci set firewall.@forwarding[-1].family='ipv4'
#         uci commit firewall
#     fi
# }

add_set() {
    if uci show firewall | grep -q "@ipset.*name='vpn_domains'"; then
        printf "\033[32;1mSet already exist\033[0m\n"
    else
        printf "\033[32;1mCreate set\033[0m\n"
        uci add firewall ipset
        uci set firewall.@ipset[-1].name='vpn_domains'
        uci set firewall.@ipset[-1].match='dst_net'
        uci commit
    fi
    if uci show firewall | grep -q "@rule.*name='mark_domains'"; then
        printf "\033[32;1mRule for set already exist\033[0m\n"
    else
        printf "\033[32;1mCreate rule set\033[0m\n"
        uci add firewall rule
        uci set firewall.@rule[-1]=rule
        uci set firewall.@rule[-1].name='mark_domains'
        uci set firewall.@rule[-1].src='lan'
        uci set firewall.@rule[-1].dest='*'
        uci set firewall.@rule[-1].proto='all'
        uci set firewall.@rule[-1].ipset='vpn_domains'
        uci set firewall.@rule[-1].set_mark='0x1'
        uci set firewall.@rule[-1].target='MARK'
        uci set firewall.@rule[-1].family='ipv4'
        uci commit
    fi
}

add_dns_resolver() {
    DNS_RESOLVER=STUBBY
    printf "\033[32;1mConfigure Stubby\033[0m\n"

    if opkg list-installed | grep -q stubby; then
        printf "\033[32;1mStubby already installed\033[0m\n"
    else
        printf "\033[32;1mInstalled stubby\033[0m\n"
        opkg install stubby

        printf "\033[32;1mConfigure Dnsmasq for Stubby\033[0m\n"
        uci set dhcp.@dnsmasq[0].noresolv="1"
        uci -q delete dhcp.@dnsmasq[0].server
        uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#5453"
        uci add_list dhcp.@dnsmasq[0].server='/use-application-dns.net/'
        uci commit dhcp

        printf "\033[32;1mDnsmasq restart\033[0m\n"

        /etc/init.d/dnsmasq restart
    fi
}

add_packages() {
    if opkg list-installed | grep -q "curl -"; then
        printf "\033[32;1mCurl already installed\033[0m\n"
    else
        printf "\033[32;1mInstall curl\033[0m\n"
        opkg install curl
    fi

    if opkg list-installed | grep -q nano; then
        printf "\033[32;1mNano already installed\033[0m\n"
    else
        printf "\033[32;1mInstall nano\033[0m\n"
        opkg install nano
    fi
}

add_whitelist() {
    COUNTRY=russia_inside
    EOF_DOMAINS=DOMAINS=https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst

    printf "\033[32;1mCreate script /etc/init.d/getdomains\033[0m\n"

cat << EOF > /etc/init.d/getdomains
#!/bin/sh /etc/rc.common

START=99

start () {
    $EOF_DOMAINS
EOF
cat << 'EOF' >> /etc/init.d/getdomains
    count=0
    while true; do
        if curl -m 3 github.com; then
            curl -f $DOMAINS --output /tmp/dnsmasq.d/domains.lst
            break
        else
            echo "GitHub is not available. Check the internet availability [$count]"
            count=$((count+1))
        fi
    done

    if dnsmasq --conf-file=/tmp/dnsmasq.d/domains.lst --test 2>&1 | grep -q "syntax check OK"; then
        /etc/init.d/dnsmasq restart
    fi
}
EOF

    chmod +x /etc/init.d/getdomains
    /etc/init.d/getdomains enable

    if crontab -l | grep -q /etc/init.d/getdomains; then
        printf "\033[32;1mCrontab already configured\033[0m\n"
    else
        crontab -l | { cat; echo "0 */8 * * * /etc/init.d/getdomains start"; } | crontab -
        printf "\033[32;1mIgnore this error. This is normal for a new installation\033[0m\n"
        /etc/init.d/cron restart
    fi

    printf "\033[32;1mStart script\033[0m\n"

    /etc/init.d/getdomains start
}

install_awg_packages() {
    # Получение pkgarch с наибольшим приоритетом
    PKGARCH=$(opkg print-architecture | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}')

    TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
    SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
    VERSION=$(ubus call system board | jsonfilter -e '@.release.version')
    PKGPOSTFIX="_v${VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"
    BASE_URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/"

    AWG_DIR="/tmp/amneziawg"
    mkdir -p "$AWG_DIR"

    if opkg list-installed | grep -q amneziawg-tools; then
        echo "amneziawg-tools already installed"
    else
        AMNEZIAWG_TOOLS_FILENAME="amneziawg-tools${PKGPOSTFIX}"
        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${AMNEZIAWG_TOOLS_FILENAME}"
        curl -L -o "$AWG_DIR/$AMNEZIAWG_TOOLS_FILENAME" "$DOWNLOAD_URL"

        if [ $? -eq 0 ]; then
            echo "amneziawg-tools file downloaded successfully"
        else
            echo "Error downloading amneziawg-tools. Please, install amneziawg-tools manually and run the script again"
            exit 1
        fi

        opkg install "$AWG_DIR/$AMNEZIAWG_TOOLS_FILENAME"

        if [ $? -eq 0 ]; then
            echo "amneziawg-tools file downloaded successfully"
        else
            echo "Error installing amneziawg-tools. Please, install amneziawg-tools manually and run the script again"
            exit 1
        fi
    fi
    
    if opkg list-installed | grep -q kmod-amneziawg; then
        echo "kmod-amneziawg already installed"
    else
        KMOD_AMNEZIAWG_FILENAME="kmod-amneziawg${PKGPOSTFIX}"
        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${KMOD_AMNEZIAWG_FILENAME}"
        curl -L -o "$AWG_DIR/$KMOD_AMNEZIAWG_FILENAME" "$DOWNLOAD_URL"

        if [ $? -eq 0 ]; then
            echo "kmod-amneziawg file downloaded successfully"
        else
            echo "Error downloading kmod-amneziawg. Please, install kmod-amneziawg manually and run the script again"
            exit 1
        fi
        
        opkg install "$AWG_DIR/$KMOD_AMNEZIAWG_FILENAME"

        if [ $? -eq 0 ]; then
            echo "kmod-amneziawg file downloaded successfully"
        else
            echo "Error installing kmod-amneziawg. Please, install kmod-amneziawg manually and run the script again"
            exit 1
        fi
    fi
    
    if opkg list-installed | grep -q luci-app-amneziawg; then
        echo "luci-app-amneziawg already installed"
    else
        LUCI_APP_AMNEZIAWG_FILENAME="luci-app-amneziawg${PKGPOSTFIX}"
        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${LUCI_APP_AMNEZIAWG_FILENAME}"
        curl -L -o "$AWG_DIR/$LUCI_APP_AMNEZIAWG_FILENAME" "$DOWNLOAD_URL"

        if [ $? -eq 0 ]; then
            echo "luci-app-amneziawg file downloaded successfully"
        else
            echo "Error downloading luci-app-amneziawg. Please, install luci-app-amneziawg manually and run the script again"
            exit 1
        fi

        opkg install "$AWG_DIR/$LUCI_APP_AMNEZIAWG_FILENAME"

        if [ $? -eq 0 ]; then
            echo "luci-app-amneziawg file downloaded successfully"
        else
            echo "Error installing luci-app-amneziawg. Please, install luci-app-amneziawg manually and run the script again"
            exit 1
        fi
    fi

    rm -rf "$AWG_DIR"
}

# System Details
MODEL=$(cat /tmp/sysinfo/model)
source /etc/os-release
printf "\033[34;1mModel: $MODEL\033[0m\n"
printf "\033[34;1mVersion: $OPENWRT_RELEASE\033[0m\n"

VERSION_ID=$(echo $VERSION | awk -F. '{print $1}')

if [ "$VERSION_ID" -ne 23 ]; then
    printf "\033[31;1mScript only support OpenWrt 23.05\033[0m\n"
    echo "For OpenWrt 21.02 and 22.03 you can:"
    echo "1) Use ansible https://github.com/itdoginfo/domain-routing-openwrt"
    echo "2) Configure manually. Old manual: https://itdog.info/tochechnaya-marshrutizaciya-na-routere-s-openwrt-wireguard-i-dnscrypt/"
    exit 1
fi

printf "\033[31;1mAll actions performed here cannot be rolled back automatically.\033[0m\n"

check_repo

add_packages

add_tunnel

add_mark

add_zone

add_set

dnsmasqfull

add_dns_resolver

add_whitelist


printf "\033[32;1mRestart network\033[0m\n"
/etc/init.d/network restart

printf "\033[32;1mDone\033[0m\n"