#!/bin/sh
# Validates locally everything that ends up in the package.
set -eu

cd "$(dirname "$0")/.."

fail() {
	echo "  FAIL  $*" >&2
	exit 1
}

echo "== JSON =="
for f in files/usr/share/luci/menu.d/*.json \
         files/usr/share/rpcd/acl.d/*.json \
         files/usr/share/oui/menu.d/*.json; do
	python3 -m json.tool "$f" >/dev/null || fail "$f"
	echo "  OK    $f"
done

echo "== JavaScript =="
if command -v node >/dev/null 2>&1; then
	LUCI=files/www/luci-static/resources/view/sidestore-reflector/main.js
	TMP=$(mktemp --suffix=.js)
	{ echo '(function(){'; cat "$LUCI"; echo '})'; } > "$TMP"
	node --check "$TMP" || fail "$LUCI"
	rm -f "$TMP"
	echo "  OK    $LUCI"

	# The GL SPA runs eval() on the bundle and expects a Vue component back.
	GLVIEW=files/www/views/gl-sdk4-ui-sidestore-reflector.common.js
	node - "$GLVIEW" <<'EOF' || fail "$GLVIEW (eval contract)"
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
let went = null;
global.window = { location: { assign: (u) => { went = u; } } };
const c = eval(src);
if (typeof c !== 'object' || !c || typeof c.render !== 'function')
	process.exit(1);
if (went !== '/cgi-bin/luci/admin/services/sidestore-reflector')
	process.exit(1);
EOF
	echo "  OK    $GLVIEW"
else
	echo "  SKIP  node not installed"
fi

echo "== Shell scripts =="
for f in files/etc/init.d/sidestore-reflector \
         files/usr/lib/sidestore-reflector/run.sh \
         scripts/*.sh; do
	sh -n "$f" || fail "$f"
	echo "  OK    $f"
done

echo "== nftables include =="
grep -q 'iifname "sidestore"' \
	files/usr/share/nftables.d/chain-pre/forward/30-sidestore-reflector.nft &&
grep -q 'oifname "sidestore"' \
	files/usr/share/nftables.d/chain-pre/forward/30-sidestore-reflector.nft ||
	fail "forward rules for the sidestore interface"
echo "  OK    nft include"

echo "== Binary =="
file build/sidestore-reflector-arm64 | sed 's/^/  /'
file build/sidestore-reflector-arm64 | grep -q 'ARM aarch64' ||
	fail "build/sidestore-reflector-arm64 is not an aarch64 binary"

echo "== Package contents =="
IPK=$(ls dist/*.ipk | head -1)
[ -n "$IPK" ] || fail "no dist/*.ipk (run ./scripts/build-ipk.sh)"
tar -tzf "$IPK" | sed 's/^/  /'
tar -tzf dist/data.tar.gz | grep -v '/$' | sed 's/^/  /'

echo
echo "All checks passed."
