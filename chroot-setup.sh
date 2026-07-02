#!/usr/bin/env bash
#
# chroot-setup.sh — runs inside the target root via `chroot`, invoked by
# run_chroot_setup() in the install script. Not meant to be run standalone;
# expects CHR_* variables to already be exported into its environment.

set -euo pipefail

echo "$CHR_HOSTNAME" > /etc/hostname
ln -sf "/usr/share/zoneinfo/$CHR_TIMEZONE" /etc/localtime

echo "en_US.UTF-8 UTF-8" >> /etc/default/libc-locales
xbps-reconfigure -f glibc-locales
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# stock rc.conf ships KEYMAP commented out, and sed exits 0 on no-match,
# so probe for an active line first instead of relying on sed's exit code
if grep -q '^KEYMAP=' /etc/rc.conf 2>/dev/null; then
  sed -i "s/^KEYMAP=.*/KEYMAP=\"$CHR_KEYMAP\"/" /etc/rc.conf
else
  echo "KEYMAP=\"$CHR_KEYMAP\"" >> /etc/rc.conf
fi

# shellcheck disable=SC2086
xbps-install -Sy $CHR_PACKAGES >/dev/null
# a sudoers.d drop-in is immune to upstream changes in the commented-out
# wheel line's exact format, unlike sed against /etc/sudoers
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel
visudo -c >/dev/null

ln -sf /etc/sv/dhcpcd /etc/runit/runsvdir/default/
ln -sf /etc/sv/sshd /etc/runit/runsvdir/default/

useradd -m -G wheel -s /bin/bash "$CHR_USERNAME"
echo "root:$CHR_ROOT_HASH" | chpasswd -e
echo "$CHR_USERNAME:$CHR_USER_HASH" | chpasswd -e

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=void --recheck
grub-mkconfig -o /boot/grub/grub.cfg

xbps-reconfigure -fa
