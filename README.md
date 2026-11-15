# SideStore Reflector

**Refresh SideStore apps from anywhere, over Tailscale, without turning
Tailscale off.**

A tiny IPv4 reflector, packaged as an OpenWrt `.ipk`. It runs on the router you
already have, needs no computer, no container and no second VPN profile.

|  |  |
|---|---|
| **What it is** | a TUN IPv4 reflector + OpenWrt service + web page |
| **What it solves** | SideStore cannot refresh apps while Tailscale is connected |
| **Needs** | an OpenWrt 23.05+ router with Tailscale, an iPhone with SideStore |
| **Package size** | about 60 KB, one dependency (`kmod-tun`), stateless |
| **Tested on** | GL-BE3600 (Slate 7), GL.iNet 4.10.1, OpenWrt 23.05-SNAPSHOT, SideStore `idevice` 0.6.3+ |

## What problem does this solve?

SideStore installs and refreshes apps by talking to the iOS device itself,
using the same protocols as Xcode: lockdownd on port 62078 and RSD on the
49152-65535 range. To do that it needs a reachable *device endpoint*.

Inside a local network, SideStore creates a **Local VPN** on the phone that
loops back to the phone (`10.7.0.1`). That works — but iOS only allows **one
VPN at a time**. Once Tailscale is connected, Local VPN cannot be, so SideStore
loses its endpoint and refreshes fail. You end up switching VPNs back and forth:
Tailscale off to refresh, Tailscale on to reach your home network.

This project removes the trade-off: with the reflector running on the router,
**Tailscale stays connected and SideStore still has its endpoint**, from any
network, including cellular.

## What this package does

The router acts as a **mirror**: packets the iPhone sends to the router's
Tailscale IP are sent straight back to the iPhone. SideStore, which expects to
talk to a device, ends up talking to its own phone through Tailscale.

```
iPhone:P  ──►  router Tailscale IP:Q          (SideStore, Remote Endpoint mode)
              │  DNAT (nftables)               ──► 10.7.0.1:Q
              ▼
        TUN device "sidestore"
              │  the reflector swaps source and destination
              ▼
        10.7.0.1:Q ──► iPhone:P                (SNAT: source = router Tailscale IP)
```

Concretely, the package gives you:

- a **small static binary**: one C program of about 200 lines that swaps the
  source and destination of IPv4 packets, nothing else;
- an **OpenWrt service** that creates the TUN device, the `/32` route and the
  nftables NAT rules, and enforces the Tailscale setting the trick requires;
- a **web page** to enable, disable and tune everything, plus an entry in the
  GL.iNet *Applications* menu.

It does **not** proxy your traffic, does not expose your LAN, and does not
change how your router routes anything else: only the three SideStore ports,
only from the Tailscale interface, and only to the mirror address.

## Is this for you?

**Yes, if** you run SideStore on an iPhone, you already use Tailscale to reach
your home network, and your gateway is an OpenWrt or GL.iNet router.

**No, if** you only refresh at home on the same Wi-Fi as your computer (Local
VPN is enough), or your router cannot run Tailscale.

## Quick start

```sh
# 1. build (needs an aarch64 cross toolchain, see Build)
make ipk

# 2. copy to the router and install it
scp -O dist/*.ipk slate7:/tmp/
./scripts/remote.sh scripts/install-remote.sh
```

3. **Enable it in the web UI**: *Services → SideStore Reflector* →
   tick **Enabled** → **Save & Apply**
   (or `uci set sidestore-reflector.main.enabled=1 && uci commit && /etc/init.d/sidestore-reflector restart`).

4. **On the iPhone**, with Tailscale connected:
   *SideStore → Settings → Connection Config* → **Use Local VPN: OFF** →
   **Device IP** = the **router** Tailscale IP (`ssh slate7 'tailscale ip -4'`)
   → **RemotePair Port** empty → **Confirm**.
   Then *Settings → Health Check*: *Device Reachability* must be green.

5. **If the router is a GL.iNet**, also run the LuCI workaround once, otherwise
   every LuCI page shows *"No related RPC reply"* (a firmware bug, not this
   package): `./scripts/remote.sh scripts/fix-luci-rpc.sh`.

That is the whole setup. Everything below is the detail.

> `slate7` above is an SSH alias for the router. SSH is off by default on some
> firmware builds: enable it in the admin panel under **System → Advanced
> Settings**, then see
> [Before you start: SSH access](#before-you-start-ssh-access).

## Contents

- [How it works](#how-it-works)
- [What is in the package](#what-is-in-the-package)
- [Requirements](#requirements)
- [Build](#build)
- [Install](#install)
- [Configuration](#configuration)
- [Web interfaces](#web-interfaces)
- [SideStore setup (iOS)](#sidestore-setup-ios)
- [The Tailscale SNAT trap](#the-tailscale-snat-trap)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Design notes and limits](#design-notes-and-limits)
- [Field notes (GL-BE3600, firmware 4.10.1)](#field-notes-gl-be3600-firmware-4101)

## How it works

Three pieces cooperate:

1. **DNAT**: a packet from the iPhone to `<router Tailscale IP>:<port>` is
   rewritten to `10.7.0.1:<port>` and routed into the TUN device.
2. **The reflector**: the TUN device is a userspace network interface. The C
   program reads each IPv4 packet, swaps its source and destination, and writes
   it back. The packet now goes from `10.7.0.1` to the iPhone's Tailscale IP.
3. **SNAT**: on the way out, the source is rewritten to the router's Tailscale
   IP, so the iPhone sees a normal, established connection.

The iOS device ends up talking to itself, which is exactly what SideStore
exploits to install and refresh apps. This is the same approach as
[shiqi917/sidestore-vpn-tailscale](https://github.com/shiqi917/sidestore-vpn-tailscale)
and [xddxdd/sidestore-vpn](https://github.com/xddxdd/sidestore-vpn), but native:
no Docker, no container, no second `tailscaled`.

The reflector is stateless and has no notion of devices: it only swaps addresses
of packets aimed at the reflected address. Because the swap preserves the
one's-complement checksum sums (including the TCP/UDP pseudo-header), no
checksum adjustment is needed.

## What is in the package

| Path | Purpose |
|---|---|
| `/usr/sbin/sidestore-reflector` | static C binary (aarch64/musl), the IPv4 swap |
| `/etc/init.d/sidestore-reflector` | procd service (respawn, `enabled` from UCI) |
| `/usr/lib/sidestore-reflector/run.sh` | starts the binary, creates the TUN, the /32 route and the NAT table |
| `/etc/config/sidestore-reflector` | UCI configuration (kept on upgrade: `conffiles`) |
| `/usr/share/nftables.d/chain-pre/forward/30-sidestore-reflector.nft` | lets `fw4` forward through the TUN |
| `/usr/share/luci/menu.d/…`, `/usr/share/rpcd/acl.d/…`, `/www/luci-static/…` | LuCI page |
| `/usr/share/oui/menu.d/sidestore-reflector.json`, `/www/views/gl-sdk4-ui-sidestore-reflector.common.js` | GL.iNet Applications entry |

`postinst` enables the init script, reloads `fw4` (for the nftables include) and
reloads `rpcd` (for the LuCI ACL). `prerm` stops and disables the service.

## Requirements

- Router with OpenWrt 23.05 or newer and `opkg`; the architecture must accept
  `aarch64_cortex-a53_neon-vfpv4` (`opkg print-architecture`).
- `kmod-tun` (`Depends` of the package) and `nftables`/`fw4` (present on any
  firewall4 router).
- Tailscale installed and connected on the router.
- LuCI (`luci-base`) for the web page; the service works without it.
- SSH access to the router (see
  [Before you start: SSH access](#before-you-start-ssh-access)).

## Build

You need an aarch64 cross toolchain that can link statically. Any recent one
works (musl or glibc); the default path is a
[Bootlin](https://toolchains.bootlin.com/) toolchain:

```sh
export TOOLCHAIN=$HOME/toolchains/aarch64--musl--stable-2025.08-1
make ipk      # cross-compile + package -> dist/sidestore-reflector_<ver>-r<rel>_<arch>.ipk
make check    # JSON, JS, shell, nftables, binary and archive contents
```

Override the compiler with `CC=/path/to/aarch64-linux-gcc` instead of
`TOOLCHAIN` if your toolchain lives elsewhere.

| Command | Effect |
|---|---|
| `make` | cross-compile the binary into `build/` |
| `make host` | native build, to test the swap logic on a PC |
| `make ipk` | full package into `dist/` |
| `make check` | validate the sources and the built archive |
| `make clean` | remove the binaries |

`build/` and `dist/` are generated and git-ignored; a fresh clone only needs
`make ipk`.

Package variables: `VERSION`, `RELEASE`, `ARCH`, `FORMAT=tar|ar`,
`WITH_LUCI=0` (no web page), `SKIP_BUILD=1` (reuse the existing binary). They
are passed through `scripts/build-ipk.sh`, e.g.
`VERSION=0.2.0 make ipk`.

### Repository layout

| Path | Content |
|---|---|
| `src/main.c` | the reflector (about 200 lines of C, no dependency) |
| `files/` | everything installed on the router, copied as-is into the package |
| `scripts/` | build, validation, deployment and firmware workaround |
| `Makefile` | `make`, `make ipk`, `make check` |
| `README.md`, `LICENSE` | documentation, MIT license |

### Archive formats

The GL.iNet `opkg` **rejects `.ipk` files in `ar` format** (the stock OpenWrt
format) with `pkg_init_from_file: Malformed package file`. The package is
therefore produced as a `tar.gz` container (the historical ipkg format), which
also works on a regular OpenWrt. `FORMAT=ar` remains available for non-GL.iNet
firmware.

## Install

### Before you start: SSH access

Everything below is done over SSH, so it has to be enabled on the router first.

1. Open the router admin panel: `http://192.168.8.1` (GL.iNet factory address;
   it is `http://192.168.1.1` on stock OpenWrt). Log in with the admin password.
2. Go to **System → Advanced Settings**. This opens LuCI, the advanced OpenWrt
   interface.
3. In LuCI, go to **System → Administration** and check that **SSH Access** is
   enabled for the LAN interface. On most GL.iNet builds it already is; on some
   it is limited to the WAN or disabled.
4. The SSH user is `root` and the password is the same as the admin panel one.

Then, on the computer that holds the sources, connect once:

```sh
ssh root@192.168.8.1
```

Accept the host key on the first connection. On Windows, `ssh` ships with
Windows 10 and later (otherwise add *OpenSSH Client* from *Optional features*).

The rest of this README uses `slate7` as the router name. That is just a
shortcut: add this to `~/.ssh/config` (`C:\Users\<you>\.ssh\config` on Windows)
and every command below works as written:

```
Host slate7
    HostName 192.168.8.1
    User root
```

Change `HostName` if your router uses another address, or set `HOST` when
running the scripts. Password-less login (`ssh-keygen` then `ssh-copy-id`) is
optional and not used by the scripts.

### From the machine that holds the sources

```sh
scp -O dist/*.ipk slate7:/tmp/
./scripts/remote.sh scripts/install-remote.sh
```

`scp -O` is mandatory: the modern `scp` uses SFTP, which dropbear does not
provide. `scripts/remote.sh` pipes the script over SSH stdin, which avoids
PowerShell quoting problems; set `HOST` to use another host name.

`install-remote.sh` reinstalls the package, forces `enabled=1`, restarts the
service and prints the configuration, the processes, the TUN device, the nft
table, the Tailscale `NoSNAT` flag and the last log lines.

Uninstall: `opkg remove sidestore-reflector`.

## Configuration

| UCI option | Default | Purpose |
|---|---|---|
| `enabled` | `0` | start the service (1 = on) |
| `mode` | `node` | `node` = through the router Tailscale IP; `direct` = /32 route only |
| `node_addr` | `auto` | router Tailscale IP (`tailscale ip -4`) |
| `dnat_ports` | `62078, 49152-65535` | redirected ports (lockdownd + RSD) |
| `reflect_ip` | `10.7.0.1` | internal TUN address |
| `uplink_iface` | `tailscale0` | interface the packets arrive on |
| `enforce_no_snat` | `1` | turn off Tailscale `--snat-subnet-routes` (required, see below) |

The TUN interface name is hardcoded to `sidestore` because
`30-sidestore-reflector.nft` matches on it. If you change it, update that file
too.

The same settings are available through the web page, or on the command line:

```sh
uci set sidestore-reflector.main.enabled='1'
uci commit sidestore-reflector
/etc/init.d/sidestore-reflector restart
```

## Web interfaces

### LuCI page

`Services → SideStore Reflector`, or directly
`http://192.168.8.1/cgi-bin/luci/admin/services/sidestore-reflector`.

The page shows the service state (running / stopped, with the PID) and lets you
change everything without SSH: **Enabled**, mode, router address, ports,
reflected address, uplink interface, and **Disable Tailscale SNAT**.

**Save & Apply** stores the configuration and restarts the service
(`procd_add_reload_trigger`). Clearing **Enabled** and applying stops the
reflector, removes the TUN device and the NAT table, and prevents it from
starting at boot; the configuration is kept, so ticking it again is enough to
come back.

### GL.iNet Applications entry

The package also adds **Applications → SideStore Reflector** to the stock
GL.iNet UI. It redirects to the LuCI page above: the GL UI is a Vue SPA whose
pages are bundles compiled against an internal, undocumented kit that changes
with every firmware update. A plain redirect avoids that dependency.

Related files (removing both never breaks the LuCI page):

- `/usr/share/oui/menu.d/sidestore-reflector.json` — menu entry
- `/www/views/gl-sdk4-ui-sidestore-reflector.common.js` — bundle evaluated by the SPA

The SPA loads a view with
`axios.get('/views/gl-sdk4-ui-<view>.common.js').then(res => eval(res.data))`
and uses the value of the last expression as the Vue component; the bundle
returns a component that navigates to the LuCI URL. If a future firmware
changes that contract, delete both files: the LuCI page keeps working at its
direct URL.

## SideStore setup (iOS)

On the iPhone, with Tailscale **enabled and connected**:

1. SideStore → **Settings → Connection Config**
2. **Use Local VPN: OFF** → the mode becomes *Remote Endpoint*
3. **Device IP** = the **router** Tailscale IP, e.g. `100.101.102.103`
   (check with `ssh slate7 'tailscale ip -4'`)
4. **RemotePair Port**: leave empty
5. **Confirm**

Then **Settings → Health Check** → *Device Reachability* must turn green.

### Why "Remote Endpoint" and not "Local VPN"

The old SideStore hardcoded `10.7.0.1`. The new one (`idevice` architecture,
0.6.3+ / nightly) derives its target from the VPN interface: `<utun IP> + 1`.
In *Local VPN* mode the `utun` belongs to SideStore and that guess does not land
on the reflector, hence `DeviceEndpointNotInitialized`. In *Remote Endpoint*
mode the address is explicit — it is exactly `NODE_ADDR` from the reference
project — so there is no `+1` to compute and no IP to edit in the Tailscale
console. That is this package's `node` mode.

> If you really want *Local VPN*, then both `node_addr` (UCI) and the machine's
> IPv4 address in the [Tailscale console](https://login.tailscale.com/admin/machines)
> must equal `<iPhone Tailscale IP> + 1`, and that address must be free.

### Pairing: it is not a key

There is **no pairing key to type in**. SideStore consumes an **RPPairing**
file (`.mobiledevicepairing`):

- generated by **iloader** (`iloader pairing`) and imported into SideStore
  (Settings → Pairing File → *Import*), or taken from an existing pairing
  backup;
- it is bound to the device (UDID) and its certificate: regenerate it if the
  app rejects it.

### Requirements that do not depend on the router

- A recent SideStore (`idevice` architecture).
- **The iPhone must be associated with a Wi-Fi network**: iOS only opens
  lockdownd (62078) and RSD (49152+) in that case. On cellular only it is
  impossible, whatever the tool.
- If the Tailscale link is relayed (DERP), raise
  *Developer Options → Device (TCP) Probe Timeout* to 2000 ms.

### What must be true on the router

- `tailscale ip -4` returns the expected address and `tailscaled` is running;
- `--snat-subnet-routes` is **disabled** (the service does it, see below);
- the Tailscale ACL allows the peer to reach the node.

## The Tailscale SNAT trap

This is the one setting that silently breaks everything, so it is worth
understanding. Symptom observed in production on this router:

```
iPhone -> router : 100.101.102.104:59077 -> 100.101.102.103:49152 [SYN]
on the TUN       : 203.0.113.27:59180    -> 10.7.0.1:62078       [SYN]  <- source is the WAN IP!
reflection       : 10.7.0.1:59180        -> 203.0.113.27:62078   [SYN]  <- comes back to the router
reply            : 100.101.102.103:49152 -> 100.101.102.104:59077 [RST]  <- red Health Check
```

Addresses are examples: `100.101.102.103` is the router Tailscale address,
`100.101.102.104` the iPhone one, and `203.0.113.27` (RFC 5737 documentation
range) stands for the router public WAN address.

Tailscale marks packets received on `tailscale0`, and its `MASQUERADE`
(`ts-postrouting`) replaces the source with the node address **before** the
reflector sees them. The reflected packet therefore goes back to the router
instead of the iPhone, and the router answers with a RST.

The service fixes this on start:

```sh
tailscale set --snat-subnet-routes=false   # only if NoSNAT is not already true
```

Check at any time:

```sh
ssh slate7 'tailscale debug prefs | grep NoSNAT'                    # must be true
ssh slate7 'nft list table ip nat | sed -n "/ts-postrouting/,/}/p"' # empty chain
```

The setting is stored in `tailscaled.state`, so it survives a reboot. The UCI
option `enforce_no_snat` (`1` by default) only exists to disable that check if
you prefer to manage Tailscale yourself.

## Troubleshooting

Start with the two commands that answer most questions:

```sh
ssh slate7 '/etc/init.d/sidestore-reflector status'   # running?
ssh slate7 'logread | grep sidestore'                 # what did it say?
```

- **Service stopped**: check that `tailscale0` exists and `tailscale ip -4`
  answers. The service waits up to 30 s for the uplink interface, then gives up
  with `interface tailscale0 missing after 30s`.
- **Service running, Health Check still red**:
  - `nft list table ip sidestore_reflector` — the DNAT rules must be there;
  - `nft list chain inet fw4 forward | grep sidestore` — the counters must grow
    when SideStore retries;
  - widen `dnat_ports` to `0-65535`;
  - the device must be on Wi-Fi, Tailscale up, and the Tailscale ACL must allow
    the node to reach the other peers.
- **Traffic loops back to the router**: that is Tailscale SNAT (see above).
  `tailscale debug prefs | grep NoSNAT` must be `true`; if not, run
  `tailscale set --snat-subnet-routes=false`. The service does it on start
  when `enforce_no_snat` is `1`.
- **"Error / No related RPC reply" in LuCI**: firmware bug, covered below.
- **Rollback**: `uci set sidestore-reflector.main.enabled=0 && uci commit && /etc/init.d/sidestore-reflector stop`
- **Uninstall**: `opkg remove sidestore-reflector`

### "Error / No related RPC reply" (GL.iNet firmware bug)

This message has nothing to do with the reflector: it breaks **every** LuCI
page on this firmware, including the login page. Reproduced on a fresh browser
with no session, before any of this package was involved.

Exact sequence:

1. `/etc/nginx/gl-conf.d/gl-portal.conf` declares `error_page 404 /handle_404;`
   and `gl-portal.lua` redirects every 404 to the GL home page (302).
2. On start, LuCI **probes** `/ubus/` to pick its JSON-RPC endpoint.
3. The browser follows the 302, gets 200 (the GL page), so LuCI concludes that
   `/ubus/` works and caches it for the tab.
4. Every later call goes to `/ubus/`, gets HTML instead of JSON-RPC →
   "No related RPC reply", once per batch of requests.

Fix, run once on the router (idempotent, runs `nginx -t`, rolls itself back if
the final test fails):

```sh
scp -O scripts/fix-luci-rpc.sh slate7:/tmp/
ssh slate7 'sh /tmp/fix-luci-rpc.sh'
```

It adds `/etc/nginx/gl-conf.d/zz-luci-ubus.conf`, which answers `403` on
`/ubus`; LuCI then falls back to its documented endpoint
`/cgi-bin/luci/admin/ubus`, which works. The GL.iNet UI is unaffected (it uses
`/rpc`).

**After the fix, close every router tab and open a new one**: the broken
endpoint is cached per tab (`sessionStorage`), a plain reload does not clear it.

## FAQ

**Do I need a jailbreak, a computer, or a Mac?**
No. Only the iPhone, SideStore, Tailscale and a compatible router.

**Does it work on cellular only?**
No. iOS only opens lockdownd and RSD when the phone is associated with a Wi-Fi
network, even one without internet. This is an iOS limitation, not this package.

**Does it slow down or route my other traffic?**
No. Only the configured ports, arriving on `tailscale0`, addressed to the
router's Tailscale IP, are touched.

**Will it cut my access to the router?**
No. SSH, LuCI and the rest of the administration keep working through the
router's Tailscale IP, which is exactly what the reference projects get wrong.

**Several iPhones in the house?**
Yes. The reflector is stateless: each phone uses the same *Device IP*, with its
own pairing file and Developer Portal registration.

**What if I reboot the router?**
The service starts with the router (once enabled), recreates the TUN, the route
and the NAT table. The `NoSNAT` setting lives in `tailscaled.state`.

**What if SideStore updates?**
Nothing to do here. Only the *Device IP* and *Remote Endpoint* mode matter.

## Design notes and limits

- Redirection only matches `iifname tailscale0` and the ports
  `62078, 49152-65535`, so **SSH, LuCI and the rest of the router
  administration keep working through its Tailscale IP**. The reference project
  DNATs *all* traffic to `NODE_ADDR`, which cuts admin access to the node.
- No per-peer filtering: any device on the tailnet that contacts
  `<router IP>:62078` is reflected. The reflector sends the packet back to its
  sender, so a curious peer only talks to itself — harmless, but visible in the
  counters. Restrict with `ip saddr` in the `ip sidestore_reflector` table if
  needed.
- `62078` is included in `49152-65535`: `nft` merges the set into
  `{ 49152-65535 }`. That is normal.
- One reflector per node; several iPhones can share it (each sets the same
  *Device IP*), each with its own pairing and Developer Portal registration.
- The reflector is stateless: restarting it drops nothing but in-flight
  connections.

## Field notes (GL-BE3600, firmware 4.10.1)

- Accepted opkg architecture: `aarch64_cortex-a53_neon-vfpv4` only.
- The modern `scp` uses SFTP, absent from dropbear → `scp -O`.
- The local BusyBox has no `sleep 0.1`, no `pgrep`, no `ip route replace`
  (`ip route change` is used instead).
- `signal()` set `SA_RESTART`, so the binary ignored `SIGTERM`; fixed with
  `sigaction(…, 0)`.
- An `accept` in a separate nft table does not short-circuit `fw4`: the
  forwarding rule has to go through a `chain-pre/forward` include.
- LuCI on this firmware needs the `/ubus` workaround described above.
