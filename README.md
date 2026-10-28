<p align="center">
  <img src="assets/logo.png" alt="Mayfly logo: a geometric low-poly mayfly with cyan wings and yellow edges on a dark circle" width="200">
</p>

# Mayfly

<p align="center">
  <img src="assets/banner.png" alt="Illustration of a hooded netrunner at a desk full of glowing screens showing network graphs and mayflies, in front of a rainy neon city" width="100%">
</p>

Mayfly runs your browser in a disposable virtual machine (VM) behind a default-deny gateway VM. Every session starts from a clean base image, keeps its writes in RAM, and is deleted when you close the browser. You choose one of three entries per session: Firefox over WireGuard, Tor Browser over WireGuard, or an I2P entry for eepsites only. Your normal desktop keeps its existing network. By design, session traffic leaves only through the WireGuard profile you provide, and the gateway drops anything else. That is design intent, not a proven result: a packet-counter check has passed but isn't a proof (see [Tested](#tested)). Mayfly exists for people who want browsing state that doesn't survive the session and a network path designed to fail closed, without running a full privacy-focused operating system.

**Status: experimental (v0.1.0).** Live testing covers one host. Read [Tested](#tested) and [What Mayfly does not protect against](#what-mayfly-does-not-protect-against) before you rely on it. It is a privacy tool, not a guarantee of anonymity, and its leak testing is limited to a single host (see [Tested](#tested)), so don't stake your safety on it yet.

Licence: [MIT](LICENSE).

## Contents

- [What Mayfly is for](#what-mayfly-is-for)
- [How it works](#how-it-works)
- [Threat model](#threat-model)
- [What Mayfly does not protect against](#what-mayfly-does-not-protect-against)
- [When you need stronger protection](#when-you-need-stronger-protection)
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

### Researching risky sites

Mayfly is also built for security research on parts of the internet you wouldn't open on your everyday system, such as dark web and I2P sites. Every page runs in a throwaway VM, not on your host. That limits the damage a hostile page can do:

- **An exploit has to get out of the VM.** A browser exploit lands inside the VM first. To reach your computer it would also need a way out of the VM.
- **Nothing crosses back by default.** There are no shared folders, no shared clipboard and no download export (on Windows the clipboard is shared; see [Windows](#windows)). Files you open or download in a session stay in the session. The `--attach` option only goes from your host into the VM.
- **The VM can't reach your home network.** The browser VM has one connection, to the gateway VM, and the gateway lets out only the WireGuard tunnel. In the packet counter test, every packet the VMs sent went to the VPN endpoint, so none went to other devices on your network.
- **Nothing persists.** The base image is read-only and the session overlay is in RAM, so malware that lands in a session is gone when it ends.
- **A separate user in run mode 1.** The VMs run as the `mayfly` user, not as you.

This lowers the risk. It doesn't remove it. A flaw in QEMU, KVM or the kernel could let code escape a VM, so keep those updated. In run modes 2 and 3 an escape would run as you. Don't open files from a session on your host, and only visit content that is legal where you are. See [What Mayfly does not protect against](#what-mayfly-does-not-protect-against).

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
- **A VM escape.** A flaw in QEMU, KVM or the host kernel could let code in a VM reach your host. In run mode 1 it would run as the `mayfly` user, and in modes 2 and 3 as you. Keep QEMU and your kernel updated.
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

## When you need stronger protection

Mayfly runs on top of your everyday operating system. Everything it does depends on that system being trustworthy, so it can't protect a session from malware, a keylogger or a compromised kernel on the host. If you need protection from the computer itself, use a system that doesn't depend on it.

[Tails](https://tails.net/) is built for that. You start the computer from a USB stick instead of your normal system. Tails runs from memory and doesn't use the computer's hard disk. It sends all internet traffic through the Tor network and blocks applications that try to connect without Tor. When you shut down, the memory is erased and nothing remains on the computer. Because it doesn't start your installed system, malware on that system doesn't run during the session.

Tails also has limits. It can't protect you if you install it from an infected computer or use it on a computer with malicious hardware, such as a keylogger. See the Tails pages for the details:

- [About Tails](https://tails.net/about/)
- [Warnings: Tails is safe but not magic](https://tails.net/doc/about/warnings/)
- [Download and install Tails](https://tails.net/install/)
- [System requirements](https://tails.net/doc/about/requirements/)

Mayfly and Tails fit different needs:

| | Mayfly | Tails |
|---|---|---|
| Runs on | Your installed system, in a VM | A USB stick, instead of your installed system |
| Protection from the host | None. A compromised host can read the session. | Strong, because your installed system doesn't run |
| Network | Your own VPN, Tor Browser through the VPN, or I2P | Tor for everything |
| Convenience | Use it next to your normal work, no restart | Restart the computer to use it |

If your threat includes the computer you're using, choose Tails. Use Mayfly when you want a disposable browser session beside your normal work and you trust the host.

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
- A **Wayland desktop session**. Wayland is the system that draws your desktop. The older one is X11. Only native Wayland sessions are supported and tested, and preflight warns when it finds none. To check yours, run `echo $XDG_SESSION_TYPE` in a terminal. It prints `wayland` or `x11`. Most current default desktops use Wayland, including Fedora Workstation, Ubuntu 24.04, Debian 13 with GNOME or KDE Plasma, and Bazzite with KDE Plasma. Xfce and MATE still default to X11. If you see `x11`, log out and pick a Wayland session on the login screen, often named "Plasma (Wayland)" or "GNOME" in place of the "Xorg" or "X11" entry. Gaming-mode sessions such as Bazzite's Steam Gaming Mode aren't supported, so use the desktop session.
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

You need a WireGuard profile from a VPN provider before you start. Mayfly isn't a VPN and doesn't provide one. Download the WireGuard configuration file from your provider's account page. The launcher refuses to start without it. You don't create anything else by hand.

This is the shortest path for run mode 2 (your own user, native host). Mayfly keeps everything it needs in `~/.local/state/mayfly` (or `$MAYFLY_HOME`, or `$XDG_STATE_HOME/mayfly`) and creates the subdirectories itself.

```bash
# Download Mayfly and enter its folder. If you don't have git, download the ZIP from GitHub instead.
git clone https://github.com/stschulznz/mayfly.git && cd mayfly

# Check your system. It changes nothing and prints the install command for anything missing.
bash mayfly.sh preflight

# Make a private folder for the profile, then copy your WireGuard file into it
# with owner-only permissions (600). Replace /path/to/provider.conf with your file.
(umask 077; mkdir -p ~/.local/state/mayfly/secrets) && install -m 600 /path/to/provider.conf ~/.local/state/mayfly/secrets/wireguard.conf

# Download and verify Debian and Tor Browser, then build the base images (this takes several minutes).
bash mayfly.sh setup --core-policy

# Start a session and pick Firefox, Tor Browser or I2P in the chooser.
bash mayfly.sh launch --core-policy
```

1. `preflight` changes nothing. It prints the package install command for your system. Run that command, then run `preflight` again until it says `Ready for the next step`. Fix every `WARNING` line before you continue (each one prints a `Fix:` line with what to do), because that message is printed even when warnings remain. See [step 1 of DEPLOYMENT.md](DEPLOYMENT.md#1-check-the-host-and-install-packages) for the Ubuntu kernel-image fix (`sudo chmod 0644 /boot/vmlinuz-*`) and the `/dev/kvm` group fix.
2. Place your WireGuard profile at the default path, mode `0600`, in the [restricted format](#wireguard-profile-format). Provider-generated files often fail the restricted parser (IPv4 `/32` address only, a numeric IPv4 endpoint, one numeric DNS server), so edit yours to match first. `setup` rejects anything else at its profile check, step 4 of 6, before any download, and names the field, not the value. If you skip this step, `setup` creates the directories, tells you where the file goes and stops. Run it again after you place the file.
3. `setup` checks the profile, downloads and verifies Debian and Tor Browser (it shows exact versions and URLs and asks `Continue? [y/N]`), then builds the base. Each step is skipped when it's already done, so it's safe to run again.
4. `launch` starts the newest base. Pick an entry in the chooser and keep the terminal open. Close the browser to end the session. The VMs stop and the session's RAM files are removed.

A profile in the accepted shape looks like this. The values are placeholders:

```ini
# Your side of the tunnel.
[Interface]
# The secret key for this device. Keep it private.
PrivateKey = <your private key>
# Your address inside the VPN, as a single IPv4 address with /32.
Address = 10.0.0.2/32
# The VPN's DNS server, as a numeric IPv4 address.
DNS = 10.0.0.1

# The VPN server.
[Peer]
PublicKey = <the server's public key>
# Send all traffic through the tunnel.
AllowedIPs = 0.0.0.0/0
# The server's numeric IPv4 address and port. Use your provider's real one; this example address is for documentation only.
Endpoint = 203.0.113.5:51820
```

`--core-policy` is only needed when your host pipes core dumps to a collector such as `apport` or `systemd-coredump`, or has `fs.suid_dumpable` other than `0`. When the host already satisfies the requirement, it changes nothing. Otherwise it runs `sudo sysctl` to set `kernel.core_pattern=/dev/null` and `fs.suid_dumpable=0` for the whole host, and undoes that on exit only if it applied the change and no QEMU process is running. Before you launch, close other work and don't hibernate. See [Core-dump policy](DEPLOYMENT.md#9-temporary-core-dump-policy).

Run mode 1 (dedicated user) has more steps than mode 2, in this order:

1. Run `bash mayfly.sh preflight` and install the packages it prints, as above.
2. Place your WireGuard profile at `~/.local/state/mayfly/secrets/wireguard.conf` with mode `0600`, as in step 2 above, before you run the installer. The installer imports it for the `mayfly` user, and `sudo mayfly setup` stops with "the WireGuard profile is missing" without it.
3. Read `host/install-host.sh`, then run `sudo bash host/install-host.sh`. The installer creates the no-login `mayfly` user and `/var/lib/mayfly`, and copies the profile in. `sudo mayfly setup` doesn't create the user.
4. Run `sudo mayfly setup`, then `sudo mayfly launch --core-policy`. If `sudo` can't find `mayfly`, use `/usr/local/sbin/mayfly`.

See [DEPLOYMENT.md](DEPLOYMENT.md#10-run-as-a-dedicated-user-mode-1).

## Advanced

`setup` runs these commands in order. Run each one yourself if you want to:

```bash
# Check that your WireGuard profile is in the accepted format. It never prints the file.
bash mayfly.sh check-profile [--core-policy] [ABSOLUTE-PROFILE-FILE]

# Find the newest Debian image and Tor Browser, verify them, and write the pins file.
bash mayfly.sh fetch-pins [--yes] [--debian DATE-BUILD] [--tor X.Y.Z] [PINS-FILE]

# Build the base images from the pins file into a new, named base.
bash mayfly.sh build [PINS-FILE] [NAME]

# Check the host (memory, swap, crash dumps) without starting anything.
bash mayfly.sh doctor ABSOLUTE-RAM-DIRECTORY

# Start a session from the newest base, or from the named one.
# --attach FILE also gives the browser VM one text file to read (see below).
bash mayfly.sh launch [--attach FILE] [--core-policy] [NAME]

# Set, undo, or show the temporary crash-dump policy. It changes a host-wide setting.
bash mayfly.sh core-policy apply|restore|status
```

- `fetch-pins` finds the newest Debian trixie generic cloud image and the latest stable Tor Browser version, shows them, asks for confirmation, and writes the pins file only if every check passes. Debian publishes no detached signature, so trust in the image is HTTPS plus Debian's published `SHA512SUMS`. Tor Browser is verified against Tor's pinned signing key. Pass `--debian` and `--tor` to choose versions yourself. Versions are chosen automatically from upstream, so compare them with the official Debian and Tor Browser pages if you need to guard against a downgrade. `--yes` skips this review. [DEPLOYMENT.md](DEPLOYMENT.md#2-get-and-verify-downloads) lists the equivalent manual steps.
- `build` names the base `base-YYYYMMDD` unless you give a name (`base-YYYYMMDD-2` and so on if that name is taken), and never overwrites an existing base.
- The absolute-path forms still work and are what the dedicated-user wrapper uses: `build ABS-PINS ABS-NEW-BASE` and `launch ABS-BASE ABS-PROFILE [RAM-PARENT]`.
- [DEPLOYMENT.md](DEPLOYMENT.md#manual-and-advanced-steps) has the manual steps, host diagnostics, the leak test and troubleshooting.

### Copy a text file into the session

`launch --attach FILE` gives the browser VM one text file to read, without a clipboard bridge. Mayfly builds a tiny read-only disk image holding only that file and attaches it to the browser VM alone, as a CD-ROM. The guest mounts it read-only at `/mnt/transfer`. The transfer goes one way, from the host into the VM. The gateway VM gets no extra device, and the disk image lives in the session's RAM directory and is removed with it.

```bash
# Start a session and attach one text file. Run it in mode 2.
# Add --core-policy if your host needs it, as in the Quick start.
bash mayfly.sh launch --attach post.txt

# The same in the dedicated-user mode (mode 1).
sudo mayfly launch --core-policy --attach post.txt

# Then, inside the VM, open this address in the browser, select the text and copy it there:
# file:///mnt/transfer/post.txt
```

- The guest can read only that one file. Attach nothing you wouldn't disclose to the session: the browser, and anything you open in it, can read the text, and any site you paste it into receives it.
- The file must be a regular file that you own (not a symlink), from 1 byte to 1 MiB, with no NUL bytes. Mayfly reads it once and refuses anything else with a fixed message that never shows its content.
- The name in the VM is the file's name when it uses only letters, digits, `.`, `_` and `-`, is at most 64 characters, and doesn't start with `-` or `.`. Otherwise it's `transfer.txt`.
- The guest image carries the mount setup, so you need a base built from this version of Mayfly. Build a new base before you use `--attach`.
- An ISO tool (`genisoimage`, `mkisofs` or `xorriso`) is required, as for every launch.
- It has been tested live in run mode 1 in the Firefox entry. See [Tested](#tested).

**Keep the file off your disk.** Deleting a file doesn't reliably erase it from a modern disk. On SSDs and on copy-on-write filesystems such as btrfs, the old data can stay where it was, and tools such as `shred` don't help there. Full-disk encryption is your main protection. To avoid the problem, write the file in RAM, in `/dev/shm`, so it never reaches the disk:

```bash
# Make a private folder in RAM, then write your text there. Pick an editor that doesn't save backup files.
mkdir -m 700 /dev/shm/post && nano /dev/shm/post/post.txt

# Launch with the file attached. Add --core-policy if your host needs it.
sudo mayfly launch --core-policy --attach /dev/shm/post/post.txt

# Delete it when you're done. RAM files also vanish when the computer restarts.
rm -r /dev/shm/post
```

The file only has to be a regular file that you own, so a file in `/dev/shm` works. Check that your editor keeps no backup, swap or recent-file copies elsewhere.

## Tested

| What | Result |
|---|---|
| Offline suite, `bash tests/run.sh` (562 checks) | Passes inside distrobox containers of Debian 13, Ubuntu 24.04, Fedora 44, Arch and openSUSE Tumbleweed. |
| Live image build, boot and browsing | Verified on **one** host (Bazzite, Fedora family) only: Firefox over WireGuard, Tor Browser over Tor over WireGuard, and I2P. A bookmark made in one session was absent from the next. |
| Dedicated-user boundary (run mode 1) | Verified on that same host: the `mayfly` user owned the QEMU processes, `/var/lib/mayfly` was `root` mode `drwx--x--x`, and the `mayfly` user's profile and `/proc/<pid>/mem` of the VMs were denied to the desktop user. |
| `--core-policy`, apply and automatic restore (run mode 1) | On a host whose original setting was the `systemd-coredump` handler with `fs.suid_dumpable = 2`, `sudo mayfly launch --core-policy` set `/dev/null` and `0` for the session and restored the original values when the session closed. The same sequence ran in same-user mode (mode 2) with the same result: the same-user restore accepted that handler and `fs.suid_dumpable = 2`. |
| Firefox hardening policy and sandbox | `about:policies` in the Firefox entry lists the policies as active, and `about:support` shows a content process sandbox level of 6 (enabled). |
| Tor Browser security level | The level reads Standard, which is Tor Browser's default. Mayfly doesn't change it. |
| RAM-only writes (run mode 1) | While the session ran, `/dev/shm` grew from 65 MiB to 307 MiB after a large download and browsing, while `/` and `/var/home` changed by 5 MiB or less (other host activity). After the session ended, no `mayfly.*` directory remained in `/dev/shm`, and the only file the `mayfly` user had written on disk since the start was a small `dconf` cache file in its home directory. Browsing content wasn't looked for on disk beyond that file listing. |
| Leak test, all three entries (run mode 1) | Per-user packet counters on that host. After the Firefox, Tor Browser and I2P sessions, the `mayfly` user had sent 15,939 packets off the machine, and all 15,939 went to the WireGuard endpoint. The counters were cumulative, so each session added to the total and none added a packet elsewhere. No DNS, IPv6 or other traffic from the VMs was counted. One session per entry is not proof for every case. |
| Tunnel-down test (run mode 1) | With a profile whose endpoint port was wrong, no site loaded. The `mayfly` user sent 11 packets off the machine, all to that endpoint and port (WireGuard handshake retries). |
| Text transfer, `launch --attach` (run mode 1) | A text file attached with `sudo mayfly launch --core-policy --attach` could be opened in the guest browser at `file:///mnt/transfer/` and copied from there. Run mode 2, the Tor Browser and I2P entries, and hostile file names were not tested live. |
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

Mayfly for Windows 11 runs in WSL2 with `mayfly.ps1`. It is a different design from the Linux version, with a weaker isolation boundary. Read the [limits of the Windows variant](#limits-of-the-windows-variant) before you rely on it.

How it works:

- Setup downloads a Debian 13 root filesystem, checks its SHA-256 against the digest Debian publishes in the same repository, builds a small base distro called `mayfly` and imports it once with `wsl --import`. This is the base. Mayfly writes to it only during setup, rebuild and uninstall. WSL itself still updates files such as `/etc/hosts` and filesystem metadata when the distro starts.
- Each session mounts the base root as the read-only lower layer of an overlayfs. The upper layer, `/tmp`, the home directory and the Firefox profile are on tmpfs, in RAM. A bubblewrap sandbox uses that overlay as its root. Closing the browser unmounts the tmpfs and removes the session directory.
- WireGuard comes from the same strict profile parser as the Linux version (`lib/policy.sh`). The tunnel interface is moved into a private network namespace that holds only `lo` and `wg0`. The sandbox runs in that namespace, so the browser has no other IP route. The default-deny nft rules load inside the namespace before `wg0` comes up: only the browser user may send, only through `wg0`, DNS only to the tunnel resolver, special-use addresses refused, and IPv6 off. WSL2 distros share one network namespace, so the rules cannot go in the distro itself without cutting off your other distros.
- `/etc/wsl.conf` in the base distro turns off Windows drive automount, interop and the Windows `PATH`.
- Firefox uses the same hardening policy file as the Linux version. The I2P entry reuses the Linux configuration. Setup also installs Tor Browser, checked against the same pinned Tor signing key as the Linux build (`lib/pins.sh`), and the Tor entry runs it in the same sandbox and namespace, so Tor runs over WireGuard.
- Firefox shows its window through WSLg over X11. Wayland froze Firefox on the one machine tested (Windows 11 build 26300), so the sandbox forces X11. The sandbox gets the WSLg X11 socket only, not the Wayland or audio sockets (so no sound).

### Requirements for Windows

- Windows 11 with a current WSL (`wsl --update`) and WSLg. Tested with WSL 2.7.8.0 only, and the launcher reads the English output of `wsl --version`.
- Swap off. WSL swap is global to every distro and is set in `%UserProfile%\.wslconfig`. Mayfly refuses to start while `/proc/swaps` has an entry. Put this in the file, then run `wsl --shutdown`:

```ini
[wsl2]
swap=0
```

- A WireGuard profile in the [accepted format](#wireguard-profile-format) with exactly one `DNS` address. If your provider lists two, keep the first.

### Windows quick start

Run these in PowerShell from the Mayfly folder. Use a local drive. If PowerShell says running scripts is disabled, run `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` first (it affects only that window), and if you downloaded a ZIP, run `Get-ChildItem -Recurse | Unblock-File` once. The steps in [DEPLOYMENT.md](DEPLOYMENT.md#windows-and-wsl2) cover the same ground in more detail.

```powershell
# Check Windows and WSL. It changes nothing and prints the fix for anything missing.
.\mayfly.ps1 preflight

# Download and verify the rootfs, build the base distro and import it (several minutes).
.\mayfly.ps1 setup

# Copy your profile into the owner-only secrets folder, then check its format. It never prints the file.
Copy-Item C:\path\to\provider.conf "$env:LOCALAPPDATA\mayfly\secrets\wireguard.conf"
.\mayfly.ps1 check-profile

# Start a session. Close the browser to end it.
.\mayfly.ps1 launch
```

Other commands: `launch` asks which browser to start (Firefox, I2P or Tor Browser), `launch -Entry firefox|i2p|tor` skips the question, `cleanup` removes stale session mounts and stops the base distro, `setup -Rebuild` rebuilds the base after you update Mayfly, and `uninstall` unregisters the distro and deletes the downloaded and built files. State lives in `%LOCALAPPDATA%\mayfly`. The `secrets` and `pins` folders are owner-only. The rest keeps the default permissions because the WSL service can't create the distro disk in an owner-only folder. `uninstall` leaves `secrets` in place.

### Limits of the Windows variant

- **Weaker isolation than the Linux version.** Every WSL2 distro runs in one shared utility VM with one Linux kernel. Linux Mayfly puts the browser in its own VM. Here a kernel or sandbox escape reaches the shared VM and your other distros.
- **RAM-only only while swap is off.** Session writes avoid the distro disk (`ext4.vhdx`) only while the VM has no swap. Mayfly checks `/proc/swaps` at launch, but nothing stops you from turning swap on later.
- **Windows controls the VM's memory.** Windows can page the WSL VM's memory to its own page file, and hibernation and crash dumps can capture it. Mayfly has no control over any of these. On the machine tested, hibernation was available (`hiberfil.sys` present), the page file was system-managed at about 9.7 GB and not cleared at shutdown, and crash dumps were set to automatic. That is exposure only. Whether session data reaches any of them was not tested, because those files can't be read while Windows runs.
- **Mount metadata on disk.** The base mount is read-only, but the ext4 journal may still record metadata about mounting it.
- **A shared clipboard.** WSLg shares the clipboard with Windows in both directions, and the sandbox does not block it (tested). Anything you copy in a session reaches Windows, and anything on your Windows clipboard can be read by the browser.
- **You must trust the host.** Windows, the WSL service and anything with access to your account can read the session, the profile in `%LOCALAPPDATA%\mayfly\secrets`, and the VM's memory.
- **The Windows driver store is visible read-only in the distro.** WSL mounts `/usr/lib/wsl/drivers` (the Windows driver store) in the distro. The sandbox root doesn't include it.
- **The WSLInterop entry stays registered.** WSL keeps a `WSLInterop` binfmt entry registered VM-wide even when a distro disables interop. Mayfly checks `wsl.conf`, the `PATH` and the environment, and doesn't treat that entry as proof either way.
- **The X server has no authentication.** WSLg's X server has no authentication. A compromised browser could read other WSLg windows and the clipboard, and send input to them. Keep other WSLg windows closed during a session. Mayfly does not run a separate X server per session.
- **Other channels may lead out of the sandbox.** The sandbox keeps the WSLg X11 socket and has no seccomp filter. Mayfly does not restrict VM sockets (AF_VSOCK), which are not part of a network namespace. Whether a browser exploit could use them is unverified.
- **The tunnel's own traffic is not filtered.** The encrypted WireGuard UDP leaves the namespace through the shared WSL network, as any WSL traffic does. Mayfly doesn't filter it there.

### Windows: tested and unverified

Live-tested on **one** machine: Windows 11 (build 26300), WSL 2.7.8.0, WSLg 1.0.73.2, kernel 6.18.33.1.

| What | Result |
|---|---|
| Offline suite, `bash tests/run.sh` (562 checks) | Unchanged. Passes in a Debian 13 distro. The Linux files weren't edited. |
| `bash tests/wsl-tests.sh` (49 to 50 checks, depending on whether `nft --check` can run) and Pester `tests\wsl` (17 checks) | Pass. They check rule text, the preflight predicates, the profile parser path, and the launcher guards. They don't start a session. |
| Setup, preflight, check-profile and launch | Worked. The base distro built and imported, and Firefox opened through WSLg. |
| Swap | With `swap=0` in `.wslconfig` and a `wsl --shutdown`, `/proc/swaps` was empty. The sandbox saw no swap. |
| Sandbox | Firefox ran as `browser` (uid 1000) with no capabilities and `NoNewPrivs` set. Its network namespace held only `lo` and `wg0`. `/tmp`, the home directory and `/` were tmpfs or overlay on tmpfs. No Windows drive was visible. |
| WireGuard (kernel module) | With a synthetic local server: DNS queries from Firefox reached the tunnel resolver through `wg0`. With a real provider profile: a handshake and several MiB of traffic received. |
| Kill switch | With a synthetic server: a UDP packet to another resolver on port 53 was refused. With `wg0` down, nothing reached the server and the default route disappeared. |
| Disk writes | After sessions that held a throwaway private key and a marker string, a byte scan of `ext4.vhdx` found neither. The same scan found a marker written to the base on purpose. |
| MTU | On this machine the WSL uplink MTU was 1280. With the tunnel at 1420, TLS handshakes stalled while DNS and TCP connects worked. At 1220, HTTPS requests succeeded. The launcher now sets the tunnel MTU from the uplink. |
| Entries | Firefox loaded HTTPS pages (after the MTU fix). I2P opened an eepsite (`stats.i2p`, `200 OK` through the local proxy; a clearnet name was refused as designed). Tor Browser started with its `tor` process inside the sandbox. |
| Uplink capture, Firefox entry | With a real provider profile, a capture of the WSL uplink (`eth0`) from another distro during one browsing session held 57,361 packets. 57,339 were UDP to and from the profile's endpoint. The rest were ARP, host multicast discovery that also appeared in a no-session baseline, and 6 NTP packets from the VM's own address (most likely another distro's time sync). No DNS, TCP, ICMP or IPv6 left the machine. This shows nothing about traffic inside the tunnel. |
| Uplink capture, I2P entry | Same method, on the same machine, during one I2P session with eepsites loading. 4,076 packets: 3,953 were UDP to and from the profile's endpoint. No TCP, DNS or sandbox IPv6. The rest were host multicast discovery, NTP from the VM's address about every 34 seconds, and 4 ICMP port-unreachable replies to the endpoint about the previous session's closed port. |
| Uplink capture, Tor entry | Same method, same machine, one Tor Browser session that browsed normally. 26,869 packets: 26,628 were UDP to and from the profile's endpoint on the session's port, plus 64 on the previous session's closed port. One short TCP flow to `motd.ubuntu.com` came from the other distro's own `motd-news` timer (its journal shows it starting at the same second), not from the session. Host multicast discovery and NTP appeared as before. No DNS and no sandbox IPv6. ``check.torproject.org`` confirmed Tor in the browser. |
| DNS, IPv6 and tunnel down, Firefox entry | In one Firefox session with a real provider profile: a DNS leak test site (`browserleaks.com/dns`) listed the provider's addresses, and `test-ipv6.com` reported no IPv6. With `wg0` brought down inside the session namespace, a loaded page no longer loaded, the namespace had no route, and the capture of the shared uplink (25,566 packets, mostly UDP to the endpoint) showed no sandbox traffic to any other address. After that the tunnel and default route were restored by hand and the session worked again. The only TCP in the capture was a 4-second burst to Canonical addresses within 3 seconds of the capture starting, before the session started: the other distro's boot-time update checks, identified by timing and addresses, not by process. |
| Wrong endpoint port, Firefox entry | With a copy of the real profile whose endpoint port was changed to one that does not answer: Firefox opened and no page loaded. The first 70 seconds of the capture held 29 packets. The sandbox sent only 7 WireGuard handshake attempts to the wrong port, answered by 7 ICMP port-unreachable replies. One stray 32-byte packet came from the previous session's tunnel closing. No DNS, TCP, IPv6 or other address. |
| Clearnet in the I2P entry | In one I2P session, `.i2p` sites loaded and clearnet sites (including a DNS test site and an IPv6 test site) could not be found, as designed (no outproxy). A packet capture of the same entry earlier showed no DNS or sandbox IPv6 leaving the machine. |
| DNS and IPv6, Tor entry | In one Tor Browser session: `check.torproject.org` said Tor and showed an address that Tor's public exit list contains (a Netherlands exit). A DNS leak test listed resolvers in Stockholm, not the provider's. `test-ipv6.com` showed an IPv6 address that Tor's relay data (Onionoo) lists as the OR address of four running exit relays, so it was an exit, not the machine (Tor Browser uses a separate circuit per site, so it differed from the exit ``check.torproject.org`` saw). The session's namespace held only `lo` and `wg0`, with no IPv6 address or route, IPv6 disabled and the IPv6 drop rules loaded, so the sandbox has no IPv6 of its own to leak. |
| `wireguard-go` (forced) | With `MF_WSL_USERSPACE=1` on a machine that also has the kernel module, one Firefox session: the tunnel came up and DNS and TCP connects worked, but HTTPS stalled at tunnel MTU 1220. `wireguard-go` needs 80 bytes of overhead, not 60. At 1200, HTTPS to three sites succeeded (3 of 3, 3 of 3, 2 of 3 attempts), and the launcher now uses 80 for this path. Only the Firefox entry was tried, checked with curl from inside the sandbox. |
| Clipboard | In a Firefox session, a marker text put on the Windows clipboard pasted into Firefox's address bar, and text copied in Firefox appeared on the Windows clipboard. WSLg shares the clipboard in both directions, and the sandbox does not block it. |
| Cleanup | After each session the launcher exited 0, the distro stopped, and no session mount or `mfw` interface remained. |

**Unverified:**

- The leak test for Windows with any provider other than the one tested. See the [leak test for Windows](DEPLOYMENT.md#windows-and-wsl2).
- `wireguard-go` on a machine that has no WireGuard kernel module. It was forced on a machine that has one (`MF_WSL_USERSPACE=1`).
- Tor circuit details. Tor Browser loaded sites and `check.torproject.org` confirmed Tor, and nothing more was checked.
- Windows 10, other Windows or WSL builds, WSL mirrored networking, and a distro that already holds a Windows drive mount.
- Whether Windows pages, hibernates or dumps the WSL VM's memory in practice, and what the ext4 journal records.
- A real tunnel outage in the middle of a session (the endpoint going silent). Bringing `wg0` down by hand and a wrong endpoint port were tested. Also a `wsl --shutdown` during a session.
- A non-English Windows. The version checks match English text.

## Reference

### Commands

```text
# Check the host and print the install command for anything missing. Changes nothing.
bash mayfly.sh preflight

# Run the whole first-time setup: profile check, downloads, and base build.
bash mayfly.sh setup [--core-policy] [--yes]

# Download and verify Debian and Tor Browser, and write the pins file.
bash mayfly.sh fetch-pins [--yes] [--debian DATE-BUILD] [--tor X.Y.Z] [PINS-FILE]

# Build the base images. NAME is a short name in the state directory.
bash mayfly.sh build [PINS-FILE] [NAME | NEW-BASE-DIRECTORY]

# Start a session from the newest base, or from the named one.
# --attach FILE gives the browser VM one text file to read.
bash mayfly.sh launch [--attach FILE] [--core-policy] [NAME]

# Check a WireGuard profile without printing it. The default is the profile in the state directory.
bash mayfly.sh check-profile [--core-policy] [PROFILE-FILE]

# Apply, restore, or show the temporary crash-dump policy.
bash mayfly.sh core-policy apply|restore|status

# Check the host's memory, swap and crash-dump settings. Takes an absolute path in RAM, such as /dev/shm.
bash mayfly.sh doctor ABSOLUTE-RAM-DIRECTORY

# The same build and launch with full paths. The dedicated-user wrapper uses these forms.
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

Run mode 1 uses `sudo mayfly setup`, `fetch-pins`, `doctor`, `check-profile [--core-policy]`, `build [NAME]`, `launch [--attach FILE] [--core-policy] [--diag] [--display wayland-N] [NAME]`, `core-policy`, `status`, `stop` and `cleanup`. See [DEPLOYMENT.md](DEPLOYMENT.md#10-run-as-a-dedicated-user-mode-1).

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
