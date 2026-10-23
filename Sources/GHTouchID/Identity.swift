import Darwin
import Foundation
import Security

// Which program on the other end of the agent's socket is a gh-touchid this one trusts. Clients ask it about the
// agent before acting on its reply, and the agent asks it about a client before it begins, records or refuses a
// session approval or elevates. The checks read the kernel's view of the peer through the connection's audit
// token, never through a pid lookup that a reused pid could fool: a valid code signature, the hardened runtime when
// this program has it, and then its cdhash: this executable's own (any architecture), an earlier release on the
// built-in list, or (builds that share agent.sock) a newer release proven by its code signature. Builds that keep an
// agent of their own also trust a program running from their own path, as every build did before.

/// Whether this build shares one agent per user at `agent.sock`, with the built-in list of earlier releases, the
/// lookup of 0.4.0/0.4.1 agents and newer releases proven by signature. Test builds and builds that carry a list of
/// releases do. Every other build (a development build, or one that pins gh without a list, such as Nix's build from
/// source, which is ad hoc signed) keeps an agent of its own at a socket named after its path and trusts its own
/// cdhashes and its own path: on agent.sock it and a Homebrew release would each find the other untrusted and fall
/// back to Touch ID for every use, where apart they each keep their sessions; and a rebuilt development binary keeps
/// the agent, and sessions, of the one it replaced.
let sharesAgentSocket: Bool = {
#if GH_TOUCHID_TESTING
    return true
#else
    return !knownReleaseList.hasPrefix("@") && !knownReleaseList.isEmpty
#endif
}()

/// The agent protocol this build speaks; every request and reply carries it with `toolVersion`.
let agentProtocol = 1

@_silgen_name("csops")
func csops(_ pid: pid_t, _ operation: UInt32, _ buffer: UnsafeMutableRawPointer?, _ size: Int) -> Int32

@_silgen_name("csops_audittoken")
private func csopsAuditToken(
    _ pid: pid_t,
    _ operation: UInt32,
    _ buffer: UnsafeMutableRawPointer?,
    _ size: Int,
    _ token: UnsafeMutablePointer<audit_token_t>
) -> Int32

// From xnu's <sys/codesign.h>, which the macOS SDK does not ship.
let csOpsStatus: UInt32 = 0
let csOpsCDHash: UInt32 = 5
let csValid: UInt32 = 0x1
private let csRuntime: UInt32 = 0x0001_0000

/// 20 bytes as 40 lowercase hex digits.
private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

/// An earlier release on the built-in list.
private struct KnownRelease {
    let version: String
    let revoked: Bool
}

/// `knownReleaseList` (scripts/build.sh --known-releases) by cdhash: `VERSION STATUS arch=CDHASH[,arch=CDHASH]`
/// entries joined by `;`. Empty when the build carries no list.
private let knownReleases: [String: KnownRelease] = {
    guard !knownReleaseList.hasPrefix("@") else {
        return [:]
    }
    var releases: [String: KnownRelease] = [:]
    for entry in knownReleaseList.split(separator: ";") {
        let fields = entry.split(separator: " ")
        guard fields.count == 3, fields[1] == "trusted" || fields[1] == "revoked" else {
            continue
        }
        let release = KnownRelease(version: String(fields[0]), revoked: fields[1] == "revoked")
        for pin in fields[2].split(separator: ",") {
            let parts = pin.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                releases[String(parts[1])] = release
            }
        }
    }
    return releases
}()

/// The cdhashes of this executable: every architecture of its file, and the code the kernel loaded for this process.
/// The agent reads them as it starts, since an upgrade may delete its file while it runs.
let ownCodeDirectoryHashes: Set<String> = {
    var hashes: Set<String> = []
    var hash = [UInt8](repeating: 0, count: 20)
    if csops(getpid(), csOpsCDHash, &hash, hash.count) == 0 {
        hashes.insert(hex(hash))
    }
    guard let path = ownExecutablePath else {
        return hashes
    }
    for architecture in ["arm64", "x86_64"] {
        var code: SecStaticCode?
        let attributes = [kSecCodeAttributeArchitecture: architecture] as CFDictionary
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPathAndAttributes(URL(fileURLWithPath: path) as CFURL, [], attributes, &code)
            == errSecSuccess, let code,
            SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
            let information = information as? [String: Any] else {
            continue
        }
        let all = information[kSecCodeInfoCdHashes as String] as? [Data] ?? []
        let unique = information[kSecCodeInfoUnique as String] as? Data
        for data in all + (unique.map { [$0] } ?? []) where data.count >= 20 {
            hashes.insert(hex(Array(data.prefix(20))))
        }
    }
    return hashes
}()

/// The code requirement a newer release meets, in builds that share agent.sock: the Developer ID requirement in a
/// release, GH_TOUCHID_TEST_PEER_REQUIREMENT in a test build (none when it is unset).
private let newerReleaseRequirement: SecRequirement? = {
#if GH_TOUCHID_TESTING
    guard let text = ProcessInfo.processInfo.environment["GH_TOUCHID_TEST_PEER_REQUIREMENT"], !text.isEmpty else {
        return nil
    }
#else
    guard sharesAgentSocket else {
        return nil
    }
    let text = releaseCodeRequirement
#endif
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
        return nil
    }
    return requirement
}()

/// Who a peer is.
enum PeerIdentity {
    /// This very executable (any architecture of it).
    case same
    /// An earlier release on the built-in list.
    case older(String)
    /// A later release: it meets the release code requirement and says it has a later version.
    case newer(String)
    /// An earlier release the built-in list marks revoked.
    case revoked(String)
    case untrusted(String)

    var isTrusted: Bool {
        switch self {
        case .same, .older, .newer:
            return true
        case .revoked, .untrusted:
            return false
        }
    }

    var isRevoked: Bool {
        if case .revoked = self {
            return true
        }
        return false
    }

    /// Why a peer that is not trusted is not, for messages and the access log.
    var reason: String {
        switch self {
        case .same:
            return "this gh-touchid"
        case let .older(version):
            return "gh-touchid \(version)"
        case let .newer(version):
            return "gh-touchid \(version), a newer release"
        case let .revoked(version):
            return "gh-touchid \(version), which is revoked"
        case let .untrusted(reason):
            return reason
        }
    }
}

/// What the kernel and the code signature say about a peer, before its message is read.
enum PeerCode {
    case decided(PeerIdentity)
    /// It meets the newer-release requirement: the version it states decides.
    case meetsRequirement(PeerProcess)
}

/// One process, from an audit token: its pid and the kernel's version of that pid, which tells it from a later
/// process given the same pid.
struct PeerProcess: Equatable {
    let pid: pid_t
    let pidVersion: UInt32
}

/// The audit token of a local socket's peer (`LOCAL_PEERTOKEN` at level `SOL_LOCAL`, from sys/un.h).
private func peerAuditToken(_ fd: Int32) -> audit_token_t? {
    var token = audit_token_t()
    var length = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(fd, 0, 0x006, &token, &length) == 0, length == MemoryLayout<audit_token_t>.size else {
        return nil
    }
    return token
}

/// Steps 1–3 of identifying a peer: same user, valid code (hardened like this one, if this one is), and its cdhash
/// among this executable's own or the list's; otherwise whether it meets the newer-release requirement.
func examinePeer(_ fd: Int32) -> PeerCode {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
        return .decided(.untrusted("it runs as another user"))
    }
    guard var token = peerAuditToken(fd) else {
        return .decided(.untrusted("its audit token cannot be read"))
    }
    let pid = pid_t(bitPattern: token.val.5)
    var status: UInt32 = 0
    guard csopsAuditToken(pid, csOpsStatus, &status, MemoryLayout<UInt32>.size, &token) == 0,
          status & csValid != 0 else {
        return .decided(.untrusted("its code signature is not valid"))
    }
    var own: UInt32 = 0
    if csops(getpid(), csOpsStatus, &own, MemoryLayout<UInt32>.size) == 0, own & csRuntime != 0,
       status & csRuntime == 0 {
        return .decided(.untrusted("it does not run with the hardened runtime"))
    }
    var bytes = [UInt8](repeating: 0, count: 20)
    guard csopsAuditToken(pid, csOpsCDHash, &bytes, bytes.count, &token) == 0 else {
        return .decided(.untrusted("its cdhash cannot be read"))
    }
    let cdhash = hex(bytes)
    if ownCodeDirectoryHashes.contains(cdhash) {
        return .decided(.same)
    }
    if let release = knownReleases[cdhash] {
        return .decided(release.revoked ? .revoked(release.version) : .older(release.version))
    }
    // A rebuilt binary has a new cdhash; at the same path it is the same program as far as this build's agent goes.
    if !sharesAgentSocket, let path = executablePath(pid), path == ownExecutablePath {
        return .decided(.same)
    }
    let unknown = PeerIdentity.untrusted("its cdhash \(cdhash) is not a gh-touchid this one knows")
    guard let requirement = newerReleaseRequirement else {
        return .decided(unknown)
    }
    // the code of a process whose file is gone cannot be found, so a newer release deleted by an upgrade is not
    // trusted: it serves out its sessions, and the next agent starts once it exits
    var code: SecCode?
    let attributes = [kSecGuestAttributeAudit: Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)]
    guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess, let code,
          SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
        return .decided(unknown)
    }
    return .meetsRequirement(PeerProcess(pid: pid, pidVersion: token.val.7))
}

/// Step 3c: a peer that meets the requirement is a newer release when the version it states is later than this one.
func identity(of code: PeerCode, statedVersion: Any?) -> PeerIdentity {
    switch code {
    case let .decided(identity):
        return identity
    case .meetsRequirement:
        guard let version = statedVersion as? String, isLaterVersion(version, than: toolVersion) else {
            let stated = (statedVersion as? String).map { printable($0, limit: 40) } ?? "no version"
            return .untrusted("it meets the release requirement but states \(stated), not later than \(toolVersion)")
        }
        return .newer(version)
    }
}

/// Who the peer of `fd` is, given the version it stated in its message.
func identifyPeer(_ fd: Int32, statedVersion: Any?) -> PeerIdentity {
    identity(of: examinePeer(fd), statedVersion: statedVersion)
}

/// Dotted numeric versions compared part by part (missing parts are 0); anything else is never later.
func isLaterVersion(_ version: String, than reference: String) -> Bool {
    func parts(_ text: String) -> [Int]? {
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { field -> Int? in
            field.allSatisfy(\.isASCII) && field.allSatisfy(\.isNumber) ? Int(field) : nil
        }
        return !fields.isEmpty && numbers.count == fields.count ? numbers : nil
    }
    guard let later = parts(version), let earlier = parts(reference) else {
        return false
    }
    for index in 0 ..< max(later.count, earlier.count) {
        let left = index < later.count ? later[index] : 0
        let right = index < earlier.count ? earlier[index] : 0
        if left != right {
            return left > right
        }
    }
    return false
}
