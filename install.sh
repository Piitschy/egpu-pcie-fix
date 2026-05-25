#!/bin/sh
set -eu

install -m 0755 bin/egpu-init.sh /usr/local/bin/egpu-init.sh
install -m 0644 systemd/egpu-init.service /etc/systemd/system/egpu-init.service
install -m 0644 udev/80-tb-pcie-tunnel.rules /etc/udev/rules.d/80-tb-pcie-tunnel.rules
install -m 0644 udev/90-nvidia-egpu-power.rules /etc/udev/rules.d/90-nvidia-egpu-power.rules
install -m 0644 modprobe.d/nvidia-egpu-gate.conf /etc/modprobe.d/nvidia-egpu-gate.conf

systemctl daemon-reload
udevadm control --reload
systemctl enable egpu-init.service

printf '%s\n' 'Installed. Reboot to let egpu-init.service retrain before NVIDIA binds.'
