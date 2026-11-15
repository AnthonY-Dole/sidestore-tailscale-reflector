'use strict';
'require view';
'require form';
'require rpc';
'require uci';

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: [ 'name' ],
	expect: { '': {} }
});

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('sidestore-reflector'),
			callServiceList('sidestore-reflector').catch(function() { return {}; })
		]);
	},

	render: function(data) {
		var instances = (data[1] && data[1]['sidestore-reflector'] &&
			data[1]['sidestore-reflector'].instances) || {};

		var running = false;
		Object.keys(instances).forEach(function(name) {
			if (instances[name] && instances[name].running)
				running = true;
		});

		var m = new form.Map('sidestore-reflector', _('SideStore Reflector'),
			_('IPv4 reflector on a TUN interface: packets addressed to the ' +
			  'reflected address are sent back to their sender with source and ' +
			  'destination swapped. Lets SideStore refresh apps over Tailscale ' +
			  'without LocalDevVPN.'));

		var s = m.section(form.NamedSection, 'main', 'reflector');
		s.anonymous = true;

		var o = s.option(form.Flag, 'enabled', _('Enabled'),
			_('Start the reflector at boot.'));
		o.rmempty = false;
		o.default = '0';

		o = s.option(form.ListValue, 'mode', _('Mode'),
			_('"Via Tailscale": SideStore connects to the router Tailscale IP ' +
			  '(SideStore Remote Endpoint). "Direct": the device connects ' +
			  'straight to the reflected address.'));
		o.value('node', _('Via Tailscale (router IP)'));
		o.value('direct', _('Direct (reflected address)'));
		o.default = 'node';
		o.rmempty = false;

		o = s.option(form.Value, 'node_addr', _('Router Tailscale address'),
			_('"auto" detects the current address with "tailscale ip -4".'));
		o.placeholder = 'auto';
		o.datatype = 'or("auto", ip4addr)';
		o.depends('mode', 'node');
		o.rmempty = false;

		o = s.option(form.Value, 'dnat_ports', _('Redirected ports'),
			_('TCP/UDP ports forwarded to the reflector: 62078 = lockdownd, ' +
			  '49152-65535 = RSD. Use "0-65535" if the reachability test ' +
			  'fails. Empty = all ports.'));
		o.placeholder = '62078, 49152-65535';
		o.depends('mode', 'node');
		o.rmempty = true;

		o = s.option(form.Value, 'reflect_ip', _('Reflected IPv4 address'),
			_('Internal TUN address. A /32 route to it is added ' +
			  'automatically.'));
		o.datatype = 'ip4addr';
		o.placeholder = '10.7.0.1';
		o.rmempty = false;

		o = s.option(form.Value, 'uplink_iface', _('Uplink interface'),
			_('Interface the packets arrive on, usually tailscale0.'));
		o.placeholder = 'tailscale0';
		o.rmempty = false;

		o = s.option(form.Flag, 'enforce_no_snat',
			_('Disable Tailscale SNAT'),
			_('Required: with SNAT active, Tailscale rewrites the source of ' +
			  'packets before the reflector sees them, so they are sent back ' +
			  'to the router itself (red Health Check). The service runs ' +
			  '"tailscale set --snat-subnet-routes=false" when needed.'));
		o.default = '1';
		o.rmempty = false;
		o.depends('mode', 'node');

		return m.render().then(function(node) {
			var label = running ? _('Running') : _('Stopped');
			var color = running ? '#2e7d32' : '#c62828';

			var badge = E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Status')),
				E('p', {}, [
					E('strong', { 'style': 'color:' + color }, label),
					running && instances.reflector && instances.reflector.pid
						? E('span', { 'style': 'margin-left:1em;opacity:.7' },
							'(pid ' + instances.reflector.pid + ')')
						: ''
				])
			]);

			node.insertBefore(badge, node.firstChild);
			return node;
		});
	}
});
