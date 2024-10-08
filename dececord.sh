#!/bin/sh

wget -O /etc/config/firewall https://raw.githubusercontent.com/stesh0ff/OWRT/refs/heads/main/dis
/etc/init.d/firewall restart

echo "Deceda - magic, no less"
