# Mayfly

Mayfly runs your browser in a disposable virtual machine (VM) behind a default-deny gateway VM. Every session starts from a clean base image, keeps its writes in RAM, and is deleted when you close the browser. You choose one of three entries per session: Firefox over WireGuard, Tor Browser over WireGuard, or an I2P entry for eepsites only. Your normal desktop keeps its existing network. By design, session traffic leaves only through the WireGuard profile you provide, and the gateway drops anything else. That is design intent, not a proven result: a packet-counter check has passed but isn't a proof (see [Tested](#tested)). Mayfly exists for people who want browsing state that doesn't survive the session and a network path designed to fail closed, without running a full privacy-focused operating system.

**Status: experimental (v0.1.0).** Live testing covers one host. Read [Tested](#tested) and [What Mayfly does not protect against](#what-mayfly-does-not-protect-against) before you rely on it. It is a privacy tool, not a guarantee of anonymity, and its leak testing is limited to a single host (see [Tested](#tested)), so don't stake your safety on it yet.

Licence: [MIT](LICENSE).

## Contents

- [What Mayfly is for](#what-mayfly-is-for)
- [How it works](#how-it-works)
- [Threat model](#threat-model)
- [What Mayfly does not protect against](#what-mayfly-does-not-protect-against)
- [Run modes](#run-modes)
- [The three entries](#the-three-entries)
- [Requirements](#requirements)
- [Install packages](#install-packages)
- [Quick start](#quick-start)
- [Advanced](#advanced)
- [Tested](#tested)
- [Windows](#windows)
- [Reference](#reference)
- [Documentation](#documentation)

## What Mayfly is for

Mayfly is for visiting sites without leaving a record of the visit on your computer, and without your home connection being the one the site sees. You pick how the visit leaves your machine:

| Entry | The site sees | Your internet provider sees | Your VPN provider sees |
|---|---|---|---|
| Firefox over WireGuard | The VPN's address, not yours | An encrypted connection to the VPN | Which sites you visit, and when |
| Tor Browser over WireGuard | A Tor exit relay's address | An encrypted connection to the VPN | That you use Tor, not which sites |
| I2P over WireGuard (eepsites only) | Not your IP address. Eepsites are reached through I2P tunnels | An encrypted connection to the VPN | That the traffic looks like I2P, not which eepsites |

What you get when the session ends and you shut the machine down or lock it as you normally would:

- **No browsing record on your computer.** By design, history, cookies, caches, bookmarks and downloads are written to a RAM-backed overlay and discarded. A live check supports this (see [Tested](#tested)). Nothing in your normal browser or home directory ever saw the visit.
- **No record of the visit in your desktop's normal network setup.** Your desktop's own connection doesn't carry the traffic to the sites; only the encrypted tunnel to your VPN does. Your router and internet provider can still see that tunnel.

What this doesn't mean, and why the claim "no trace" is not safe to make:

- The VPN provider, Tor relays, I2P peers and the sites themselves keep their own records. Mayfly can't delete those.
- Anything you log in to, search for or type identifies you to that site, whichever route you use.
- Session memory can reach disk if your host swaps, hibernates or writes a crash dump. Mayfly checks for these when a session starts: `launch` refuses to run on a host with disk swap, a configured resume device, a loaded crash kernel or a piped core-dump handler, and `preflight` warns about disk swap. It doesn't watch for them during a session. See [What Mayfly does not protect against](#what-mayfly-does-not-protect-against).
- It protects the visit from your computer's records, not from someone who controls the computer while the session runs.
- Leak-proofing is by design. A packet-counter test of all three entries found nothing leaving outside the tunnel, but a test can't prove that no leak path exists. See [Tested](#tested).

## How it works

Mayfly runs native QEMU as a user process, not through libvirt:

```text
Normal desktop applications: existing host networking, unchanged by Mayfly

Firefox ---------+
                 | browser VM, one NIC
Tor Browser -----+---- private UNIX socket ---- gateway VM
   |                                            |
   +-- bundled Tor client                       +-- WireGuard -- VPN endpoint
         (Tor connections travel through VPN)
```

- The gateway VM alone has QEMU user-mode WAN networking. Its guest service loads default-deny nftables rules before it enables WAN connectivity.
- The rules permit WAN UDP only to the profile's numeric endpoint. Browser traffic is forwarded through `wg0`, never through the WAN interface.
- IPv6 is disabled in both guests and denied by the gateway filter.
- The browser VM runs Debian's `firefox-esr` package and the upstream Tor Browser bundle. A chooser starts one entry per session. Firefox has no Tor proxy configuration. Tor Browser starts its own bundled Tor client.
- Each session gets fresh qcow2 overlays on a RAM-backed `tmpfs` over two read-only base images that you build once. The guests get 1 GiB and 4 GiB of RAM, and each overlay file has a hard 3 GiB growth ceiling.
- The launcher configures no shared folder and no download export. Downloads, bookmarks and guest-side changes are lost with the session.

These are implemented controls. A packet-counter check that nothing falls back to a direct path has passed (see [Tested](#tested)).

The exact QEMU arguments are in [`lib/runtime.sh`](lib/runtime.sh). The guest firewall is in [`lib/policy.sh`](lib/policy.sh) and [`guest/network.sh`](guest/network.sh).

## Threat model

Mayfly is built to reduce these risks:

- **Browser state that outlives a session.** Cookies, history, caches and downloads live on a RAM-backed overlay and are discarded at the end.
- **Browser compromise reaching your desktop.** The browser runs inside a VM with no shared folders.
- **Accidental direct connections.** The browser VM has one NIC that leads only to the gateway, and the gateway denies everything except the tunnel.
- **Other programs on your desktop reading the session.** In run mode 1, the VMs run as a separate `mayfly` user, so other programs that run as you can't read the VMs' memory, the profile or the bases through file permissions.

Mayfly assumes the host kernel, hypervisor, your firmware and the base images you build are trustworthy.

## What Mayfly does not protect against

RAM-only session storage is not a zero-traces or physical memory-wipe promise. The host still stores the source, base images, build caches and the local VPN profile. Host activity metadata, external network logs, provider records and remote-site records are outside session cleanup. A compromised host can inspect guest memory, input, display and keys, and this design doesn't defend against that.

Specifically:

- **A compromised host or hypervisor.** Anything that controls your host controls the VMs.
- **Your own user account, in run modes 2 and 3.** Software that runs as your user can read the VMs' memory. Only mode 1 closes this gap, and even then your `sudo` password stays a way in, because your account remains an administrator.
- **Browser fingerprinting and account correlation.** Firefox over a VPN is not Tor anonymity, and Mayfly doesn't make Firefox fingerprint-resistant. Accounts, fingerprinting and correlation can still identify your activity. See [Tor Browser's fingerprinting protections](https://support.torproject.org/tor-browser/features/fingerprinting-protections/) and their limits.
- **Your VPN provider.** The provider sees that you connect and where your traffic goes. Tor Browser over a VPN adds another party and configuration dependency, not a proven anonymity improvement. Read the [Tor Project's VPN guidance](https://support.torproject.org/tor-browser/general/vpn-with-tor/) first.
- **Code that takes over the browser.** The I2P entry's "no ordinary websites" rule is a browser property, not a network one. Code that controls the browser can still reach the internet through the tunnel, as in the other two entries.
- **Encrypted DNS chosen by an application.** The gateway filter restricts classic TCP/UDP port 53 DNS. It doesn't pin every encrypted DNS protocol to the profile's resolver. The Firefox entry blocks DNS over HTTPS by policy. `about:policies` lists that policy as active, but the blocking itself hasn't been tested.
- **Memory pressure and storage exhaustion.** The host may stop a VM or the launcher under memory pressure, and overlay exhaustion can end a VM. Neither case has a disk fallback or a guarantee that a session completes.
- **Hibernation, swap and crash dumps.** Session memory can reach disk if your host writes RAM out. The risks are disk swap, hibernation, VM save-state, and crash dumps by a system collector such as `systemd-coredump` or `apport`. The launcher refuses to start on a host that has disk swap, a configured resume device, a loaded crash kernel or a piped core handler. That is a check at launch only. Mayfly can't stop you from changing the setting after the session starts, for example by restoring the core-dump policy or hibernating while a session is open. Anything written that way can hold what you browsed, the WireGuard key or guest memory, and Mayfly can't clean it up. Restore the core-dump policy only after every session has ended. See [Core-dump policy](DEPLOYMENT.md#9-temporary-core-dump-policy).
- **Stale software.** Nothing updates inside a session, and base images age. The launcher warns when a base is older than 35 days (`MAYFLY_MAX_BASE_AGE_DAYS` changes the limit). Rebuild bases regularly.
- **Wayland-socket exposure in mode 1.** The `mayfly` user, including a compromised VM, can talk to your compositor as an ordinary client through the one shared Wayland socket. What the compositor allows such a client to do is unverified.
- **Content on the networks.** Sites reachable over Tor or I2P can host scams, malware and illegal material.

### Host and browser hardening

When you start the launcher from a Wayland session, it forces the Wayland display backend and drops the X11 variables, so the VM window isn't exposed through XWayland. It deletes the RAM copy of the profile once the gateway has started, because QEMU reads that file at startup.

The Firefox entry loads [`guest/firefox-policies.json`](guest/firefox-policies.json). That file configures Firefox to block DNS over HTTPS, restrict WebRTC address candidates, turn off telemetry, studies, sponsored content, extensions and developer tools, and enable HTTPS-only mode and strict tracking protection. Some keys need Firefox ESR 140.4 or later, and the build doesn't pin the ESR version, so check the version in the build log. Tor Browser keeps its upstream fingerprint defaults. The Firefox policy doesn't apply to Tor Browser, except for the shared update controls.

Update controls are written at build time by [`guest/browser-prepare.sh`](guest/browser-prepare.sh) into Firefox's `/etc/firefox/policies/policies.json` and Tor Browser's `/opt/tor-browser/Browser/distribution/policies.json`. Both files, and their ancestor directories, are root-owned and not writable by the unprivileged browser user. Guest apt update services are masked.

| Control written for both browsers | Value |
|---|---|
| `DisableAppUpdate` | `true` |
| `ExtensionUpdate` | `false` |
| `DisableSystemAddonUpdate` | `true` |
| `media.gmp-manager.updateEnabled` and `media.gmp-provider.enabled` | `false`, status `locked` |

These are source controls, not proof of effective runtime behavior. See [Tested](#tested).

## Run modes

| Mode | How it runs | Boundary | Notes |
|---|---|---|---|
| 1. Dedicated service user, native host | `sudo mayfly ...` through the installer's wrapper. The VMs run as the no-login `mayfly` user. | **Strongest.** Other programs that run as you can't read the VMs' memory, the profile or the bases through file permissions. | Needs root once, to install. Requires a native Wayland session. |
| 2. Same user, native host | `bash mayfly.sh ...` as your desktop user. | Other programs that run as you can read the VMs' memory, the profile and the bases. | Simplest. No root needed after you install packages. |
| 3. Distrobox, same user only | `bash mayfly.sh ...` inside a distrobox container. | Same as mode 2. | Distrobox can't provide the dedicated-user boundary, because that boundary needs host users, mounts and sysctls. |

Immutable distributions such as Bazzite and Silverblue can use mode 1 natively through the installer, or mode 3.

Mode 3 has not been live-tested. The offline suite runs inside distrobox containers (see [Tested](#tested)). Inside a distrobox container, host root appears as `nobody`, and Mayfly accepts that.

## The three entries

| Entry | What it is | Notes |
|---|---|---|
| **Firefox over WireGuard** | Debian `firefox-esr` with the hardening policy above. | All traffic goes through your WireGuard profile. Not Tor. |
| **Tor Browser over WireGuard** | The upstream Tor Browser bundle with its bundled Tor client. | Tor connections travel through the tunnel. Tor Browser's own defaults apply. |
| **I2P over WireGuard (eepsites only)** | A Debian `i2pd` router inside the browser VM, and a separate Firefox profile whose only proxy is that router. | `.i2p` sites only. The router has no outproxy, so ordinary websites are refused. Experimental. |

### The I2P entry

Type `http://` before `.i2p` addresses. Most eepsites don't use HTTPS, and Firefox can otherwise treat the name as a search. The router config is [`guest/i2pd.conf`](guest/i2pd.conf) and the browser settings are [`guest/i2p-user.js`](guest/i2p-user.js).

The [I2P getting started guide](https://i2p.net/en/docs/guides/gettingstarted/#firefox-recommended) describes a manual Firefox setup for the Java router. This entry follows it for the proxy (`127.0.0.1` port `4444`), `keyword.enabled`, `media.peerconnection.ice.proxy_only`, the `.i2p` domain suffix and a separate profile. It differs on purpose:

- It runs `i2pd`, not the Java router.
- Extensions are blocked, so it doesn't use the guide's "I2P in Private Browsing" extension. It has no container tabs or first-party isolation, and relies on fingerprint resistance and letterboxing, whose effect is unverified.
- JavaScript and WebRTC are off. HTTPS-Only and HTTPS-First are off so that plain HTTP eepsites load.
- The router relays no traffic for others, and pages can't add address-book entries through jump links.
- It never uses the guide's default outproxy.

Limits to expect:

- Every session builds a new router identity and takes a few minutes to join. The session ends by itself if the router isn't ready after about ten minutes. The launcher waits for 6 tunnels, and that threshold hasn't been tuned.
- An outbound-only router can be slow to join or fail to build enough tunnels.
- A name resolves only once the router has downloaded its default address book. A `.b32.i2p` address works without it.
- Your VPN provider can see that the traffic looks like I2P, and the reseed servers see your VPN address when the router joins.
- The guest has no network time sync. I2P needs a roughly correct clock, so suspect the clock first if joining never finishes.
- Debian's `i2pd` is older than the upstream release, and whether its packaged AppArmor profile is enforced in the guest is unverified.
- This entry uses Firefox ESR, so it doesn't give Tor Browser's uniform fingerprint.

## Requirements

- An x86_64 Linux host with hardware virtualization and read/write access to `/dev/kvm`.
- A **native Wayland session**. Only native Wayland sessions are supported and tested. Preflight warns when it finds none.
- 16 GiB of available RAM recommended. The launcher requires 16 GiB available at the check.
- Native QEMU 8.0 or later with the GTK display and the `user` and `stream` network backends.
- A WireGuard profile that you provide, in the [restricted format](#wireguard-profile-format) below. Keep it outside the source directory and never commit it to Git.
- Bash, `jq`, `awk`, `prlimit`, `runuser` and `unshare` (both from `util-linux`), an ISO tool (`genisoimage`, `mkisofs` or `xorriso`), and `qemu-img`. Building bases also needs `virt-customize`, `virt-resize`, `curl`, `gpg` and `gpgv`. Mode 1 also needs `setfacl`.
- Internet access for building bases. Launching never downloads or installs anything.

Flatpak isn't qualified. A container or Flatpak tool with a similar name doesn't satisfy these requirements.

## Install packages

Run `bash mayfly.sh preflight`. It changes nothing, reports what's missing, and prints the exact install command for your system. The commands below are what it prints. If you use a container or an unsupported distribution, install the equivalent packages with your own package manager.

| Distribution | Command |
|---|---|
| Fedora | `sudo dnf install qemu-kvm qemu-img qemu-ui-gtk xorriso guestfs-tools gnupg2 gnupg2-verify jq curl tar gawk util-linux acl git-core` |
| Bazzite and other Fedora Atomic (rpm-ostree) | `sudo rpm-ostree install --idempotent qemu-kvm qemu-img qemu-ui-gtk xorriso guestfs-tools gnupg2 gnupg2-verify jq curl tar gawk util-linux acl git-core`, then reboot. Rebooting is your decision. Mayfly never reboots your system. |
| Debian 13 | `sudo apt-get install qemu-system-x86 qemu-utils qemu-system-gui xorriso libguestfs-tools gpg gpgv jq curl tar gawk util-linux acl git` |
| Ubuntu 24.04 | Same as Debian 13. |
| Arch | `sudo pacman -S --needed qemu-system-x86 qemu-img qemu-ui-gtk libisoburn guestfs-tools gnupg jq curl tar gawk util-linux acl git` |
| openSUSE Tumbleweed (best effort) | `sudo zypper install qemu-x86 qemu-tools qemu-ui-gtk xorriso guestfs-tools gpg2 jq curl tar gawk util-linux acl git-core` |

Preflight leaves out packages that are already present, so your output may be shorter. See [DEPLOYMENT.md](DEPLOYMENT.md#1-check-the-host-and-install-packages) for distribution-specific hazards, such as unreadable kernel images on Ubuntu.

## Quick start

This is the shortest path for run mode 2 (your own user, native host). Mayfly keeps everything it needs in `~/.local/state/mayfly` (or `$MAYFLY_HOME`, or `$XDG_STATE_HOME/mayfly`).

```bash
git clone https://github.com/stschulznz/mayfly.git && cd mayfly
bash mayfly.sh preflight
(umask 077; mkdir -p ~/.local/state/mayfly/secrets) && install -m 600 /path/to/provider.conf ~/.local/state/mayfly/secrets/wireguard.conf
bash mayfly.sh setup --core-policy
bash mayfly.sh launch --core-policy
```

1. `preflight` changes nothing. It prints the package install command for your system. Run that command, then run `preflight` again until it says `Ready for the next step`. Fix every `WARNING` line before you continue, because that message is printed even when warnings remain. See [step 1 of DEPLOYMENT.md](DEPLOYMENT.md#1-check-the-host-and-install-packages) for the Ubuntu kernel-image fix (`sudo chmod 0644 /boot/vmlinuz-*`) and the `/dev/kvm` group fix.
2. Place your WireGuard profile at the default path, mode `0600`, in the [restricted format](#wireguard-profile-format). Provider-generated files often fail the restricted parser (IPv4 `/32` address only, a numeric IPv4 endpoint, one numeric DNS server), so edit yours to match first. `setup` rejects anything else at its profile check, step 4 of 6, before any download, and names the field, not the value. If you skip this step, `setup` creates the directories, tells you where the file goes and stops. Run it again after you place the file.
3. `setup` checks the profile, downloads and verifies Debian and Tor Browser (it shows exact versions and URLs and asks `Continue? [y/N]`), then builds the base. Each step is skipped when it's already done, so it's safe to run again.
4. `launch` starts the newest base. Pick an entry in the chooser and keep the terminal open. Close the browser to end the session. The VMs stop and the session's RAM files are removed.

A profile in the accepted shape looks like this. The values are placeholders:

```ini
[Interface]
PrivateKey = <your private key>
Address = 10.0.0.2/32
DNS = 10.0.0.1

[Peer]
PublicKey = <the server's public key>
AllowedIPs = 0.0.0.0/0
Endpoint = 203.0.113.5:51820
```

`--core-policy` is only needed when your host pipes core dumps to a collector such as `apport` or `systemd-coredump`, or has `fs.suid_dumpable` other than `0`. When the host already satisfies the requirement, it changes nothing. Otherwise it runs `sudo sysctl` to set `kernel.core_pattern=/dev/null` and `fs.suid_dumpable=0` for the whole host, and undoes that on exit only if it applied the change and no QEMU process is running. Before you launch, close other work and don't hibernate. See [Core-dump policy](DEPLOYMENT.md#9-temporary-core-dump-policy).

Run mode 1 (dedicated user) has more steps than mode 2, in this order:

1. Run `bash mayfly.sh preflight` and install the packages it prints, as above.
2. Place your WireGuard profile at `~/.local/state/mayfly/secrets/wireguard.conf` with mode `0600`, as in step 2 above, before you run the installer. The installer imports it for the `mayfly` user, and `sudo mayfly setup` stops with "the WireGuard profile is missing" without it.
3. Read `host/install-host.sh`, then run `sudo bash host/install-host.sh`.
4. Run `sudo mayfly setup`, then `sudo mayfly launch --core-policy`. If `sudo` can't find `mayfly`, use `/usr/local/sbin/mayfly`.

See [DEPLOYMENT.md](DEPLOYMENT.md#10-run-as-a-dedicated-user-mode-1).

## Advanced

`setup` runs these commands in order. Run each one yourself if you want to:

```bash
bash mayfly.sh check-profile [--core-policy] [ABSOLUTE-PROFILE-FILE]
bash mayfly.sh fetch-pins [--yes] [--debian DATE-BUILD] [--tor X.Y.Z] [PINS-FILE]
bash mayfly.sh build [PINS-FILE] [NAME]
bash mayfly.sh doctor ABSOLUTE-RAM-DIRECTORY
bash mayfly.sh launch [--core-policy] [NAME]
bash mayfly.sh core-policy apply|restore|status
```

- `fetch-pins` finds the newest Debian trixie generic cloud image and the latest stable Tor Browser version, shows them, asks for confirmation, and writes the pins file only if every check passes. Debian publishes no detached signature, so trust in the image is HTTPS plus Debian's published `SHA512SUMS`. Tor Browser is verified against Tor's pinned signing key. Pass `--debian` and `--tor` to choose versions yourself. Versions are chosen automatically from upstream, so compare them with the official Debian and Tor Browser pages if you need to guard against a downgrade. `--yes` skips this review. [DEPLOYMENT.md](DEPLOYMENT.md#2-get-and-verify-downloads) lists the equivalent manual steps.
- `build` names the base `base-YYYYMMDD` unless you give a name, and never overwrites an existing base.
- The absolute-path forms still work and are what the dedicated-user wrapper uses: `build ABS-PINS ABS-NEW-BASE` and `launch ABS-BASE ABS-PROFILE [RAM-PARENT]`.
- [DEPLOYMENT.md](DEPLOYMENT.md#manual-and-advanced-steps) has the manual steps, host diagnostics, the leak test and troubleshooting.

## Tested

| What | Result |
|---|---|
| Offline suite, `bash tests/run.sh` (515 checks) | Passes inside distrobox containers of Debian 13, Ubuntu 24.04, Fedora 44, Arch and openSUSE Tumbleweed. |
| Live image build, boot and browsing | Verified on **one** host (Bazzite, Fedora family) only: Firefox over WireGuard, Tor Browser over Tor over WireGuard, and I2P. A bookmark made in one session was absent from the next. |
| Dedicated-user boundary (run mode 1) | Verified on that same host: the `mayfly` user owned the QEMU processes, `/var/lib/mayfly` was `root` mode `drwx--x--x`, and the `mayfly` user's profile and `/proc/<pid>/mem` of the VMs were denied to the desktop user. |
| `--core-policy`, apply and automatic restore (run mode 1) | On a host whose original setting was the `systemd-coredump` handler with `fs.suid_dumpable = 2`, `sudo mayfly launch --core-policy` set `/dev/null` and `0` for the session and restored the original values when the session closed. The same sequence ran in same-user mode (mode 2) with the same result: the same-user restore accepted that handler and `fs.suid_dumpable = 2`. |
| Firefox hardening policy and sandbox | `about:policies` in the Firefox entry lists the policies as active, and `about:support` shows a content process sandbox level of 6 (enabled). |
| Tor Browser security level | The level reads Standard, which is Tor Browser's default. Mayfly doesn't change it. |
| RAM-only writes (run mode 1) | While the session ran, `/dev/shm` grew from 65 MiB to 307 MiB after a large download and browsing, while `/` and `/var/home` changed by 5 MiB or less (other host activity). After the session ended, no `mayfly.*` directory remained in `/dev/shm`, and the only file the `mayfly` user had written on disk since the start was a small `dconf` cache file in its home directory. Browsing content wasn't looked for on disk beyond that file listing. |
| Leak test, all three entries (run mode 1) | Per-user packet counters on that host. After the Firefox, Tor Browser and I2P sessions, the `mayfly` user had sent 15,939 packets off the machine, and all 15,939 went to the WireGuard endpoint. The counters were cumulative, so each session added to the total and none added a packet elsewhere. No DNS, IPv6 or other traffic from the VMs was counted. One session per entry is not proof for every case. |
| Tunnel-down test (run mode 1) | With a profile whose endpoint port was wrong, no site loaded. The `mayfly` user sent 11 packets off the machine, all to that endpoint and port (WireGuard handshake retries). |
| Other distributions | **Not live-tested.** |

Each live test above was run on a single host. The offline suite checks parsers, policy text, host predicates, and mocked build and launch failure paths. It doesn't boot VMs or prove routing.

On the live host, Firefox over WireGuard, Tor Browser and the I2P entry worked. A bookmark made in one session was absent from the next, and sessions shut down cleanly. In dedicated-user mode, the VM processes were owned by the service user, and the state directory was `root:root` mode `0711`. Other processes of the desktop user were denied `/proc/<pid>/mem` of the VMs, the profile and the session directory, and the Wayland socket ACL was revoked after each session. The VMs ran in the same unconfined SELinux domain (`unconfined_t`) as the desktop user.

**Still unverified:**

- The leak test in run modes 2 and 3, and on any host other than the one tested. The [leak test](DEPLOYMENT.md#12-leak-test-check-that-nothing-leaves-outside-the-tunnel) has only been run in run mode 1.
- Restart paths, tunnel loss in the middle of a session, and a gateway or router crash.
- Update suppression in either browser. Tor Browser showed no update prompt in the sessions run, which isn't proof that updates are blocked.
- A policy-by-policy check of Firefox beyond `about:policies` listing them as active.
- A full SELinux denial survey. `ausearch -m avc -ts recent` found no denials after one session.

Also unverified: I2P joining time and SSU2 behavior at the guest's 1280-byte MTU, and AppArmor enforcement in the guest.

## Windows

WSL2 support is planned. It isn't available yet.

## Reference

### Commands

```text
bash mayfly.sh preflight
bash mayfly.sh setup [--core-policy] [--yes]
bash mayfly.sh fetch-pins [--yes] [--debian DATE-BUILD] [--tor X.Y.Z] [PINS-FILE]
bash mayfly.sh build [PINS-FILE] [NAME | NEW-BASE-DIRECTORY]
bash mayfly.sh launch [--core-policy] [NAME]
bash mayfly.sh check-profile [--core-policy] [PROFILE-FILE]
bash mayfly.sh core-policy apply|restore|status
bash mayfly.sh doctor ABSOLUTE-RAM-DIRECTORY
bash mayfly.sh build ABSOLUTE-PINS-FILE NEW-BASE-DIRECTORY
bash mayfly.sh launch BASE-DIRECTORY PROFILE-FILE [RAM-PARENT]
```

- `preflight` lists missing tools and prints an install command. It changes nothing.
- `setup` runs preflight, creates the state directory, checks the profile, fetches pins and builds a base, skipping finished steps. It never reads or prints the profile when it's missing.
- `fetch-pins` downloads and verifies the Debian image and Tor Browser, then writes the pins file. It refuses to overwrite an existing pins file.
- `doctor` checks prerequisites only: it never tests live routing or full operational readiness. It exits `78` when it refuses the host.
- `check-profile` parses a profile locally and prints no keys. It doesn't contact the provider or prove the keys work. Without a path it checks the default profile.
- `build` downloads the pinned images, installs guest packages and writes two bases. It never accepts a VPN profile and never overwrites a base.
- `launch` starts a session. With no base it uses the newest one. `RAM-PARENT` defaults to `/dev/shm`, and the launcher creates its own `0700` subdirectory there. The resulting session path must be shorter than 75 characters, because of the UNIX socket limit.
- `core-policy` applies, restores or shows the temporary core-dump policy. `restore` refuses while any QEMU process exists.

Run mode 1 uses `sudo mayfly setup`, `fetch-pins`, `doctor`, `check-profile [--core-policy]`, `build [NAME]`, `launch [--core-policy] [--diag] [--display wayland-N] [NAME]`, `core-policy`, `status`, `stop` and `cleanup`. See [DEPLOYMENT.md](DEPLOYMENT.md#10-run-as-a-dedicated-user-mode-1).

Use canonical absolute paths with no symlink components. For build and runtime data paths, use only letters, digits, `_`, `.`, `/` and `-`.

### Memory and host checks

The launcher checks these conditions before it reads a real profile:

| Condition | Requirement |
|---|---|
| Available physical memory | At least 16 GiB at the check |
| Session filesystem | Actual `tmpfs`, with `nodev,nosuid` |
| tmpfs capacity and free space | At least 7 GiB each |
| Session directory | Current owner, mode `0700`, canonical absolute path |
| Swap | None, or only `/dev/zramN` devices whose `backing_dev` is `none` |
| Resume configuration | No configured resume device, offset or resume kernel arguments |
| Kernel crash dump | No loaded crash kernel and no reserved crash memory |
| Process core dumps | Zero soft and hard core limits, `suid_dumpable=0`, and a non-piped core pattern |

These checks are snapshots, not resource reservations. Another application can consume RAM after launch, and a large shared tmpfs isn't a private session quota. Don't weaken a refused check just to start the VMs.

### Pins file

The pins file is literal `key=value` data, not shell. Supply each field once.

| Field | Value |
|---|---|
| `IMAGE_URL` | Versioned official Debian 13 generic amd64 qcow2 HTTPS URL |
| `IMAGE_SHA256` | SHA-256 of the verified image, 64 lowercase hexadecimal digits |
| `TOR_URL` | Versioned official stable `tor-browser-linux-x86_64-<version>.tar.xz` HTTPS URL |
| `TOR_SHA256` | SHA-256 of the signature-verified archive, 64 lowercase hexadecimal digits |

The parser accepts only these four fields, blank lines and full-line comments. Quotes, shell variables and command substitutions aren't expanded. Mayfly ships no sample hashes. The fixture in `tests/fixtures/synthetic.pins` is deliberately unusable.

Build checks both SHA-256 pins. It also fetches the matching Tor signature and signing key and verifies them with `gpgv` against the pinned primary fingerprint. It doesn't verify a Debian signature, because Debian's cloud image directory publishes `SHA512SUMS` without a detached signature. See [Get and verify downloads](DEPLOYMENT.md#2-get-and-verify-downloads).

A successful build produces `gateway.qcow2` and `browser.qcow2`, each with a 16 GiB virtual size, mode `0444` and a `.sha256` companion file. Guest package versions from Debian repositories aren't pinned, so builds are not reproducible.

### WireGuard profile format

Get a profile privately from your provider. Never paste it into an issue, terminal transcript, chat, test fixture or repository.

The file must be a regular file you own, mode `0600`, with one hard link, in a parent directory you own with mode `0700`. It must be 1 to 16384 bytes, with at most 100 lines. Every ancestor directory through `/` must belong to root or you and must not be group- or world-writable (a root-owned sticky directory is the exception). Symlink components are rejected. `check-profile` and `launch` open the file once, compare the descriptor with the validated metadata snapshot, and reject replacements.

The parser supports a deliberately restricted format:

| Section | Required fields | Optional fields |
|---|---|---|
| One `[Interface]`, first | `PrivateKey`, one IPv4 `/32` `Address`, one numeric IPv4 `DNS` | `MTU` (1280 to 1420) |
| One `[Peer]`, second | `PublicKey`, `AllowedIPs = 0.0.0.0/0`, public numeric IPv4 `Endpoint` with UDP port 1 to 65535 | `PresharedKey`, `PersistentKeepalive` (0 to 65535) |

The address, resolver and endpoint must be distinct and must avoid the fixed guest networks. Mayfly rejects hostname endpoints, IPv6, split tunnels, multiple peers, multiple addresses or resolvers, hooks, includes, routing-table overrides, and unknown or duplicate fields. A valid `wg-quick` profile from your provider may therefore not be supported.

## Documentation

- [DEPLOYMENT.md](DEPLOYMENT.md): a numbered first-run guide, core-dump policy, dedicated-user install, and troubleshooting.
- [SECURITY.md](SECURITY.md): how to report a vulnerability.
- [CONTRIBUTING.md](CONTRIBUTING.md): how to run the tests and what a change needs.
