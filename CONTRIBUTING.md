# Contributing

Mayfly is experimental, small, and written in Bash. This page covers how to test a change and what a change needs.

Report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md), not in a public issue.

## Run the tests

The offline suite needs no KVM, network, credentials or `sudo`. Its dependencies are Bash, `git`, `jq`, `python3`, `awk`, coreutils, `util-linux` and `acl`. The seed-builder tests also need one of `xorriso`, `genisoimage` or `mkisofs`, so install one before you run the suite.

```bash
find . -type f -name '*.sh' -exec bash -n {} \;
bash tests/run.sh
```

The first command syntax-checks every script. The second prints one `ok` or `not ok` line per check and ends with a summary such as `513 passed, 0 failed`. It must exit `0`. The suite checks parsers, policy text, host predicates, and mocked build and launch failures. It doesn't boot VMs or prove routing.

The workflow in `.github/workflows/tests.yml` runs a `bash -n` loop over `git ls-files '*.sh'` and then `bash tests/run.sh`, in containers for `debian:13`, `ubuntu:24.04`, `fedora:latest`, `archlinux:latest` and `opensuse/tumbleweed:latest`. A separate job runs ShellCheck at error severity only.

### Test on other distributions

`tests/distro/matrix.sh` runs `mayfly.sh preflight` and the offline suite inside distrobox containers. It only enters containers whose names start with `mayfly-test-`:

```bash
bash tests/distro/matrix.sh                        # all five default containers
bash tests/distro/matrix.sh mayfly-test-debian     # one container
MATRIX_INSTALL=1 bash tests/distro/matrix.sh       # install missing packages first
```

The default containers are `mayfly-test-debian`, `mayfly-test-ubuntu`, `mayfly-test-fedora`, `mayfly-test-arch` and `mayfly-test-opensuse`. Create them with `distrobox create` from the matching distribution image. The script installs packages inside a container only when you set `MATRIX_INSTALL=1`.

## Rules

- **Mutation-check your tests.** A test that can't fail proves nothing. Before you send a change, break the code it covers (flip a condition, delete a rule) and confirm that the new test fails. Then restore the code. Say in the pull request how you checked.
- **Never commit secrets or state.** No WireGuard profiles, keys, pins from a real build, base images, logs or browser data. `.gitignore` blocks most of these, but check `git status` yourself. Tests use only the synthetic fixtures in `tests/fixtures`.
- **No Unicode dashes in code.** Use ASCII hyphens in scripts, tests and comments.
- **Keep scripts safe.** Scripts keep `set +x` and `set -euo pipefail`, and never print keys, endpoints or resolver values. Error messages are fixed text.
- **Add package-map entries for new distributions.** Preflight maps tool groups to package names in `mf_pkg_for` in `lib/preflight.sh`, and install commands in `mf_install_command`. Extend both, extend `mf_os_family`, and add cases to `tests/preflight-tests.sh`.
- **Don't claim live results without live evidence.** An offline pass doesn't establish that a VM boots, that traffic routes, or that a policy is active. In docs and pull requests, say what you ran, on which host, at which commit, and mark everything else unverified. Update the [Tested](README.md#tested) section only with evidence you collected.
- **Keep the docs in step.** If you change a command, a check or an installer behavior, update [README.md](README.md) and [DEPLOYMENT.md](DEPLOYMENT.md) in the same change. Write in plain language and avoid marketing wording.

## Send a change

1. Fork the repository and create a branch.
2. Make a focused change, with tests.
3. Run both commands in [Run the tests](#run-the-tests).
4. Open a pull request that states what changed, why, and how you tested it, including any live testing and its limits.

By contributing, you agree that your contribution is licensed under the [MIT licence](LICENSE).
