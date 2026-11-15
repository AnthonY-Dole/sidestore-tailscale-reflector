#!/bin/sh
# Works around a GL.iNet firmware bug that breaks EVERY LuCI page with
# "Error / No related RPC reply".
#
# Cause
#   /etc/nginx/gl-conf.d/gl-portal.conf declares:
#       error_page 404 /handle_404;
#   and gl-portal.lua redirects that 404 to the GL home page (302).
#   LuCI probes /ubus/ on every start: the browser follows the 302, gets 200
#   (the GL home page), so LuCI concludes /ubus/ is a valid JSON-RPC endpoint,
#   caches it in sessionStorage, and sends all its calls there. HTML comes
#   back instead of JSON-RPC -> "No related RPC reply".
#   Pure firmware bug: it also hits the login page, with no session at all.
#
# Fix
#   Answer 403 on /ubus (with and without the trailing slash). LuCI then
#   gives up its preferred endpoint and uses its documented fallback
#   /cgi-bin/luci/admin/ubus, which works.
#
# Idempotent; checks nginx -t; rolls back and exits non-zero if the final
# test fails.
set -eu

CONF=/etc/nginx/gl-conf.d/zz-luci-ubus.conf

echo "===== 1. conflicting rule already present? ====="
conflict=0
for f in /etc/nginx/nginx.conf /etc/nginx/conf.d/*.conf /etc/nginx/gl-conf.d/*.conf; do
	[ -f "$f" ] || continue
	if [ "$f" = "$CONF" ]; then
		continue
	fi
	if grep -qs 'location = /ubus' "$f"; then
		echo "  already declared in $f"
		conflict=1
	fi
done
if [ "$conflict" = "1" ]; then
	echo "  another configuration already handles /ubus: nothing to do"
	exit 0
fi
echo "  none"

echo
echo "===== 2. state before the fix ====="
curl -s -o /dev/null -w "  POST /ubus/ -> HTTP %{http_code} -> %{redirect_url}\n" \
	-X POST -H 'Content-Type: application/json' \
	-d '{"jsonrpc":"2.0","id":1,"method":"list","params":null}' \
	http://127.0.0.1/ubus/

echo
echo "===== 3. writing $CONF ====="
cat > "$CONF" <<'EOF'
# GL.iNet firmware workaround (see scripts/fix-luci-rpc.sh in the
# sidestore-reflector package).
#
# Every 404 on this router is handled by /handle_404, which redirects (302)
# to the GL home page. LuCI probes /ubus/ on start: the redirect is followed,
# the GL page answers 200, so LuCI keeps /ubus/ as its JSON-RPC endpoint and
# all its requests then fail ("No related RPC reply").
#
# Answering a plain 403 forces LuCI to use its documented fallback
# (/cgi-bin/luci/admin/ubus), which works. No effect on the GL.iNet UI, which
# uses /rpc.
location = /ubus {
	return 403;
}

location = /ubus/ {
	return 403;
}
EOF
sed 's/^/  /' "$CONF"

echo
echo "===== 4. nginx syntax ====="
if ! nginx -t 2>&1 | sed 's/^/  /'; then
	echo "  FAILED: removing the file"
	rm -f "$CONF"
	exit 1
fi

echo
echo "===== 5. reload and wait until it takes effect ====="
nginx -s reload 2>&1 | sed 's/^/  /' || /etc/init.d/nginx reload 2>&1 | sed 's/^/  /'

code=000
i=0
while [ "$i" -lt 15 ]; do
	code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
		-H 'Content-Type: application/json' -d '{}' \
		http://127.0.0.1/ubus/)
	[ "$code" = "403" ] && break
	sleep 1
	i=$((i + 1))
done

echo
echo "===== 6. result ====="
echo "  POST /ubus/ -> HTTP $code  (403 expected)"

if [ "$code" = "403" ]; then
	echo
	echo "===== 7. everything else still works ====="
	curl -s -o /dev/null -w "  GL page (/)              -> HTTP %{http_code}\n" http://127.0.0.1/
	curl -s -o /dev/null -w "  LuCI ubus controller     -> HTTP %{http_code}\n" \
		-X POST -H 'Content-Type: application/json' \
		-d '{"jsonrpc":"2.0","id":1,"method":"list","params":null}' \
		http://127.0.0.1/cgi-bin/luci/admin/ubus
	curl -s -o /dev/null -w "  SideStore Reflector page -> HTTP %{http_code}\n" \
		http://127.0.0.1/luci-static/resources/view/sidestore-reflector/main.js
	echo
	echo "  OK: LuCI will use /cgi-bin/luci/admin/ubus"
	echo "  Close every open router tab and open a new one: the broken"
	echo "  endpoint is cached per tab (sessionStorage)."
else
	echo
	echo "  FAILED: rollback"
	rm -f "$CONF"
	nginx -s reload 2>/dev/null || true
	exit 1
fi
