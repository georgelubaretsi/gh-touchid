# Upgrading

## From 0.4.2

- `app set` is now `app add`, with the same arguments; `app set` no longer exists.
- Invalid input exits with status 2 instead of 1.
- Nothing stored changes. For public data of other owners without Touch ID, run `gh-touchid reader create`, or
  `gh-touchid setup`.

## From 0.4.0 or 0.4.1

Nothing to do. Sessions approved before the upgrade keep working: the newer release asks the old release's agent about
them, and `status` and `lock` include it. A session that was still pending (never used yet) is not carried over; run
`gh-touchid session` in it again. From then on, upgrades keep sessions approved as described under
[Status, lock and the access log](status.md#status-lock-and-the-access-log).

## From 0.3.1 or earlier to 0.4

0.3.1 and earlier acted as each App's bot, with the App's private key. 0.4 acts as you, and cannot use an App stored by
an older version ("the stored App for OWNER is not valid"). For each owner:

1. Run `gh-touchid app create OWNER` and go through **Create**, **Authorize** and **Install**. The new App is named
   `OWNER-touchid`, so it does not clash with the old default, `OWNER-agent`. It replaces the stored App.
2. Run `gh-touchid git setup OWNER`. The helper command changed from `git-credential` to `git credential`, and the old
   entry no longer works. `status` shows `fix:` for each owner still on it.
3. Delete the old App on GitHub: its settings page, **Advanced → Delete GitHub App**.

Commands that changed:

| 0.3                     | 0.4                        |
| ----------------------- | -------------------------- |
| `user add <login>`      | `account add <login>`      |
| `user remove <login>`   | `account remove <login>`   |
| `git-setup <owner>`     | `git setup <owner>`        |
| `git-credential …`      | `git credential …`         |

Account tokens stored by 0.3 keep working.

## From 0.3.0

0.3.0 put its own `gh` in `bin/`. Later versions keep it in `libexec/bin`, off your PATH unless you add it. After
upgrading, `gh` is whatever other `gh` comes first on PATH, or not found: pick one of the
[ways to run it through gh-touchid](install.md#running-gh-through-gh-touchid). Unpacking a newer tarball over 0.3.0 leaves
0.3.0's `bin/gh` behind; delete it. Then follow [the 0.3.1 steps](#from-031-or-earlier-to-04).

## From 0.2

- `unlock` is gone. Use [`session`](sessions.md#sessions) for unattended work and [`elevate`](sessions.md#elevating-a-repository) for
  workflow changes.
- `set` and the tokens stored per repository are gone. Store a token per GitHub account with `account add` and use it
  with `as`. The old items have Keychain service `com.lubaretsi.gh-touchid` and account `owner/repo`. List them with
  `security find-generic-password -s com.lubaretsi.gh-touchid -a owner/repo` (this prints no secret), and delete each
  with `security delete-generic-password -s com.lubaretsi.gh-touchid -a owner/repo`.
- Create an App per owner with `app create`, or make one by hand and use `app add`.
- Replace 0.2's per-repository `credential.helper` settings (`git config --local --unset-all credential.helper`) with
  `gh-touchid git setup OWNER`.
