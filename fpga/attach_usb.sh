#!/usr/bin/env bash
# Makes the board's USB-JTAG (Digilent FTDI, 0403:6010; Basys3 and Nexys A7 use the same chip) visible in WSL.
# Used by make prog. Already visible: nothing to do. Otherwise attaches it with usbipd-win (Windows),
# which WSL can run directly. The one-time `usbipd bind` needs an administrator PowerShell, so it is not done here.
set -euo pipefail
ID=0403:6010

if lsusb | grep -qi "$ID"; then
    exit 0
fi

if ! command -v usbipd.exe >/dev/null; then
    echo "attach_usb: board not visible in WSL and usbipd.exe not found (install usbipd-win in Windows)" >&2
    exit 1
fi

echo "attach_usb: attaching $ID to WSL with usbipd"
if ! usbipd.exe attach --wsl --hardware-id "$ID"; then
    cat >&2 <<EOF
attach_usb: usbipd attach failed. If the board is plugged in, it is probably not shared yet: in an
administrator PowerShell run once per board
    usbipd list                    (find the bus id of "USB Serial Converter A, USB Serial Converter B")
    usbipd bind --busid <id>
then run make prog again.
EOF
    exit 1
fi

for _ in $(seq 20); do
    lsusb | grep -qi "$ID" && exit 0
    sleep 0.5
done
echo "attach_usb: attached, but $ID did not show up in WSL within 10 s" >&2
exit 1
