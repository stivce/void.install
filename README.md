# void.install

Minimal unattended-ish installer for Void Linux (glibc, UEFI only).

## What it does

- Wipes and partitions the disk you pick: GPT, 254MiB ESP (boot) +
  8GiB swap partition + ext4 root (rest of the disk)
- Installs `base-system` via xbps, plus `sudo`, `python3` (so Ansible can
  manage the box afterward), `openssh`, `fastfetch`, and `git`
- Sets hostname, timezone, keymap, locale (en_US.UTF-8)
- Creates root and one regular user (wheel + sudo) from pre-hashed passwords
- Installs and configures GRUB (UEFI)
- Enables (symlinks into `/etc/runit/runsvdir/default`) `dhcpcd` and
  `sshd` so both start automatically on first boot

No desktop environment, no encryption, no LVM. Console-only base system —
add whatever else you want after first boot.

## Files

- `install` — the installer; run this on the live ISO
- `chroot-setup.sh` — the part that runs inside the target system via
  `chroot`; must stay next to `install`, not run standalone
- `generate-password.sh` — hashes a password and writes it into `void.cfg`;
  can be run standalone ahead of time, or gets called automatically by
  `install` if `USER_PASSWORD_HASH` is missing
- `void.cfg` — the config the installer reads; edit it before running

## Requirements

- Booted from the official Void Linux **glibc** live ISO in **UEFI** mode
- Working network (`dhcpcd`, `wpa_supplicant`, or `iwctl` as needed)

## Usage

1. Boot the official Void Linux **glibc** live ISO in **UEFI** mode, then
   bring up networking:

   ```sh
   dhcpcd            # wired
   # or wpa_supplicant / iwctl for Wi-Fi
   ```

2. `git` isn't on the live image by default — install it and clone this
   repo:

   ```sh
   xbps-install -Sy git
   git clone https://github.com/stivce/void.install.git
   cd void.install
   ```

3. Edit `void.cfg` with your hostname, username, timezone and keymap.

   Passwords are the one thing you don't have to fill in ahead of time —
   if `USER_PASSWORD_HASH` is left blank, `install` will prompt for it
   itself (via `generate-password.sh`) and write it back into `void.cfg`
   before continuing. Everything else below is optional convenience for
   setting it up ahead of time. Since `void.cfg` is tracked in git,
   avoid committing real password hashes — let the prompt handle them.

   Generate password hashes with `openssl` directly:

   ```sh
   openssl passwd -6 'your-password-here'
   ```

   or use the helper, which prompts for the password and writes the hash
   straight into the right line of `void.cfg`:

   ```sh
   ./generate-password.sh user   # sets USER_PASSWORD_HASH
   ./generate-password.sh root   # optional, sets a separate ROOT_PASSWORD_HASH
   ```

   Example filled-in `void.cfg` (US keymap, Vienna timezone;
   locale is hardcoded to en_US.UTF-8 by the script regardless of keymap):

   ```sh
   HOSTNAME=voyd
   USERNAME=sn0w
   TIMEZONE=Europe/Vienna
   KEYMAP=us

   USER_PASSWORD_HASH='$6$7hLp2Xr4$Kq9wTb...z2'

   # ROOT_PASSWORD_HASH='$6$3kQ9mZs1$V1n8pS...j0'   # optional, defaults to USER_PASSWORD_HASH

   # Optional, defaults shown:
   # BOOT_SIZE_MB=254
   # SWAP_SIZE_MB=8192
   # MIN_ROOT_MB=4096
   ```

   Password hashes must be **single-quoted** — they contain literal `$`
   characters bash would otherwise try to expand.

4. Run the installer as root:

   ```sh
   ./install
   ```

5. Pick the target disk from the menu (uses `dialog` if present, otherwise
   falls back to a numbered prompt). CD-ROM/loop devices are excluded
   automatically, and so is any disk that currently has a mounted
   partition or active swap — which covers the live boot media itself,
   however it was booted (USB stick, ISO, etc).

6. Confirm the wipe (`y`/`N`). Everything else runs unattended.

7. When it finishes, the installer asks whether to reboot into the new
   system right away (`dialog` yes/no, or a `y`/`N` prompt without it).

## Notes

- Boot (ESP) partition defaults to 254MiB, swap to 8GiB; override by
  setting `BOOT_SIZE_MB=...` / `SWAP_SIZE_MB=...` (in MiB) in
  `void.cfg`. `SWAP_SIZE_MB=0` skips the swap partition entirely
  (root then becomes partition 2 instead of 3).
- Only supports UEFI boot and the glibc repo — the script checks for both
  and exits with a clear error if either assumption doesn't hold.
- Refuses to run if the target disk is smaller than boot + swap + a
  4096MiB minimum root (override with `MIN_ROOT_MB=...`).
- Password hashes in the config are sanity-checked against the general
  `$id$salt$hash` crypt format before anything is touched.
- `ROOT_PASSWORD_HASH` is optional and defaults to `USER_PASSWORD_HASH` —
  set it explicitly only if root should have a different password.
- Checks connectivity to the Void repo before doing anything destructive,
  so a missing network fails fast instead of partway through the install.

## Verified

- `shellcheck` clean, `bash -n` clean.
- Not yet run end-to-end against a live ISO/VM — review the script before
  trusting it against real hardware.
