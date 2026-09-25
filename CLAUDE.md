# linuxmuster-fileserver-verwaltung — dedicated "Verwaltung" fileserver for linuxmuster.net 7.3

Rulebook of the hub: `../../CLAUDE.md`; package conventions: `../../docs/paket-konventionen.md`
(paths relative to this repo checked out under `linuxmusterDEV/packages/` or `worktrees/`).
Kevin speaks German; code, commits and changelog are English. `README.md` and `ANLEITUNG.md`
are German and stay German (audience: German school admins); CLI help texts are German too.

## Overview

| Component | Path | Stack |
|---|---|---|
| CLI | `usr/bin/linuxmuster-fileserver-verwaltung` (one script, no `.py`; subcommands `setup`, `status`, `show`, `repair-acls`, `save-acl`, `restore-acl`) | Python 3.12, stdlib only (argparse, configparser, subprocess) |
| Templates | `var/lib/linuxmuster-fileserver-verwaltung/{smb,krb5,nsswitch}.conf.example` | rendered by `setup` (`%%DOMAIN%%`, `%%WORKGROUP%%`, `%%HOSTNAME%%`) |
| State | `/etc/linuxmuster-fileserver-verwaltung/share.conf` (written by `setup`, read by `status`/`repair-acls`) | INI |
| Packaging | `debian/` (`make deb`) | debhelper 13, native 3.0, dist lmn73; Depends only on Ubuntu 24.04 packages |
| Docs | `README.md` (concept, operations), `ANLEITUNG.md` (step by step); installed via `debian/docs` | German |
| Tests | none in-tree yet; the install smoke in `.github/workflows/{ci,release}.yml` imports the script, calls `validate_share_name`/`check_time_sync` and runs `testparm` on the rendered `smb.conf` | |

Runtime: its own Ubuntu 24.04 VM joined as a domain member of the linuxmuster.net 7.3 AD, never
the DC and never a sophomorix-managed fileserver.

## Constraints (do not violate)

- Version: the top entry of `debian/changelog` is the only hand-edited version (`7.3.N`, dist
  `lmn73`). Never bump it in a feature PR; Kevin bumps and tags `v7.3.N` (CI gate: tag ==
  changelog version). `release.yml` fails unless the published release comes out immutable;
  with the optional repo secret `IMMUTABLE_CHECK_TOKEN` (fine-grained, this repo,
  Administration: Read-only; GITHUB_TOKEN cannot read that setting) it also refuses to
  publish while the setting is off.
- License: GPL-3.0-or-later (`LICENSE`, `debian/copyright`). No code from linuxmuster-fileserver
  (Netzint GmbH) is included; keep it that way when touching the config examples or packaging.
- Design decisions that look odd but are deliberate (see README §2): `rid` idmap backend, not
  `autorid`/`ad`; `acl_xattr:ignore system acls = yes` so the NT ACL is the only authority; the
  share lives in the Samba registry; no sophomorix directory structure is ever created.
- Samba invocations: credentials via a short-lived 0600 file (never `-U user%password`), locale
  pinned to C, every `valid users`/`admin users` entry quoted, Domain Admins always in
  `valid users`, baseline NT ACL always seeded. Group SIDs are recorded and compared on
  `status`.
- No real-server actions outside the hub's lab workflow (`../../CLAUDE.md`, lock + snapshot
  first). The lab fileservers `lmn-fs`/`lmn-one-fs` run the upstream package; this package
  needs its own member VM.

## Way of working

- Branch `feat/<topic>` or `fix/<topic>` from `main`; English conventional commits
  `type(scope): subject` (since 7.3.1; the older history is German, leave it).
- Fast tier locally before every commit (same as `ci.yml`):
  `python3 -m py_compile usr/bin/linuxmuster-fileserver-verwaltung && ruff check usr/bin/linuxmuster-fileserver-verwaltung`
  (ruff 0.15.21, default rule set, snake_case, lines <= 100).
- `make deb` builds the package (`.deb` lands one level up); CI builds in
  `ghcr.io/linuxmuster/lmndev-runner:24.04` pinned by digest (`IMG_LMN73` in
  `.github/workflows/ci.yml`; raised by hand while Renovate is disabled) as root and installs the
  result on ubuntu-24.04. A local container build uses the same digest, never the bare tag
  (`README.md` §10).
- Lab test via the hub: `bin/lab-lock`, `bin/lab-snapshot`, `bin/lab-deploy <member-vm> <deb>`,
  then `linuxmuster-fileserver-verwaltung setup` / `status` / `show` against the lab AD
  (`lmn-test`); journal in `work/linuxmuster-fileserver-verwaltung/`.
- Changelog entry (`debian/changelog`, top block, `urgency=medium`) in the same PR as the
  change, written for admins.
