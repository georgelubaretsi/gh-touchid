# gh reference

## gh api <endpoint> [flags]

Makes an authenticated HTTP request to the GitHub API and prints the response.

```
      --cache duration        Cache the response, e.g. "3600s", "60m", "1h"
  -F, --field key=value       Add a typed parameter in key=value format
  -H, --header key:value      Add a HTTP request header in key:value format
      --hostname string       The GitHub hostname for the request (default "github.com")
  -i, --include               Include HTTP response status line and headers in the output
      --input file            The file to use as body for the HTTP request (use "-" to read from standard input)
  -q, --jq string             Query to select values from the response using jq syntax
  -X, --method string         The HTTP method for the request (default "GET")
      --paginate              Make additional HTTP requests to fetch all pages of results
  -f, --raw-field key=value   Add a string parameter in key=value format
      --silent                Do not print the response body
```

## gh auth <command>

Authenticate gh and git with GitHub

### gh auth status [flags]

Display active account and authentication state on each known GitHub host.

```
  -a, --active            Display the active account only
  -h, --hostname string   Check only a specific hostname's auth status
  -t, --show-token        Display the auth token
```

### gh auth token [flags]

Print the authentication token gh uses for a hostname and account.

```
  -h, --hostname string   The hostname of the GitHub instance authenticated with
  -u, --user string       The account to output the token for
```

## gh issue <command>

Work with GitHub issues.

### gh issue comment {<number> | <url>} [flags]

Add a comment to a GitHub issue.

```
  -b, --body text        The comment body text
  -F, --body-file file   Read body text from file (use "-" to read from standard input)
  -e, --editor           Skip prompts and open the text editor to write the body in
  -w, --web              Open the web browser to write the comment
```

### gh issue create [flags]

Create an issue on GitHub.

```
  -a, --assignee login   Assign people by their login. Use "@me" to self-assign.
  -b, --body string      Supply a body. Will prompt for one otherwise.
  -F, --body-file file   Read body text from file (use "-" to read from standard input)
  -l, --label name       Add labels by name
  -t, --title string     Supply a title. Will prompt for one otherwise.
  -w, --web              Open the browser to create an issue
```

Aliases

gh issue new

### gh issue list [flags]

List issues in a GitHub repository.

```
  -a, --assignee string   Filter by assignee
  -l, --label strings     Filter by label
  -L, --limit int         Maximum number of issues to fetch (default 30)
  -s, --state string      Filter by state: {open|closed|all} (default "open")
  -w, --web               List issues in the web browser
```

Aliases

gh issue ls

## gh pr <command>

Work with GitHub pull requests.

### gh pr checkout {<number> | <url> | <branch>} [flags]

Check out a pull request in git

```
  -b, --branch string   Local branch name to use (default [the name of the head branch])
  -f, --force           Reset the existing local branch to the latest state of the pull request
```

### gh pr list [flags]

List pull requests in a GitHub repository.

```
  -B, --base string       Filter by base branch
  -L, --limit int         Maximum number of items to fetch (default 30)
  -s, --state string      Filter by state: {open|closed|merged|all} (default "open")
```

Aliases

gh pr ls

## gh repo <command>

Work with GitHub repositories.

### gh repo view [<repository>] [flags]

Display the description and the README of a GitHub repository.

```
  -b, --branch string   View a specific branch of the repository
  -w, --web             Open a repository in the browser
```

## gh co

Alias for "pr checkout"
