import Foundation

// GitHub lets a token of the reader (an App with no permissions) open issues on any public repository, through REST
// (`POST /repos/{owner}/{repo}/issues`) and GraphQL (`createIssue`). Through the reader, gh-touchid refuses the gh
// commands that do that, before a token is made: `gh issue create` (and its alias `new`), `gh api` posting to a
// repository's issues, and `gh api graphql` with a query that mentions `createIssue` or that gh-touchid cannot read
// (from a file, stdin or `--input`). gh fills placeholders (`{owner}`, `{repo}`, `{branch}`, `:owner`, `:repo`) from
// GH_REPO and the repository here, in a `gh api` endpoint and in `-F` values, which could spell out an issues route or
// `createIssue` after this check: so a request that posts to an endpoint with one, or a typed query with one, is
// refused too. Commands are found as Cobra, gh's parser, finds them. Other writes GitHub refuses the reader on its own;
// the ones not tested are left to the notice every reader use prints.

/// Whether `gh <arguments>` would open an issue, or might and cannot be told: then the reader is not used for it.
func opensIssue(_ arguments: [String]) -> Bool {
    guard let command = cobraSubcommand(arguments, switches: ["help", "h", "version"]) else {
        return false
    }
    switch command.word {
    case "issue":
        let subcommand = cobraSubcommand(command.rest, switches: ["help", "h"])?.word
        return subcommand == "create" || subcommand == "new"
    case "api":
        return apiOpensIssue(command.rest)
    default:
        return false
    }
}

/// The word Cobra takes as the subcommand among `arguments`, and the arguments without it (the flags before it
/// included, which the subcommand parses too). As Cobra's `stripFlags` and `argsMinusFirstX` read them: a `--flag` or
/// `-f` without `=` takes the next argument unless it is one of the command's `switches`; `--` ends the search; any
/// other argument starting with `-` takes nothing; a `--flag` or `-f` with nothing after its value leaves no
/// subcommand.
private func cobraSubcommand(_ arguments: [String], switches: Set<String>) -> (word: String, rest: [String])? {
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--" {
            return nil
        }
        let long = argument.hasPrefix("--") && !argument.contains("=")
        let short = !long && argument.hasPrefix("-") && !argument.contains("=") && argument.count == 2
        if long || short {
            let name = String(argument.dropFirst(long ? 2 : 1))
            index += switches.contains(name) ? 1 : 2
        } else if !argument.isEmpty, !argument.hasPrefix("-") {
            var rest = arguments
            rest.remove(at: index)
            return (argument, rest)
        } else {
            index += 1
        }
    }
    return nil
}

/// What `gh api` reads from its arguments: its endpoint, its method, its fields and whether it reads `--input`.
private struct APICall {
    var endpoint: String?
    var method: String?
    /// `name=value` of `-f`/`--raw-field` and `-F`/`--field`, in order.
    var fields: [String] = []
    /// `name=value` of `-F`/`--field` alone: gh fills placeholders and reads `@file` in these.
    var typedFields: [String] = []
    var input = false

    /// Reads the arguments of `api`.
    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                if endpoint == nil, index < arguments.count {
                    endpoint = arguments[index]
                }
                break
            }
            if argument.hasPrefix("--") {
                let body = argument.dropFirst(2)
                if let equals = body.firstIndex(of: "=") {
                    take(String(body[..<equals]), String(body[body.index(after: equals)...]))
                } else if apiValueFlags.long.contains(String(body)) {
                    take(String(body), index < arguments.count ? arguments[index] : nil)
                    index += 1
                }
            } else if argument.count > 1, argument.hasPrefix("-") {
                // a group such as `-iXPOST`: its first flag that takes a value takes the rest of the group, or else
                // the next argument
                var group = argument.dropFirst()
                while let shorthand = group.first {
                    group = group.dropFirst()
                    guard apiValueFlags.short.contains(shorthand) else {
                        continue
                    }
                    if group.isEmpty {
                        take(String(shorthand), index < arguments.count ? arguments[index] : nil)
                        index += 1
                    } else {
                        // pflag reads `-X=POST` as `-X POST`
                        take(String(shorthand), String(group.first == "=" ? group.dropFirst() : group))
                    }
                    break
                }
            } else if endpoint == nil {
                endpoint = argument
            }
        }
    }

    /// Keeps what a flag with a value says about the request.
    private mutating func take(_ flag: String, _ value: String?) {
        guard let value else {
            return
        }
        switch flag {
        case "X", "method":
            method = value.uppercased()
        case "f", "raw-field":
            fields.append(value)
        case "F", "field":
            fields.append(value)
            typedFields.append(value)
        case "input":
            input = true
        default:
            break
        }
    }

    /// gh's method: the one given, else POST when there are fields or `--input`, else GET.
    var effectiveMethod: String {
        method ?? (fields.isEmpty && !input ? "GET" : "POST")
    }
}

/// The placeholders gh fills from the repository: in `gh api`'s endpoint, and in the values of `-F`.
private let placeholders = ["{owner}", "{repo}", "{branch}", ":owner", ":repo"]

/// `gh api` posting to a repository's issues (`repos/<owner>/<repo>/issues`, or `repositories/<id>/issues`, GitHub's
/// same route by the repository's id) or to an endpoint with a placeholder, or `gh api graphql` with a query that
/// mentions `createIssue`, cannot be read, or is typed (`-F`) with a placeholder.
private func apiOpensIssue(_ arguments: [String]) -> Bool {
    let call = APICall(arguments)
    guard let endpoint = call.endpoint else {
        return false
    }
    let posts = call.effectiveMethod == "POST"
    if posts, placeholders.contains(where: endpoint.lowercased().contains) {
        return true
    }
    let path = endpointPath(endpoint)
    if path == ["graphql"] || path == ["api", "graphql"] {
        if call.input {
            return true
        }
        let typed = Set(queries(in: call.typedFields))
        return queries(in: call.fields).contains { query in
            query.hasPrefix("@") || query.contains("createIssue")
                || (typed.contains(query) && placeholders.contains(where: query.contains))
        }
    }
    let rest = path.starts(with: ["api", "v3"]) ? Array(path.dropFirst(2)) : path
    let issues = (rest.count == 4 && rest[0] == "repos" && rest[3] == "issues")
        || (rest.count == 3 && rest[0] == "repositories" && rest[2] == "issues")
    return posts && issues
}

/// The values of the `query` fields among `name=value` fields.
private func queries(in fields: [String]) -> [String] {
    fields.compactMap { field in
        guard let equals = field.firstIndex(of: "="), field[..<equals] == "query" else {
            return nil
        }
        return String(field[field.index(after: equals)...])
    }
}

/// The parts of an endpoint's path, lowercase and percent-decoded before it is split (so an encoded slash counts as
/// one), without the host of a full URL, a query or a fragment, without empty parts (so leading, trailing and doubled
/// slashes do not matter), and with `.` and `..` resolved as a server would.
private func endpointPath(_ endpoint: String) -> [String] {
    var path = endpoint
    // `https://host/…`: the path after the host, read by hand so that `{owner}` placeholders do not defeat a URL parser
    if let scheme = path.range(of: "://") {
        let rest = path[scheme.upperBound...]
        path = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? ""
    }
    if let end = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
        path = String(path[..<end])
    }
    let decoded = path.removingPercentEncoding ?? path
    var parts: [String] = []
    for part in decoded.lowercased().split(separator: "/") {
        if part == ".." {
            _ = parts.popLast()
        } else if part != "." {
            parts.append(String(part))
        }
    }
    return parts
}
