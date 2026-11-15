#!/bin/sh
# Builds the OpenWrt .ipk archive (opkg) without the SDK:
# static binary + init script + configuration + web UI.
#
#   ./scripts/build-ipk.sh              # build the binary, then the .ipk
#   SKIP_BUILD=1 ./scripts/build-ipk.sh # reuse build/sidestore-reflector-arm64
#   ARCH=aarch64_generic VERSION=0.2.0 ./scripts/build-ipk.sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

PKG=sidestore-reflector
VERSION=${VERSION:-0.1.0}
RELEASE=${RELEASE:-1}
# Checked on the GL-BE3600: `opkg print-architecture` only accepts
# aarch64_cortex-a53_neon-vfpv4, all and noarch.
ARCH=${ARCH:-aarch64_cortex-a53_neon-vfpv4}
BIN=build/sidestore-reflector-arm64

OUT=dist
STAGE=$OUT/stage
CTRL=$OUT/control

# --- 1. binary -------------------------------------------------------------
if [ "${SKIP_BUILD:-0}" != "1" ]; then
	TOOLCHAIN=${TOOLCHAIN:-$HOME/toolchains/aarch64--musl--stable-2025.08-1}
	export PATH="$TOOLCHAIN/bin:$PATH"
	command -v aarch64-linux-gcc >/dev/null 2>&1 || {
		echo "aarch64-linux-gcc not found (export TOOLCHAIN=...)" >&2
		exit 1
	}
	make -s clean
	make -s CC=aarch64-linux-gcc
fi

[ -f "$BIN" ] || { echo "missing binary: $BIN" >&2; exit 1; }

# Safety net: refuse a binary compiled for the host (the classic mistake).
if ! file "$BIN" | grep -q 'ARM aarch64'; then
	echo "ERROR: $BIN is not an aarch64 binary ->" >&2
	file "$BIN" >&2
	exit 1
fi

# --- 2. file tree ----------------------------------------------------------
rm -rf "$OUT"
mkdir -p "$STAGE" "$CTRL"

cp -a files/. "$STAGE"/
mkdir -p "$STAGE/usr/sbin"
cp "$BIN" "$STAGE/usr/sbin/sidestore-reflector"

chmod 0755 \
	"$STAGE/usr/sbin/sidestore-reflector" \
	"$STAGE/etc/init.d/sidestore-reflector" \
	"$STAGE/usr/lib/sidestore-reflector/run.sh"
chmod 0644 "$STAGE/etc/config/sidestore-reflector"

SIZE=$(du -sk "$STAGE" | awk '{print $1}')

# --- 3. dependencies -------------------------------------------------------
DEPENDS="kmod-tun"
if [ "${WITH_LUCI:-1}" = "1" ] && [ -d "$STAGE/www/luci-static/resources/view/sidestore-reflector" ]; then
	DEPENDS="$DEPENDS, luci-base"
fi
cat > "$CTRL/control" <<EOF
Package: $PKG
Version: $VERSION-r$RELEASE
Depends: $DEPENDS
Source: https://github.com/Anthony/sidestore-reflector
SourceName: $PKG
License: MIT
Section: net
SourceDateEpoch: $(date +%s)
Architecture: $ARCH
Installed-Size: $SIZE
Description: TUN IPv4 reflector for iOS sideloading over Tailscale
 Swaps the source and destination of IPv4 packets addressed to the configured
 address and reinjects them into the TUN device. Lets the iOS device reach the
 router as a local peer through Tailscale.
EOF

echo "/etc/config/sidestore-reflector" > "$CTRL/conffiles"

cat > "$CTRL/postinst" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0

# The init script must be enabled in /etc/rc.d; the UCI option "enabled"
# then decides whether the service really starts.
/etc/init.d/sidestore-reflector enable 2>/dev/null

# /usr/share/nftables.d/... is only read when fw4 starts.
if command -v fw4 >/dev/null 2>&1; then
	fw4 reload >/dev/null 2>&1
fi

# The LuCI ACL is only read when rpcd starts.
/etc/init.d/rpcd reload >/dev/null 2>&1 || /etc/init.d/rpcd restart >/dev/null 2>&1
exit 0
EOF

cat > "$CTRL/prerm" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0

/etc/init.d/sidestore-reflector stop 2>/dev/null
/etc/init.d/sidestore-reflector disable 2>/dev/null

if command -v fw4 >/dev/null 2>&1; then
	fw4 reload >/dev/null 2>&1
fi
exit 0
EOF

chmod 0755 "$CTRL/postinst" "$CTRL/prerm"

# --- 4. assemble the .ipk --------------------------------------------------
# FORMAT=tar (default): tar.gz container holding debian-binary + control + data.
#   This is the ONLY format accepted by the GL.iNet 4.10 opkg (Slate 7): the
#   `ar` archives used by stock OpenWrt are rejected there
#   ("Malformed package file").
# FORMAT=ar: stock OpenWrt format, for a non GL.iNet firmware.
FORMAT=${FORMAT:-tar}

printf '2.0\n' > "$OUT/debian-binary"

tar -czf "$OUT/control.tar.gz" -C "$CTRL" --owner=0 --group=0 --numeric-owner ./control ./conffiles ./postinst ./prerm
tar -czf "$OUT/data.tar.gz"    -C "$STAGE" --owner=0 --group=0 --numeric-owner .

PKG_FILE=$OUT/${PKG}_${VERSION}-r${RELEASE}_${ARCH}.ipk
rm -f "$OUT"/*.ipk

case "$FORMAT" in
ar)
	( cd "$OUT" && ar rc "$(basename "$PKG_FILE")" debian-binary control.tar.gz data.tar.gz )
	;;
tar)
	( cd "$OUT" && tar -czf "$(basename "$PKG_FILE")" debian-binary control.tar.gz data.tar.gz )
	;;
*)
	echo "unknown FORMAT: $FORMAT (expected: tar or ar)" >&2
	exit 1
	;;
esac

echo
echo "OK  -> $ROOT/$PKG_FILE  ($FORMAT)"
echo "    $(du -h "$PKG_FILE" | awk '{print $1}')"
