# Deploy Mayfly

This guide takes you from a fresh host to a first browsing session. The [Quick path](#quick-path) is the short version. Everything after it is the manual and advanced detail: run mode 2 (same user, native host) in steps 1 to 9, then run mode 1 (dedicated service user) in step 10, which is the strongest mode. Steps 11 to 13 cover rebuilding bases, the leak test and troubleshooting. See the [README](README.md#run-modes) for what each mode protects and what it doesn't.

Mayfly is experimental. Live testing covers one host (Bazzite), and the commands here haven't been run on other distributions. See [Tested](README.md#tested).

## Quick path

Run mode 2, as your normal user in a desktop terminal on a native Wayland session:

```bash
bash mayfly.sh preflight
(umask 077; mkdir -p ~/.local/state/mayfly/secrets) && install -m 600 /path/to/provider.conf ~/.local/state/mayfly/secrets/wireguard.conf
bash mayfly.sh setup --core-policy
bash mayfly.sh launch --core-policy
```

- `preflight` changes nothing. Run the install command it prints, then run it again until it says `Ready for the next step`. On Fedora Atomic systems such as Bazzite that means a reboot, which is your decision.
- The state directory is `$MAYFLY_HOME`, else `$XDG_STATE_HOME/mayfly`, else `~/.local/state/mayfly`. It and its subdirectories (`pins`, `bases`, `secrets`, `downloads`) must be yours with mode `0700`, and Mayfly refuses symlinks and loose modes instead of repairing them. Without the profile, `setup` creates the directories, prints where the file goes and exits `0`. Run it again after you place the file. It never reads or prints the profile at that point.
- `setup` runs, in order: preflight, state directories, profile check, `fetch-pins`, `build`. It skips each finished step with an `already done` line, so you can run it again. `fetch-pins` shows the exact Debian and Tor Browser versions and URLs and asks `Continue? [y/N]`. Add `--yes` to accept without the prompt. Versions are chosen automatically from upstream, so compare them with the official [Debian](https://cloud.debian.org/images/cloud/trixie/) and [Tor Browser](https://www.torproject.org/download/) pages if you need to guard against a downgrade. `--yes` skips this review. It refuses to run without a terminal and without `--yes`.
- Debian publishes no detached signature for its cloud images. The Debian download is trusted on HTTPS plus Debian's published `SHA512SUMS`. Tor Browser is verified with `gpgv` against Tor's pinned signing key, fingerprint `EF6E286DDA85EA2A4BA7DE684E2C6E8793298290`. The pins file is written, mode `0600`, only if every check passes.
- `--core-policy` applies the [temporary core-dump policy](#9-temporary-core-dump-policy) only when the host doesn't already meet it. It asks `sudo` for `sysctl`, because it changes crash-dump behaviour for the whole host, and restores the saved values on exit only if it applied them and no QEMU process runs. In `setup` it covers the profile check only. Without the flag, `setup` stops with the remedy if the host blocks the check.
- `launch` starts the newest base with the default profile. Close other work and don't hibernate until every session ends.

Run mode 1 (dedicated `mayfly` user), after the packages are installed and the profile is at the default path:

```bash
sudo bash host/install-host.sh
sudo mayfly setup
sudo mayfly launch --core-policy
```

The installer uses `~/.local/state/mayfly/secrets/wireguard.conf` and `pins/build.pins` from the user who ran `sudo`, if they exist, through its safe-read path. Pass `--profile` or `--pins` to use other files. [Step 10](#10-run-as-a-dedicated-user-mode-1) explains what it installs, and you should review it before you run it.

## Manual and advanced steps

The numbered steps below do the same work by hand, with the downloads and core-dump policy spelled out. Use them to verify what the commands above do, to choose your own paths, or when something fails.

Conventions:

- Run each block in a desktop terminal, in a Wayland session, as your normal user. Don't run the launcher with `sudo`, except where step 10 says to.
- Run one block at a time and read its output before you continue. Blocks that change files use a subshell with `set -euo pipefail`, so an error stops that block and not your terminal.
- Don't enable `set -x` or record a terminal session while you handle your WireGuard profile.
- Run commands from the directory that contains `mayfly.sh`.
- Paths you pass to Mayfly must be absolute and must contain only letters, digits, `_`, `.`, `/` and `-`, with no symlink components. Some hosts alias `/home` to `/var/home`, so use `realpath -e` to get the real path.

Set these variables once per terminal. They're only a convenience for this guide. Choose a state directory outside the source checkout:

```bash
set +x
umask 077
export MF_STATE="$HOME/.local/state/mayfly"
mkdir -p -m 700 -- "$MF_STATE"/{downloads,pins,secrets,bases,core-policy}
MF_STATE=$(realpath -e -- "$MF_STATE")
echo "$MF_STATE"
```

Expected: a path made of allowed characters, owned by you with mode `0700`. If the path contains other characters, choose a different state directory.

## 1. Check the host and install packages

Run the offline checks first. They need no KVM, network, credentials or `sudo`:

```bash
find . -type f -name '*.sh' -exec bash -n {} \;
bash tests/run.sh
```

Expected: no syntax errors, and the last line reports `505 passed, 0 failed`. These checks don't boot a VM or prove routing.

Then run preflight. It changes nothing:

```bash
bash mayfly.sh preflight
```

Preflight lists missing tools, checks `/dev/kvm`, the Wayland session, available memory and a readable kernel image, and prints the exact install command for your system. Run that command, then run preflight again until it prints `Ready for the next step`. A `WARNING` line doesn't fail preflight, but fix it before you build or launch.

On Fedora Atomic systems such as Bazzite, preflight prints an `rpm-ostree install` command. The new packages usually take effect after a reboot. Reboot when it suits you, then open a new terminal. Mayfly never reboots your system. Follow the [Fedora Atomic Desktop layering guidance](https://docs.fedoraproject.org/en-US/atomic-desktops/getting-started/#package-layering) for that model.

The package names come from `mf_pkg_for` in [`lib/preflight.sh`](lib/preflight.sh). The [README](README.md#install-packages) lists them per distribution.

For each distribution, check these hazards now:

- **Ubuntu: kernel images unreadable.** Building bases uses libguestfs, which needs a readable kernel image. Ubuntu installs `/boot/vmlinuz-*` as `0600`. Preflight warns about it. Fix it with:

  ```bash
  sudo chmod 0644 /boot/vmlinuz-*
  ```

  A kernel update can reset the mode, so repeat it before you rebuild.
- **`/dev/kvm` access.** On Debian, Ubuntu and Arch, `/dev/kvm` is usually `root:kvm` mode `0660`, so your user needs the `kvm` group. Fedora and Bazzite make it world-accessible. In mode 1 the installer grants the group to the `mayfly` user for you. For modes 2 and 3, check `ls -l /dev/kvm` and `id`, and add your account to the owning group by following your distribution's documentation. Log in again afterwards.
- **Piped core handlers.** Many hosts pipe core dumps to a collector such as `apport` or `systemd-coredump`, depending on the distribution. `doctor` and `check-profile` refuse such hosts until you apply the [temporary core-dump policy](#9-temporary-core-dump-policy). Apply it before step 4 if `sysctl kernel.core_pattern` starts with `|`.
- **Distrobox.** Inside a distrobox container, host root appears as `nobody`. Mayfly accepts that.

## 2. Get and verify downloads

A base is built from two downloads: a Debian 13 cloud image and the Tor Browser archive. You pin both by SHA-256 in a pins file. Build checks the pins, but a locally computed digest alone doesn't authenticate a download, so verify the downloads first.

`bash mayfly.sh fetch-pins [--yes] [--debian DATE-BUILD] [--tor X.Y.Z] [PINS-FILE]` automates this step. It finds the newest `YYYYMMDD-N` directory in the Debian index and the latest stable version in Tor's `downloads.json` (only numeric versions, so alpha and rc strings are refused), shows both with their URLs, and applies the same checks as the block below. It writes the pins file only if every check passes, and leaves no pins file when one fails. The manual block remains the reference for what is checked.

Keep the pins file and everything you download outside Git. The pins file is literal `key=value` data, never shell. See the [pins file reference](README.md#pins-file).

1. Pick a versioned directory from the [Debian trixie cloud image index](https://cloud.debian.org/images/cloud/trixie/). Choose `debian-13-generic-amd64-<build>.qcow2`, not `genericcloud`, `nocloud` or a moving `latest` or `daily` URL. The desktop build needs the generic variant, because `genericcloud` has fewer kernel drivers.
2. Pick the stable Linux x86-64 Tor Browser version from the [Tor Browser download page](https://www.torproject.org/download/). Use a numeric stable version, not an alpha. The [archive index](https://dist.torproject.org/torbrowser/) also lists prereleases.

Debian's directory publishes `SHA512SUMS` but no detached signature, so this route trusts HTTPS plus Debian's published checksum, not signed provenance. If you need signed provenance and your release doesn't supply it, stop. `cloud.debian.org` redirects to a mirror, so the checksum gives you integrity relative to that file only. The Tor archive is verified against Tor's pinned primary signing key, fingerprint `EF6E286DDA85EA2A4BA7DE684E2C6E8793298290`. See the [Tor Browser verification instructions](https://support.torproject.org/tor-browser/getting-started/verifying-tor-browser/). The downloads expose your IP address to the redirect host.

This block downloads both files, verifies them, and writes the pins file only if both checks pass. It follows at most three redirects, and only over HTTPS:

```bash
(
  set -euo pipefail
  pins="$MF_STATE/pins/build.pins"
  [[ ! -e $pins && ! -L $pins ]]
  read -r -p 'Debian version directory (date-build): ' versiondir
  read -r -p 'Debian build identifier from the generic amd64 filename: ' build
  read -r -p 'Stable Tor Browser version from the download page: ' torversion
  [[ $versiondir =~ ^[0-9]{8}-[0-9]+$ && $build =~ ^[0-9]{8}-[0-9]+$ ]]
  [[ $torversion =~ ^[0-9]+(\.[0-9]+)+$ ]]
  image="debian-13-generic-amd64-$build.qcow2"
  archive="tor-browser-linux-x86_64-$torversion.tar.xz"
  image_dir="https://cloud.debian.org/images/cloud/trixie/$versiondir"
  tor_url="https://dist.torproject.org/torbrowser/$torversion/$archive"
  fingerprint=EF6E286DDA85EA2A4BA7DE684E2C6E8793298290
  work=$(mktemp -d "$MF_STATE/downloads/verified.XXXXXXXX")
  cd -- "$work"
  fetch() { curl --fail --show-error --location --max-redirs 3 \
    --proto '=https' --proto-redir '=https' --tlsv1.2 --output "$1" "$2"; }
  fetch "$image" "$image_dir/$image"
  fetch SHA512SUMS "$image_dir/SHA512SUMS"
  expected=$(awk -v name="$image" '
    NF == 2 && ($2 == name || $2 == "*" name) {count++; digest=$1}
    END {if (count != 1) exit 1; print digest}' SHA512SUMS)
  [[ $expected =~ ^[a-fA-F0-9]{128}$ ]]
  printf '%s  %s\n' "$expected" "$image" | sha512sum --check --strict -
  fetch "$archive" "$tor_url"
  fetch "$archive.asc" "$tor_url.asc"
  mkdir -m 700 gnupg
  fetch tor-key.asc "https://keys.openpgp.org/vks/v1/by-fingerprint/$fingerprint"
  gpg --batch --homedir gnupg --import tor-key.asc
  actual=$(gpg --batch --homedir gnupg --with-colons --fingerprint "$fingerprint" |
    awk -F: '$1 == "fpr" {print $10; exit}')
  [[ $actual == "$fingerprint" ]]
  gpg --batch --homedir gnupg --output tor-keyring.gpg --export "$fingerprint"
  gpgv --homedir gnupg --keyring "$PWD/tor-keyring.gpg" "$archive.asc" "$archive"
  image_sha=$(sha256sum -- "$image"); image_sha=${image_sha%% *}
  tor_sha=$(sha256sum -- "$archive"); tor_sha=${tor_sha%% *}
  (set -o noclobber
    printf 'IMAGE_URL=%s\nIMAGE_SHA256=%s\nTOR_URL=%s\nTOR_SHA256=%s\n' \
      "$image_dir/$image" "$image_sha" "$tor_url" "$tor_sha" > "$pins")
  chmod 600 -- "$pins"
  printf 'Verified at %s in %s\n' "$(date -u +%FT%TZ)" "$work"
)
```

Expected: `sha512sum` reports `OK` for the image, `gpgv` reports a good signature and exits `0`, and `build.pins` contains exactly four fields. If a release renames artifacts or a check fails, stop. Don't pick another variant or weaken the checks. If `build.pins` already exists, use it only with its recorded provenance, or start a new state directory.

## 3. Build the bases

Building is a network-enabled maintenance step. It downloads the pinned artifacts again, checks the pins, rechecks Tor's signature, installs guest packages, and writes two bases. It never takes a VPN profile. Don't browse or put personal data into a base.

```bash
(
  set -euo pipefail
  base="$MF_STATE/bases/base-01"
  [[ ! -e $base && ! -L $base ]]
  LIBGUESTFS_BACKEND=direct bash mayfly.sh build "$MF_STATE/pins/build.pins" "$base"
  sha256sum -- "$base/gateway.qcow2" "$base/browser.qcow2" > "$MF_STATE/bases-before.sha256"
)
```

The destination must not exist. Its parent must be yours with mode `0700` and outside the source repository. `bash mayfly.sh build` with no arguments does this with the state-directory pins and a new `base-YYYYMMDD` name, and refuses to overwrite an existing base. The build can take several minutes. It uses libguestfs's direct backend. The [`virt-customize`](https://github.com/libguestfs/guestfs-tools/blob/master/customize/virt-customize.pod) and [`virt-resize`](https://github.com/libguestfs/guestfs-tools/blob/master/resize/virt-resize.pod) documentation owns those tools' behavior, and the build sequence is in [`lib/build.sh`](lib/build.sh).

Expected: `Build finished`, and `base-01` contains `gateway.qcow2` and `browser.qcow2`, each 16 GiB virtual, mode `0444`, with a `.sha256` file. Hashes are published last. A nonzero exit means **don't launch**, even if some output files exist. A failed build leaves partial nonsecret artifacts for diagnosis. Retry with a new destination name, and never edit a base or write a hash file by hand.

Read-only permissions and local hashes detect accidental changes. They don't protect against a compromised host user who can replace both.

## 4. Provide the WireGuard profile

Get a profile privately from your provider. Never paste it, its keys or its endpoint into an issue, chat or transcript. Mayfly supports a restricted format, described in the [README](README.md#wireguard-profile-format): one `[Interface]` with an IPv4 `/32` address and one numeric IPv4 `DNS`, and one `[Peer]` with `AllowedIPs = 0.0.0.0/0` and a numeric IPv4 endpoint. A provider's `wg-quick` file may need changes that Mayfly can't make for you. If the parser rejects a field, it reports the field name and a fixed message, not the value.

If `sysctl kernel.core_pattern` starts with `|`, apply the [core-dump policy](#9-temporary-core-dump-policy) now. The profile check refuses piped collectors.

Copy the file into your private state directory without printing it:

```bash
(
  set -euo pipefail
  read -r -p 'Path to your WireGuard profile (not its contents): ' input
  source_profile=$(realpath -e -- "$input")
  dest="$MF_STATE/secrets/wireguard.conf"
  [[ -f $source_profile && ! -e $dest && ! -L $dest ]]
  install -m 600 -- "$source_profile" "$dest"
)
```

Your original file and this copy both stay on disk. Mayfly makes no secure-deletion claim. The default path is what `check-profile`, `launch` and `setup` use when you give no path.

## 5. Check the profile and run doctor

```bash
bash mayfly.sh check-profile "$MF_STATE/secrets/wireguard.conf"
```

Expected: `Profile syntax accepted. No keys printed, VM started or live route verified.` This checks syntax and file metadata only. It doesn't contact the provider or prove the keys work.

Now run `doctor` against a private scratch directory on `/dev/shm`, not `/dev/shm` itself:

```bash
(
  set -euo pipefail
  scratch=$(mktemp -d /dev/shm/mayfly-check.XXXXXXXX)
  status=0
  bash mayfly.sh doctor "$scratch" || status=$?
  rmdir -- "$scratch"
  exit "$status"
)
```

Expected: exit `0`. A refused host exits `78` and prints which condition failed. `doctor` checks prerequisites only. It installs nothing, changes no host policy, starts no VM and never tests live routing. See the [host checks](README.md#memory-and-host-checks). If it refuses, see [Troubleshooting](#13-troubleshooting) and don't bypass the guard.

## 6. Launch a session

Launch in the foreground, as your desktop user:

```bash
bash mayfly.sh launch "$MF_STATE/bases/base-01" "$MF_STATE/secrets/wireguard.conf" /dev/shm
```

`bash mayfly.sh launch` with no arguments does the same with the newest base in the state directory and the default profile. `launch NAME` picks a named base.

The gateway VM starts first, and the browser VM starts after the gateway's private socket appears. A socket is not a VPN handshake or a route check. A chooser window then lists the three entries. Pick one. Only one entry runs per session, so close the browser and launch again to switch.

To check which route an entry uses, open `https://check.torproject.org/api/ip` in the VM. Firefox should report your VPN's egress address and `IsTor: false`. Tor Browser should report `IsTor: true`. An address difference alone doesn't prove the VPN path, and these checks don't prove that DNS, IPv6 or fallback traffic is absent. That proof needs a leak test. See [step 12](#12-leak-test-check-that-nothing-leaves-outside-the-tunnel). The test exposes your egress to that site, so use no accounts.

The I2P entry shows a progress window while the router joins the network, which usually takes a few minutes. Type `http://` before `.i2p` names. If joining never finishes, suspect the guest clock first. See the [I2P limits](README.md#the-i2p-entry).

## 7. End sessions

Close the browser, or cancel the chooser, to power the guest off. Pressing Ctrl+C in the launcher terminal also ends the session. Wait for the launcher to return. Cleanup stops the session's VMs and removes only that session's RAM directory. The supervisor stops the browser VM if the gateway exits, and the gateway when the browser VM ends. It doesn't restart guests or resume old overlays.

Check that nothing is left:

```bash
pgrep -u "$UID" -af '[q]emu-system-' || test "$?" -eq 1
find /dev/shm -maxdepth 1 -type d -uid "$UID" -name 'mayfly.*' -printf '%m %u %p\n'
sha256sum --check --strict "$MF_STATE/bases-before.sha256"
```

Expected: no QEMU process or `mayfly.*` directory from your session, and both base hashes report `OK`. Other workloads may match these patterns, so name matches are leads, not permission to signal or delete.

If you close the terminal forcibly, send `SIGKILL` to the launcher, or the host fails, VMs or RAM files can remain. No stale-session recovery command exists for modes 2 and 3. Identify the exact orphaned processes, with their full command line, parent, start time and RAM path. Then stop each one:

```bash
(
  set -euo pipefail
  read -r -p 'Exact PID of a QEMU process you identified as yours: ' pid
  [[ $pid =~ ^[1-9][0-9]*$ ]]
  ps -p "$pid" -o uid,pid,ppid,lstart,args
  read -r -p 'Owner, start time and arguments rechecked? Type TERM: ' answer
  if [[ $answer == TERM ]]; then kill -TERM -- "$pid"; fi
)
```

Don't use `pkill`, `killall` or `rm -rf` on shared directories such as `/dev/shm`. Keep the restricted core policy until every VM is gone.

Under memory pressure the host may stop a VM or the launcher. Keep headroom and close other memory-heavy work. There is no downloads export: downloads, bookmarks and changes are lost with the session, and you shouldn't add a shared disk or reuse an overlay as a workaround.

## 8. Diagnose a failed launch

For `doctor` refusals, run these read-only checks and review the output privately, because it can identify your host:

```bash
awk '/MemAvailable:/ {print}' /proc/meminfo
findmnt --target /dev/shm --output TARGET,FSTYPE,OPTIONS,SIZE,AVAIL
cat /proc/swaps
for backing in /sys/block/zram*/backing_dev; do
  if [[ -r $backing ]]; then printf '%s: ' "$backing"; cat "$backing"; fi
done
cat /sys/power/resume /sys/power/resume_offset
cat /sys/kernel/kexec_crash_loaded /sys/kernel/kexec_crash_size
cat /proc/cmdline
sysctl kernel.core_pattern fs.suid_dumpable
stat -c '%A %U %G %n' /dev/kvm
```

For memory or tmpfs pressure, close other work and run `doctor` again. For disk swap, zram writeback, a configured resume device or a loaded crash kernel, resolve the host setting with its impact in mind. Don't run a blanket `swapoff`, remove resume arguments or unload crash support just to pass the check.

A blank guest window or a socket timeout doesn't diagnose networking. By default the launcher discards QEMU's output. For a nonsensitive test session, set `MAYFLY_DIAG=1` on the launch command. The gateway and browser VMs then write counters to `gateway-diag.log` and `browser-diag.log` in that session's private `0700` RAM directory:

```bash
MAYFLY_DIAG=1 bash mayfly.sh launch "$MF_STATE/bases/base-01" "$MF_STATE/secrets/wireguard.conf" /dev/shm
```

- The gateway log adds the WireGuard latest-handshake time and byte counts. A `handshake` value of `0` means the tunnel isn't established. The `lan0` counters show whether browser traffic reaches the gateway.
- The browser log adds a name-lookup probe run as the unprivileged browser user, a UDP packet sent to the gateway, the names of processes running as that user, and the I2P router's tunnel count (`i2p_tunnels`).
- The scripts print no keys, endpoint, resolver or profile text. Each file is the guest serial port, though, so it can also hold console output. Review it before sharing.

Read a log while the session runs, filtered through `cat -v` so guest-controlled text can't inject terminal escapes:

```bash
grep -a '^diag' /dev/shm/mayfly.*/gateway-diag.log | tail -3 | cat -v
```

**Don't use `MAYFLY_DIAG=1` for leak, idle, failure-path or fingerprint tests.** The probe sends a lookup every few seconds through the tunnel, even in Tor Browser sessions, which keeps the tunnel active and gives your VPN provider a recognizable pattern.

The guest scripts are baked into the base, so rebuild the base after you update the source.

When you report a problem, give the step number from this guide, the source revision (`git rev-parse HEAD`), OS and package versions, the command's exit status, the fixed error message, and what appeared in the VM window. Describe route results as comparisons, not IP addresses. Remove private paths, usernames, endpoint and resolver values, profiles, keys, browsing history, captures and bulk logs before you share anything.

## 9. Temporary core-dump policy

A piped core collector (for example `apport` or `systemd-coredump`) can ignore `RLIMIT_CORE`, so zero process limits aren't enough. A crashed QEMU could leave VM memory, which holds your session and the WireGuard key, in a core file. `doctor`, `check-profile` and `launch` therefore refuse a host that has a piped pattern or `fs.suid_dumpable` other than `0`. See [core(5)](https://man7.org/linux/man-pages/man5/core.5.html) and the [kernel `suid_dumpable` definition](https://www.kernel.org/doc/html/latest/admin-guide/sysctl/fs.html#suid-dumpable).

**Impact:** this changes crash diagnostics for every application on the host. It's a temporary opt-in, and it creates no sysctl drop-in, service mask or SELinux change. Mayfly changes it only when you ask, with `core-policy apply` or the `--core-policy` flag. Keep it active for the whole life of the VMs, and restore it only after they're gone.

**Automated form.** `bash mayfly.sh core-policy apply|restore|status` does what the two blocks below do. `apply` does nothing if the host already meets the requirement (a non-piped pattern and `fs.suid_dumpable=0`). Otherwise it saves the original values once per boot to `<state>/core-policy/<boot_id>/original.conf` (directories `0700`, file `0600`, created with `noclobber`), then runs `sudo sysctl -w kernel.core_pattern=/dev/null fs.suid_dumpable=0`. Without `sudo` it stops with an error and changes nothing. `restore` reads the saved file once, validates it, and passes only those validated values to `sudo sysctl -w`, never the file itself. Run as a normal user, it accepts a piped saved pattern only when the first token is an absolute path to a root-owned executable, reached through root-owned directories that are not group or world writable and with no symlinks, and it accepts a plain pattern only from a conservative character set. Anything else is refused with a message, because the snapshot lives in your own state directory and other programs that run as you could edit it. `restore` also refuses while any QEMU process exists or the check fails. In that case restore the original values by hand with `sysctl -w`, or in mode 1 run `sudo mayfly core-policy restore`, which reads the root-owned snapshot. `status` only reads. With `--core-policy` on `launch`, `check-profile` or `setup`, Mayfly remembers whether it applied the policy and restores it on exit (including Ctrl+C, `SIGTERM` and `SIGHUP`) only if it did and no QEMU process is left. Otherwise it leaves the policy in place and tells you to run `core-policy restore` after the last session. A `SIGKILL` or a power loss skips the restore, so run `core-policy status` afterwards. In mode 1 the root wrapper does the same without `sudo`, with the snapshot under `/var/lib/mayfly/core-policy`, and `sudo mayfly core-policy ...` is available.

Check the current values:

```bash
sysctl kernel.core_pattern fs.suid_dumpable
```

Save the original values, once per boot, then apply the policy. The block refuses to run if the host is already restricted and no saved baseline exists:

```bash
(
  set -euo pipefail
  boot=$(cat /proc/sys/kernel/random/boot_id)
  saved="$MF_STATE/core-policy/$boot/original.conf"
  mkdir -p -m 700 -- "$MF_STATE/core-policy/$boot"
  if [[ ! -e $saved ]]; then
    pattern=$(sysctl -n kernel.core_pattern)
    suid=$(sysctl -n fs.suid_dumpable)
    [[ -n $pattern && $suid =~ ^[012]$ ]]
    if [[ $pattern == /dev/null && $suid == 0 ]]; then
      echo 'Already restricted and no saved baseline: stop and find the original values.' >&2
      exit 1
    fi
    (set -o noclobber
      printf 'kernel.core_pattern=%s\nfs.suid_dumpable=%s\n' "$pattern" "$suid" > "$saved")
    chmod 600 -- "$saved"
  fi
  read -r -p 'Temporarily disable host-wide core collection? Type APPLY: ' answer
  [[ $answer == APPLY ]]
  sudo sysctl -w kernel.core_pattern=/dev/null fs.suid_dumpable=0
  sysctl kernel.core_pattern fs.suid_dumpable
)
```

Expected: `kernel.core_pattern = /dev/null` and `fs.suid_dumpable = 0`. If only one write succeeds, keep the saved file, fix or restore before you leave the host, and don't start a VM. Never `source` or `eval` the saved file. A piped pattern in it is data.

**Restore** after every test period, including a failed profile check with no VM. First finish step 7 for every session. In mode 1, also confirm that `pgrep -u mayfly -x qemu-system-x86` prints nothing. The restore refuses if any QEMU system process exists:

```bash
(
  set -euo pipefail
  boot=$(cat /proc/sys/kernel/random/boot_id)
  saved="$MF_STATE/core-policy/$boot/original.conf"
  [[ -f $saved && ! -L $saved ]]
  [[ $(stat -c '%u:%a:%h' "$saved") == "$UID:600:1" ]]
  mapfile -t original < "$saved"
  [[ ${#original[@]} == 2 && ${original[0]} == kernel.core_pattern=?* ]]
  [[ ${original[1]} =~ ^fs.suid_dumpable=[012]$ ]]
  pattern=${original[0]#kernel.core_pattern=}
  suid=${original[1]#fs.suid_dumpable=}
  status=0
  pgrep -f '[q]emu-system-' || status=$?
  [[ $status == 1 ]] || { echo 'QEMU remains or inspection failed: do not restore.' >&2; exit 1; }
  printf 'Saved values: kernel.core_pattern=%s fs.suid_dumpable=%s\n' "$pattern" "$suid"
  read -r -p 'Are these your original values (a pipe must name a root-owned handler), all VMs gone and no launch in progress? Type RESTORE: ' answer
  [[ $answer == RESTORE ]]
  sudo sysctl -w "kernel.core_pattern=$pattern" "fs.suid_dumpable=$suid"
  sysctl kernel.core_pattern fs.suid_dumpable
)
```

Expected: the original pattern and number return, including a piped pattern if that was your baseline. Keep the saved file. Don't run `sudo sysctl --system`, and don't pass the saved file to `sudo sysctl -p`: it sits in a directory your other programs can write to. The [sysctl reference](https://man7.org/linux/man-pages/man8/sysctl.8.html) defines `-w`. A reboot ends the old boot's policy and normally brings back your distribution's defaults. After a reboot, save a new baseline for that boot. Never replay an old boot's file.

If the restore refuses because of an unrelated QEMU process, don't stop the other workload to satisfy it. Keep the restricted policy until you have accounted for every process.

## 10. Run as a dedicated user (mode 1)

Mode 1 moves the VMs to a no-login system user named `mayfly`, so other programs that run as you can't reach them through file permissions. You still start and watch the session from your desktop. It's the strongest mode and it needs a native Wayland session. Mayfly's installer, [`host/install-host.sh`](host/install-host.sh), installs a root-owned wrapper at `/usr/local/sbin/mayfly`. The wrapper runs the project as `mayfly` with a cleared environment.

This is the one step that uses `sudo`, by design. The installer and the wrapper run as root, so read them before you run them.

What mode 1 doesn't protect against:

- **Your `sudo` password.** Your account stays an administrator, so malware that captures the password can become root. Common capture paths are a `sudo` alias in a shell startup file, a fake `sudo` early in a user-writable `PATH` folder, and a spoofed password prompt. A separate administrator account or a hardware key for `sudo` narrows this gap.
- **The shared window.** The session window appears in your desktop session. Software that can capture your screen can capture it, and a hostile window can imitate a password prompt.
- **One Wayland socket.** The `mayfly` user, including a compromised VM, can talk to your compositor as an ordinary client through that socket. What the compositor lets such a client do is unverified. Text you paste while a VM window has focus can reach that window, so don't paste anything sensitive. The wrapper accepts any socket named `wayland-N` that you own, so malware that you run could substitute its own.
- **The key.** The `mayfly` user holds the WireGuard key, so keep the account unused for anything else.
- **The network and SELinux.** The VMs use the host's network stack through QEMU user-mode networking, and this mode adds no per-user egress filter. On the tested host both users ran in the same unconfined SELinux domain, so file permissions are the only separation. Check yours with `ps -Z -u mayfly`.

Keep the core policy from step 9 active whenever you run `doctor` or `launch`. In mode 1, `sudo mayfly launch --core-policy` and `sudo mayfly check-profile --core-policy` handle it for you: the wrapper (running as root, so without a `sudo` prompt) applies the policy if needed and restores it after the session only if it applied it and no QEMU process remains.

### Review, preview and install

The installer copies files out of a user-writable checkout, so review is your protection. The options below catch mistakes, not malware that already runs as you. Compare the files with the last commit you trusted, and make sure the source is committed:

```bash
git diff TRUSTED_COMMIT -- host lib guest mayfly.sh
bash host/install-host.sh --dry-run
```

Replace `TRUSTED_COMMIT` with the commit you reviewed. The preview changes nothing. It refuses a tree that isn't a clean Git commit, so add `--allow-dirty` to preview uncommitted work.

Install once. Replace `FULL_SHA_YOU_REVIEWED` with the full 40-character hash. The installer refuses a checkout at any other commit:

```bash
sudo bash host/install-host.sh --expect-rev FULL_SHA_YOU_REVIEWED
```

`--profile` and `--pins` are optional. When you omit them and the files exist in the invoking user's default state directory (`~/.local/state/mayfly/secrets/wireguard.conf` and `pins/build.pins`), the installer uses those through the same safe-read path. If the destination already holds a file, it keeps it unless you add `--replace`. Without a pins file, `sudo mayfly setup` fetches one as the `mayfly` user. To use other files, pass them explicitly:

```bash
sudo bash host/install-host.sh --expect-rev FULL_SHA_YOU_REVIEWED \
  --profile "$MF_STATE/secrets/wireguard.conf" \
  --pins "$MF_STATE/pins/build.pins"
```

The installer:

- Creates the no-login `mayfly` system user. On Debian, Ubuntu and Arch, where `/dev/kvm` is group-restricted, it adds `mayfly` to the group that owns the device.
- Creates `/var/lib/mayfly` as a root-owned directory (mode `0711`) with private `mayfly` subdirectories, so `mayfly` can't swap them for links.
- Copies a fixed list of program files into root-owned `/usr/local/lib/mayfly`, records their hashes in a manifest, and runs `restorecon` when it's installed. The wrapper rechecks the manifest before every command except `status`, `stop` and `cleanup`. That detects changes made after installation, not a bad source.
- Installs `/usr/local/sbin/mayfly`.
- Copies the profile and pins into the `mayfly` directories without printing them. Each must be a regular file you own and not a symlink, at most 16 KiB for the profile and 4 KiB for the pins. Add `--replace` to overwrite files from an earlier install.

It doesn't reboot, change networking or the firewall, or touch the core policy. It prints the installed wrapper hash at the end. Compare it with a hash you got from a trusted source. If `sudo` can't find `mayfly`, use `/usr/local/sbin/mayfly`.

### Build and launch

Run these from a terminal in your desktop session. The short form is two commands:

```bash
sudo mayfly setup
sudo mayfly launch --core-policy
```

`setup` fetches the pins (as the `mayfly` user, with the same confirmation prompt) and builds a base if they're missing, and stops if the profile isn't installed. The step-by-step form is:

```bash
sudo mayfly check-profile --core-policy
sudo mayfly doctor
sudo mayfly fetch-pins
sudo mayfly build base-01
sudo mayfly launch --core-policy base-01
```

`build` with no name creates `base-YYYYMMDD`, and `launch` with no name uses the newest base. The build runs as the `mayfly` user and can take several minutes. `launch` needs exactly one Wayland socket in your session. If it can't pick one, list `wayland-*` in `$XDG_RUNTIME_DIR` and pass the name, for example `sudo mayfly launch --display wayland-1 base-01`. Add `--diag` for the diagnostics in step 8, which are then readable only by `mayfly` and root:

```bash
sudo bash -c 'cat /dev/shm/mayfly.*/browser-diag.log | cat -v'
```

The glob must expand in root's shell, because your account can't read inside the `mayfly.*` directories.

The launcher shares only your single Wayland socket with `mayfly`, through a private [mount namespace](https://man7.org/linux/man-pages/man7/mount_namespaces.7.html) and a temporary [access-list entry](https://man7.org/linux/man-pages/man1/setfacl.1.html) that's removed when the session ends. It doesn't open your runtime directory, which holds other sockets that any user could connect to, such as audio.

Verify the boundary from your own account. The commands in step 7 filter on your user ID, so they don't see these processes:

```bash
ps -u mayfly -o pid,user,comm
ls -ld /var/lib/mayfly /var/lib/mayfly/secrets /dev/shm/mayfly.*
cat /var/lib/mayfly/secrets/wireguard.conf
cat "/proc/$(pgrep -u mayfly -o -x qemu-system-x86)/mem"
```

Expected: the first command lists the QEMU processes under `mayfly`. The second shows `/var/lib/mayfly` owned by `root` (`drwx--x--x`) and `secrets` and the session directories owned by `mayfly` (`drwx------`). The last two commands fail with `Permission denied`. If either succeeds, stop and report it.

### End, inspect and clean up

Close the browser or press Ctrl+C in the launcher terminal to end a session. From another terminal:

- `sudo mayfly stop` asks the launcher to stop gracefully.
- `sudo mayfly status` lists the user, the bases and the processes.
- `sudo mayfly cleanup` revokes leftover access to your Wayland socket. When no launcher is running, it also stops orphaned `mayfly` VMs and removes leftover session directories, which you can't remove yourself.

Before you restore the core policy, confirm that `pgrep -u mayfly -x qemu-system-x86` prints nothing.

### Update, rotate and remove

After you update the source, commit it, review the diff, rerun the installer, and build a new base, because the guest scripts are baked into each image.

Your old profile file was readable by every process that ran as you, and it may be in your backups. After you migrate, generate a new WireGuard key pair or profile with your VPN provider, install it with `--replace`, and delete the old copies from your state directory, backups and repository folder. Delete the old bases and pins there too.

To remove everything, end all sessions and run `sudo mayfly cleanup`. Then run `sudo userdel mayfly` and delete `/var/lib/mayfly`, `/usr/local/lib/mayfly` and `/usr/local/sbin/mayfly`. The `ptrace_scope` setting is a separate hardening step. See the [Yama documentation](https://www.kernel.org/doc/html/latest/admin-guide/LSM/Yama.html).

## 11. Rebuild and rotate bases

Browsers can't update inside a session, and pinning isn't an update service. Rebuild regularly. The launcher warns when a base is older than 35 days. `MAYFLY_MAX_BASE_AGE_DAYS` changes that limit.

1. Check Debian and Tor Browser releases and security notices.
2. Repeat step 2 with a new state directory, or move the old pins file aside, to get newly verified pins.
3. Build into a new directory name, such as `base-02`, with the step 3 command (`sudo mayfly build base-02` in mode 1).
4. Launch from the new base and check each entry.
5. Delete the old base when you no longer need it. Never modify an active base.

Debian package versions inside the guest aren't pinned, so a rebuild can change them. An update that happens inside a disposable session doesn't carry over to the next session.

## 12. Leak test: check that nothing leaves outside the tunnel

A pass means no direct traffic was observed in that run. It doesn't prove that no leak path exists. Run the test once per entry, because the three entries behave differently. There are two methods. Use the first if you run mode 1, because it attributes packets to the VMs. Use the second as a cross-check, or if you can't use mode 1.

### Method 1: count packets sent by the `mayfly` user (mode 1)

The VMs run as the `mayfly` user, so the kernel can count every packet that user sends. These rules only count. They never block or change traffic, and you delete them afterwards. Replace `ENDPOINT_IP` and `PORT` with the address and port from the `Endpoint` line of your profile:

```bash
sudo nft add table inet mfcap
sudo nft add chain inet mfcap out '{ type filter hook output priority -150; policy accept; }'
sudo nft add rule inet mfcap out meta skuid mayfly oifname != lo counter comment '"all"'
sudo nft add rule inet mfcap out meta skuid mayfly oifname != lo ip daddr ENDPOINT_IP udp dport PORT counter comment '"endpoint"'
```

Launch a session, use one entry, and open `check.torproject.org`, a DNS-leak test, an IPv6 test and a WebRTC test (for the I2P entry, open an `.i2p` site). Close the session, then read the counters. Don't run `sudo mayfly build`, `fetch-pins` or `setup` while the rules exist, because they download as that user and add to the counts:

```bash
sudo nft list table inet mfcap
```

`all` counts every packet the `mayfly` user sent off the machine, over IPv4 or IPv6. `endpoint` counts those sent to the WireGuard endpoint. Pass means the two packet counts are equal. Any gap means a VM sent something outside the tunnel. Reset the counters between entries with `sudo nft reset counters table inet mfcap`, and delete the table when you finish:

```bash
sudo nft delete table inet mfcap
```

### Method 2: capture on the uplink and compare with a baseline

A capture sees your whole host, so it can't tell the VMs from your other programs. Close other network applications first, and expect to see their traffic in the result.

You need `tcpdump` and the name of your uplink interface (`ip route show default`, the word after `dev`). Use `-Z "$USER"` so the files belong to you.

1. Record an idle baseline for one minute, with no Mayfly session open:

   ```bash
   sudo timeout 60 tcpdump -Z "$USER" -i UPLINK -nn -w /tmp/baseline.pcap
   ```

2. Start a capture, launch a session from another terminal, run the same tests, close the session, then stop the capture with Ctrl-C:

   ```bash
   sudo tcpdump -Z "$USER" -i UPLINK -nn -w /tmp/session-firefox.pcap
   ```

3. Compare the two captures. Reading a capture file needs no privileges. `--profile` reads only the `Endpoint` line of your profile:

   ```bash
   bash tests/capture/analyze.sh --profile /abs/path/secrets/wireguard.conf \
     /tmp/baseline.pcap /tmp/session-firefox.pcap
   ```

   `PASS` means every outbound packet that the baseline doesn't explain went to the WireGuard endpoint over UDP. `FAIL` lists each unexpected destination. Most of those are usually your own programs, such as browsers, NTP and mDNS. Use Method 1 to tell the difference. A `FAIL` with `the capture is inconclusive` means the session never reached the endpoint.

Keep the captures private, because they contain your host's network activity, and delete them when you finish:

```bash
rm -f /tmp/baseline.pcap /tmp/session-*.pcap
```

### Tunnel-down path

Make a copy of your profile with a wrong port in the `Endpoint` line, and launch with the copy. Expect no page to load. With Method 1, set the rule's `PORT` to the wrong port and expect `all` to equal `endpoint`, which means the VM sent nothing except retries to that endpoint. Never edit your real profile.

## 13. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `doctor`, `check-profile` or `launch` refuses and mentions a piped collector, or `suid_dumpable` | The host pipes core dumps (`apport`, `systemd-coredump`) or `fs.suid_dumpable` isn't `0`. Apply the [temporary core-dump policy](#9-temporary-core-dump-policy), and restore it afterwards. |
| Preflight warns that no kernel image is readable, or the build fails in libguestfs | Ubuntu installs kernels in `/boot` as `0600`. Run `sudo chmod 0644 /boot/vmlinuz-*` and rebuild. In mode 1, the build runs as `mayfly`, so the kernel image must be readable by that user. |
| `/dev/kvm exists but you cannot use it`, or `mayfly cannot read and write /dev/kvm` | On Debian, Ubuntu and Arch the device is `root:kvm` `0660`. Mode 1's installer adds the `mayfly` user to that group. For modes 2 and 3, add your account to the group named by `ls -l /dev/kvm` and log in again. Don't `chmod 777` the device. |
| Preflight reports `MISSING /dev/kvm` | Enable hardware virtualization in the firmware and load the `kvm` module. |
| Preflight warns about no Wayland session | Only native Wayland sessions are supported and tested. Preflight warns when it finds no Wayland session, and the launcher doesn't fall back to XWayland. |
| `doctor` fails on memory or tmpfs size | The check needs 16 GiB available RAM and a `tmpfs` with `nodev,nosuid` and at least 7 GiB capacity and free space. Close other work, or fix the mount. |
| `doctor` fails on swap, resume or crash dump | Disk swap, zram with writeback, a configured resume device, or a loaded or reserved crash kernel is refused. See step 8. |
| `UNIX socket path too long` | The session path must be shorter than 75 characters. Use a shorter `RAM-PARENT`. |
| Build fails, or you have an unfinished base | A failed build leaves partial nonsecret artifacts. Don't use them. Retry with a new destination. |
| Profile rejected | The parser reports a field name and a fixed message. Compare the profile with the [supported format](README.md#wireguard-profile-format), and check the file's owner, mode, parent directory and link count. |
| Blank VM window, or a socket timeout | Rerun a nonsensitive session with `MAYFLY_DIAG=1` (step 8). A handshake value of `0` means the tunnel isn't up. |
| I2P progress window never finishes | The guest has no time sync, so suspect the clock. The session ends after about ten minutes. Read `i2p_tunnels` in `browser-diag.log`. The launcher waits for 6 tunnels. |
| Inside distrobox, host root appears as `nobody` | Expected, and Mayfly accepts it. Distrobox can't provide mode 1. |
| `sudo mayfly` reports that program files don't match the manifest | Something changed `/usr/local/lib/mayfly` after installation. Review it, then rerun the installer. |
| `sudo mayfly launch` can't pick a Wayland socket | Pass `--display wayland-N`. |
| After a build, a mode 1 command can't find the base | Base names allow letters, digits, `_` and `-`, up to 64 characters. Check `sudo mayfly status`. |
| A first run in mode 1 fails | Report the exact command, its exit status and the fixed message. Check for SELinux denials with `sudo ausearch -m avc -ts recent`. `doctor` also warns if `dev.tty.legacy_tiocsti` is enabled, which would let a process sharing your terminal inject keystrokes. |
