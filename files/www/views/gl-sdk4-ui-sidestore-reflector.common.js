/*
 * "SideStore Reflector" entry of the GL.iNet Applications menu.
 *
 * The GL SPA fetches this file and runs eval() on it, using the value of the
 * last expression as the Vue component. Take advantage of that to redirect to
 * the LuCI configuration page, which stays the single place to configure the
 * service.
 *
 * If the format changes in a future firmware release, delete this file and
 * /usr/share/oui/menu.d/sidestore-reflector.json: the LuCI page remains
 * reachable at its direct URL.
 */
(function () {
	var target = '/cgi-bin/luci/admin/services/sidestore-reflector';

	try {
		window.location.assign(target);
	}
	catch (e) {
		/* navigation failed: the component below offers a link */
	}

	return {
		name: 'SideStoreReflectorEntry',
		render: function (h) {
			return h('div', { style: 'padding:48px;text-align:center' }, [
				h('p', {}, 'Opening SideStore Reflector settings...'),
				h('p', {}, [
					h('a', { attrs: { href: target } }, 'Open the settings page')
				])
			]);
		}
	};
})()
