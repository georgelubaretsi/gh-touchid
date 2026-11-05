# Setup

`gh-touchid setup [<owner>...]` does steps 1, 3 and 5 for whatever is missing, and says whether `gh` runs through
gh-touchid; running it again repairs what changed. Without a terminal, or with `--no-input`, it does only what needs
no browser (Git) and lists the commands for the rest. The sections below are the same steps one by one.

## 1. A GitHub App per owner

Create one App for each owner whose repositories you work on:

```sh
gh-touchid app create acme [--name NAME] [--no-open]
```

gh-touchid opens a local page, `http://127.0.0.1:47911/`, which sends GitHub a manifest for a private App. The App is
named `acme-touchid` unless `--name` says otherwise. It has no webhook, the callback URL
`http://127.0.0.1:47911/callback`, and these repository permissions:

| Permission                                          | Access         |
| --------------------------------------------------- | -------------- |
| Contents, Pull requests, Issues, Actions, Workflows | Read and write |
| Checks, Commit statuses, Metadata                   | Read-only      |

The browser then goes through three pages on GitHub:

1. **Create GitHub App.** GitHub creates the App for the account you are signed in as in that browser, or for the
   organization when the owner is one. gh-touchid checks that the App belongs to the owner. It keeps the App's client
   ID and client secret, and drops the private key and webhook secret, so it never acts as an owner's App.
2. **Authorize.** You sign in to the new App as yourself (GitHub's web flow, with PKCE). Your sign-in is an access
   token that lasts 8 hours and a refresh token that renews it for 6 months. One Touch ID then stores the App and your
   sign-in in your login Keychain.
3. **Install.** Install the App on the owner, for all repositories or only the ones agents should reach.

At the end, in a terminal, gh-touchid asks `Set up Git for acme now? [Y/n]` and runs [`git setup`](#3-git) for you.
`--git-setup` or `--no-git-setup` answers in advance; without a terminal it prints the command instead.

If something goes differently:

- GitHub made the App for another account: nothing is stored, and gh-touchid says where to delete the App.
- You did not authorize: gh-touchid asks for Touch ID to keep the App alone. Finish with
  [`app login`](#signing-in-again).
- `--no-open` prints the first URL instead of opening it, for use in another browser profile.
- gh-touchid waits up to an hour for **Create** and 15 minutes for **Authorize**. Nothing else may listen on port
  47911 meanwhile: GitHub sends the browser back to exactly that address.

## 2. Or: an App made by hand

Create the App yourself in **Settings → Developer settings → GitHub Apps** with:

- the permissions above, and **Administration** at **No access**;
- **Only on this account**;
- the callback URL `http://127.0.0.1:47911/callback`.

Generate a client secret on its settings page, then run:

```sh
gh-touchid app add acme --client-id Iv23li... < client-secret
```

It reads the client secret from stdin, or at a hidden prompt when stdin is a terminal. Then it sends the browser to
the App's **Authorize** page. The code exchange checks the secret. After it, one Touch ID stores the App and your
sign-in, and gh-touchid offers to set up Git, as `app create` does. (Up to 0.4.2 this was `app set`.)

## Signing in again

gh-touchid renews your sign-in as you use it. It ends after six months without use, or when you revoke it on GitHub
(**Settings → Applications → Authorized GitHub Apps**). `gh` and Git then fail with "you are not signed in". (If the
use asks for Touch ID, you see this after it: only then does gh-touchid read the sign-in.) Sign in again with:

```sh
gh-touchid app login acme [--no-open]
```

## 3. Git

Let gh-touchid answer Git's HTTPS credential requests for an owner's repositories (`app create` and `app add` offer
to do this):

```sh
gh-touchid git setup acme
```

It writes these entries with `git config --global`, and prints them:

```ini
[credential "https://github.com/acme"]
	helper =
	helper = !/opt/homebrew/bin/gh-touchid git credential
	useHttpPath = true
```

- The empty first helper turns off any other helper, such as `osxkeychain`, for these repositories.
- `useHttpPath` tells gh-touchid which repository Git is talking to.
- Write the owner as it appears in your remotes' URLs: Git compares it case-sensitively.
- Use HTTPS remotes: `https://github.com/acme/REPO.git`.

The helper's path is one that survives updates: the first `gh-touchid` on PATH that is this one. A link such as
`/opt/homebrew/bin/gh-touchid`, `/etc/profiles/per-user/$USER/bin/gh-touchid` or `~/.nix-profile/bin/gh-touchid` wins
over a path in Homebrew's Cellar or the Nix store. If only such a versioned path exists, gh-touchid uses it and tells
you to run `git setup` again after each update.

Running `git setup` again replaces its own entries and moves them to the end of the file. There they come after any
broader `credential.helper`, such as the one `gh auth setup-git` writes for all of github.com, and turn it off for the
owner. `gh-touchid status` says for each owner which helpers Git asks.

To push as one of your accounts to other owners' repositories, configure the same three settings for
`https://github.com` as a whole. Git reads public repositories without asking. For other owners' private ones,
gh-touchid refuses unless you [act as an account](everyday-use.md#acting-as-one-of-your-accounts).

## 4. Your accounts (optional)

For what your Apps cannot reach, such as other people's repositories, store a token of each GitHub account you want
to act as. `account add` reads the token at a hidden prompt, or from stdin:

```sh
gh-touchid account add octocat
gh-touchid account remove octocat
```

`account add` asks GitHub whose token it is (`GET /user`). It stores nothing unless the token is that login's. It
prints the token's scopes, asks for Touch ID and stores the token in your login Keychain. `account remove` deletes the
token without Touch ID.

To contribute to public repositories the account is not a member of, such as opening a pull request on someone else's
project, use a classic token with the `repo` scope (and `workflow` to change workflows). A fine-grained token
(`github_pat_…`) cannot do that; `account add` warns about it.

## 5. The reader (optional)

For `gh` commands about owners you have no App for, such as reading another project's issues, store a reader: a
GitHub App of your user account with no permissions.

```sh
gh-touchid reader create [--name NAME] [--no-open]
```

The browser goes through two pages on GitHub:

1. **Create GitHub App.** An App of your account named `gh-touchid-reader-` and six hex digits unless `--name` says
   otherwise, with no permissions and no webhook. gh-touchid checks that it belongs to a user and has no
   permissions, keeps its ID and private key, and drops its secrets. One Touch ID stores it.
2. **Install.** Install it on your account. It asks for no repository access, so it gets none.

gh-touchid then makes one token with it, checks it and revokes it. From then on, a `gh` command for an owner without
an App of yours, or one that names no repository (`gh search`, `gh api users/octocat`), runs without Touch ID:

- Its token acts as `<app>[bot]`, not as you, and reads public data: repositories, issues, pull requests, files,
  releases, Actions runs, search and GraphQL. Your private repositories stay invisible to it.
- The token is made for that one use, used only when GitHub reports it has no permissions and no repository, and
  revoked when gh exits. It counts against the reader's own rate limit of 5,000 requests an hour, not yours.
- Every use tells the caller `public read-only access as <app>[bot]; don't create or change anything with it`: on
  stderr after `gh-touchid: `, and with `--json` (so through `rpc` and `mcp` too) in the result's `notices`.
- GitHub lets the bot open issues on any public repository, so gh-touchid refuses the commands that would:
  `gh issue create`, `gh api` posting to `repos/OWNER/REPO/issues`, and `gh api graphql` with `createIssue` or a
  query it cannot read. It does not refuse other writes GitHub might allow the bot ([details](security-model.md#the-reader)).
- Git never uses the reader; Git reads public repositories without a credential.

To give the reader a new key, or to use it on another Mac, generate a private key in the App's settings on GitHub
(**Settings → Developer settings → GitHub Apps → the reader → Private keys**), then:

```sh
gh-touchid reader add --app-id 123456 < ~/Downloads/gh-touchid-reader-1a2b3c.2026-11-02.private-key.pem
```

gh-touchid checks the key with GitHub, asks for Touch ID and replaces the stored reader. It prints the new key's
fingerprint and, when it replaced one, the old key's and where to delete it. Delete the downloaded file afterwards.
Every Mac using the same App shares its rate limit; for one of its own, run `reader create` on that Mac instead.

`gh-touchid reader remove` forgets the reader (`--yes` without a terminal); the App stays on GitHub until you delete
it there.

## Removing an owner

```sh
gh-touchid app remove acme [--yes]
```

It deletes the owner's App and your sign-in from the Keychain and the owner's Git entries, ends the sign-in on GitHub
(the App's authorization under **Settings → Applications**), and prints where to delete the App itself. It asks on a
terminal; elsewhere `--yes` confirms.
