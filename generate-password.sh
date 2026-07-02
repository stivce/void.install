#!/usr/bin/env bash
#
# generate-password.sh — prompt for a password, hash it, write it into
# void.cfg. Keeps the install script itself fully non-interactive.
#
# Usage: ./generate-password.sh root|user [path/to/void.cfg]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf '\n\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

usage() { die "Usage: $0 root|user [path/to/void.cfg]"; }

[ $# -ge 1 ] || usage
case "$1" in
  root) VAR=ROOT_PASSWORD_HASH ;;
  user) VAR=USER_PASSWORD_HASH ;;
  *) usage ;;
esac

CONF="${2:-$SCRIPT_DIR/void.cfg}"
[ -f "$CONF" ] || die "$CONF not found."

command -v openssl >/dev/null 2>&1 || die "openssl is required to hash the password."

read -rsp "Password for $1: " pass1
echo
read -rsp "Confirm password: " pass2
echo

[ -n "$pass1" ] || die "Password cannot be empty."
[ "$pass1" = "$pass2" ] || die "Passwords did not match."

# -stdin keeps the plaintext out of ps-visible argv
hash=$(openssl passwd -6 -stdin <<<"$pass1")
unset pass1 pass2

[[ "$hash" =~ ^\$[0-9A-Za-z]+\$[^$]+\$.+$ ]] || die "openssl produced an unexpected hash format: $hash"

tmp=$(mktemp)
if grep -q "^${VAR}=" "$CONF"; then
  awk -v var="$VAR" -v val="$VAR='$hash'" 'index($0, var "=") == 1 { print val; next } { print }' "$CONF" >"$tmp"
else
  cp "$CONF" "$tmp"
  printf "%s='%s'\n" "$VAR" "$hash" >>"$tmp"
fi
mv "$tmp" "$CONF"

echo "Set $VAR in $CONF"
