#!/usr/bin/env bash
#
# chroot-setup.sh — runs inside the target root via `chroot`, invoked by
# run_chroot_setup() in void-install.sh. Not meant to be run standalone;
# expects CHR_* variables to already be exported into its environment.

set -euo pipefail

echo "$CHR_HOSTNAME" > /etc/hostname
ln -sf "/usr/share/zoneinfo/$CHR_TIMEZONE" /etc/localtime

echo "en_US.UTF-8 UTF-8" >> /etc/default/libc-locales
xbps-reconfigure -f glibc-locales
echo "LANG=en_US.UTF-8" > /etc/locale.conf

sed -i "s/^KEYMAP=.*/KEYMAP=\"$CHR_KEYMAP\"/" /etc/rc.conf 2>/dev/null \
  || echo "KEYMAP=\"$CHR_KEYMAP\"" >> /etc/rc.conf

# shellcheck disable=SC2086
xbps-install -Sy $CHR_PACKAGES >/dev/null
sed -i 's/^# *%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
grep -q '^%wheel ALL=(ALL:ALL) ALL' /etc/sudoers \
  || { echo "Failed to enable wheel group in /etc/sudoers" >&2; exit 1; }

ln -sf /etc/sv/dhcpcd /etc/runit/runsvdir/default/
ln -sf /etc/sv/sshd /etc/runit/runsvdir/default/

useradd -m -G wheel -s /bin/bash "$CHR_USERNAME"
echo "root:$CHR_ROOT_HASH" | chpasswd -e
echo "$CHR_USERNAME:$CHR_USER_HASH" | chpasswd -e

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=void --recheck
grub-mkconfig -o /boot/grub/grub.cfg

xbps-reconfigure -fa
