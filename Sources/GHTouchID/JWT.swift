import CryptoKit
import Foundation
import Security

// The reader's private key and the App JWT it signs. GitHub hands out an App's key as a PKCS#1 PEM (`BEGIN RSA PRIVATE
// KEY`); only that form is taken, so that a key from elsewhere (PKCS#8, encrypted, another algorithm) is refused
// rather than half-understood. CryptoKit has no RSA, so the key and its RS256 signature come from Security.framework.
// No part of a key goes into an error, a log line or output; its fingerprint (as GitHub shows it) does.

/// An App's private key, parsed from the PEM GitHub downloads.
struct AppPrivateKey {
    private let key: SecKey

    /// Parses a PKCS#1 `RSA PRIVATE KEY` PEM; anything else is `invalidPrivateKey`.
    init(pem: String) throws {
        let begin = "-----BEGIN RSA PRIVATE KEY-----"
        let end = "-----END RSA PRIVATE KEY-----"
        let text = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(begin), text.hasSuffix(end), text.count > begin.count + end.count else {
            if text.contains("-----BEGIN PRIVATE KEY-----") {
                throw ToolError.invalidPrivateKey(
                    "it is PKCS#8 (BEGIN PRIVATE KEY), not the PKCS#1 key GitHub downloads (BEGIN RSA PRIVATE KEY)"
                )
            }
            if text.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") {
                throw ToolError.invalidPrivateKey("it is encrypted, unlike the key GitHub downloads")
            }
            throw ToolError.invalidPrivateKey("it is not one PEM block BEGIN RSA PRIVATE KEY, as GitHub downloads it")
        }
        let body = text.dropFirst(begin.count).dropLast(end.count)
        // `Proc-Type: 4,ENCRYPTED` and `DEK-Info:` headers mark an encrypted PKCS#1 key
        guard !body.contains(":") else {
            throw ToolError.invalidPrivateKey("it is encrypted, unlike the key GitHub downloads")
        }
        guard let der = Data(base64Encoded: String(body.filter { !$0.isWhitespace })), !der.isEmpty else {
            throw ToolError.invalidPrivateKey("its PEM body is not valid base64")
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        let created = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error)
        _ = error?.takeRetainedValue()
        guard let created, SecKeyIsAlgorithmSupported(created, .sign, .rsaSignatureMessagePKCS1v15SHA256) else {
            throw ToolError.invalidPrivateKey("it is not a valid RSA private key")
        }
        key = created
    }

    /// An App JWT for `appId` (RS256): issued a minute ago against clock skew, valid for nine minutes after now,
    /// within GitHub's limit of ten.
    func jwt(appId: Int, now: Date = Date()) throws -> String {
        let seconds = Int(now.timeIntervalSince1970)
        let header = base64URL(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
        let payload = base64URL(Data(#"{"iat":\#(seconds - 60),"exp":\#(seconds + 540),"iss":\#(appId)}"#.utf8))
        let signingInput = "\(header).\(payload)"
        var error: Unmanaged<CFError>?
        let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(signingInput.utf8) as CFData,
            &error
        )
        _ = error?.takeRetainedValue()
        guard let signature = signature as Data? else {
            throw ToolError.invalidPrivateKey("the key cannot sign")
        }
        return "\(signingInput).\(base64URL(signature))"
    }

    /// The key's fingerprint as GitHub's App settings show it: `SHA256:` and the base64 of the SHA-256 of the public
    /// key's SubjectPublicKeyInfo DER (what `openssl rsa -pubout -outform DER | openssl sha256 -binary | base64`
    /// prints).
    func fingerprint() throws -> String {
        var error: Unmanaged<CFError>?
        let publicKey = SecKeyCopyPublicKey(key)
        let external = publicKey.flatMap { SecKeyCopyExternalRepresentation($0, &error) }
        _ = error?.takeRetainedValue()
        guard let pkcs1 = external as Data? else {
            throw ToolError.invalidPrivateKey("the key's public half cannot be read")
        }
        // SubjectPublicKeyInfo: SEQUENCE { AlgorithmIdentifier rsaEncryption with NULL, BIT STRING { RSAPublicKey } }
        let rsaEncryption: [UInt8] = [
            0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00,
        ]
        let bitString = derElement(tag: 0x03, Data([0x00]) + pkcs1)
        let spki = derElement(tag: 0x30, Data(rsaEncryption) + bitString)
        return "SHA256:" + Data(SHA256.hash(data: spki)).base64EncodedString()
    }
}

/// A DER element: `tag`, the definite length of `content`, then `content`.
private func derElement(tag: UInt8, _ content: Data) -> Data {
    var element = Data([tag])
    if content.count < 0x80 {
        element.append(UInt8(content.count))
    } else {
        var length: [UInt8] = []
        var remaining = content.count
        while remaining > 0 {
            length.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        element.append(0x80 | UInt8(length.count))
        element.append(contentsOf: length)
    }
    element.append(content)
    return element
}

/// Base64url without padding, as JWTs use it.
private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
