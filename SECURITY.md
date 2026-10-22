# Security policy

Mayfly is experimental (v0.1.0). Read [What Mayfly does not protect against](README.md#what-mayfly-does-not-protect-against) before you rely on it.

## Report a vulnerability

Use GitHub's private vulnerability reporting for this repository:

1. Open the [Security tab of stschulznz/mayfly](https://github.com/stschulznz/mayfly/security).
2. Select **Report a vulnerability**.
3. Describe the problem, the affected file or command, and the steps to reproduce it.

Don't open a public issue or pull request for a vulnerability, and don't post it anywhere public before a fix exists. This project doesn't take reports by email. Private vulnerability reporting must be enabled in the repository settings for the **Report a vulnerability** button to appear.

Don't include real WireGuard profiles, keys, endpoints, browsing data or packet captures in a report. Use the synthetic fixtures in `tests/fixtures`, or describe the shape of the data.

Mayfly has a single maintainer, so response times vary. Expect an acknowledgement in the report thread, followed by a fix or a decision on the report in the same place.

## Supported versions

Only the latest commit on `main` is supported. Fixes aren't backported. Rebuild your bases after you update, because the guest scripts are baked into the images.

## Scope

These are in scope:

- The launcher and CLI: `mayfly.sh` and `lib/*.sh`.
- The dedicated-user installer and wrapper: `host/install-host.sh` and `host/mayfly-wrapper.sh`.
- The guest scripts and policies in `guest/`, including the gateway's nftables rules.
- A way for session traffic to reach the network outside the WireGuard tunnel, other than the browser-level exceptions below.
- A way for a program running as your desktop user to read the VMs' memory, the profile or the bases in run mode 1.
- A way to read or leak the WireGuard profile or keys.
- A way for guest code to reach the host beyond the one shared Wayland socket.
- Download verification: the pins file parser and the build's checks.

## Not a vulnerability

The README lists the known limits. These reports aren't vulnerabilities:

- Anything that needs a compromised host, kernel, hypervisor or firmware.
- Anything that needs code running as your desktop user, in run modes 2 and 3. Those modes don't claim to stop it.
- Capturing your `sudo` password in run mode 1.
- Browser fingerprinting, account correlation, or a VPN provider seeing your traffic.
- Code that controls the browser reaching the internet through the tunnel, including in the I2P entry. The "eepsites only" rule is a browser property, not a network one.
- Tor, I2P, Firefox, Debian or libguestfs vulnerabilities. Report those upstream. A Mayfly-specific way to trigger one is in scope.
- The unverified items listed under [Tested](README.md#tested). Evidence that one of them fails is welcome, so report it as a normal issue, or privately if it affects security.
- A base that is out of date because you haven't rebuilt it.
