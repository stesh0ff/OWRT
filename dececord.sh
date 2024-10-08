#!/bin/sh

wget -O /etc/config/firewall https://raw.githubusercontent.com/stesh0ff/OWRT/refs/heads/main/dis
/etc/init.d/firewall restart

echo "Firewall configuration has been replaced and firewall service restarted."
