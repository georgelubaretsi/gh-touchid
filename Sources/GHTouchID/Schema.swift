import CoreFoundation
import Foundation

// The shape of every operation's input and output, declared once: rendered as JSON Schema (draft 2020-12) for
// `--help --json`, and used to check input strictly before anything runs (and, in test builds, every output). The
// checks are exact: a boolean is not a number, an integer has no fraction, an object takes no field it does not
// declare. Messages name the field and what is wrong, never the value, which might be a secret.

indirect enum Schema {
    case object(properties: [(name: String, schema: Schema)], required: [String], description: String = "")
    /// `argument`: text a program gets as an argument or a path, so no NUL, which would end it early in C: the program
    /// would get less than gh-touchid checked.
    case string(
        enumValues: [String]? = nil,
        pattern: String? = nil,
        secret: Bool = false,
        argument: Bool = false,
        description: String = ""
    )
    case integer(minimum: Int? = nil, maximum: Int? = nil, description: String = "")
    case boolean(description: String = "")
    case array(Schema, description: String = "")
    /// The schema or null; its description is the wrapped schema's.
    case nullable(Schema)

    /// The JSON Schema keywords of this schema.
    var jsonSchema: [String: Any] {
        var rendered: [String: Any]
        let text: String
        switch self {
        case let .object(properties, required, description):
            var declared: [String: Any] = [:]
            for property in properties {
                declared[property.name] = property.schema.jsonSchema
            }
            rendered = ["type": "object", "properties": declared, "additionalProperties": false]
            if !required.isEmpty {
                rendered["required"] = required
            }
            text = description
        case let .string(enumValues, pattern, secret, argument, description):
            rendered = ["type": "string"]
            if let enumValues {
                rendered["enum"] = enumValues
            }
            if let pattern {
                rendered["pattern"] = pattern
            } else if argument {
                rendered["pattern"] = "^[^\\u0000]*$"
            }
            if secret {
                rendered["writeOnly"] = true
            }
            text = description
        case let .integer(minimum, maximum, description):
            rendered = ["type": "integer"]
            if let minimum {
                rendered["minimum"] = minimum
            }
            if let maximum {
                rendered["maximum"] = maximum
            }
            text = description
        case let .boolean(description):
            rendered = ["type": "boolean"]
            text = description
        case let .array(items, description):
            rendered = ["type": "array", "items": items.jsonSchema]
            text = description
        case let .nullable(wrapped):
            rendered = wrapped.jsonSchema
            if let type = rendered["type"] as? String {
                rendered["type"] = [type, "null"]
            }
            if let values = rendered["enum"] as? [Any] {
                rendered["enum"] = values + [NSNull()]
            }
            return rendered
        }
        if !text.isEmpty {
            rendered["description"] = text
        }
        return rendered
    }

    /// Whether any string in this schema is a secret.
    var hasSecret: Bool {
        switch self {
        case let .object(properties, _, _):
            return properties.contains { $0.schema.hasSecret }
        case let .string(_, _, secret, _, _):
            return secret
        case .integer, .boolean:
            return false
        case let .array(items, _):
            return items.hasSecret
        case let .nullable(wrapped):
            return wrapped.hasSecret
        }
    }

    /// Whether this is a secret string.
    var isSecret: Bool {
        if case let .string(_, _, secret, _, _) = self {
            return secret
        }
        return false
    }

    /// The first way `value` (as JSONSerialization makes it) does not fit, as `<path>: <reason>`; nil when it fits.
    func violation(_ value: Any?, path: String) -> String? {
        let name = path.isEmpty ? "the input" : path
        switch self {
        case let .nullable(wrapped):
            return value is NSNull ? nil : wrapped.violation(value, path: path)
        case let .object(properties, required, _):
            guard let object = value as? [String: Any], !(value is NSArray) else {
                return "\(name): must be an object"
            }
            for key in object.keys.sorted() where !properties.contains(where: { $0.name == key }) {
                return "\(joined(path, printable(key, limit: 60))): is not a field this takes"
            }
            for field in required where object[field] == nil {
                return "\(joined(path, field)): is required"
            }
            for property in properties {
                guard let field = object[property.name] else {
                    continue
                }
                if let problem = property.schema.violation(field, path: joined(path, property.name)) {
                    return problem
                }
            }
            return nil
        case let .string(enumValues, pattern, _, argument, _):
            guard !isNumber(value), let text = value as? String else {
                return "\(name): must be a string"
            }
            if argument, text.utf8.contains(0) {
                return "\(name): contains a NUL character, which a program cannot receive: remove it"
            }
            if let enumValues, !enumValues.contains(text) {
                return "\(name): must be one of \(enumValues.joined(separator: ", "))"
            }
            if let pattern, !matches(text, pattern) {
                return "\(name): must match \(pattern)"
            }
            return nil
        case let .integer(minimum, maximum, _):
            guard let number = value as? NSNumber, isNumber(value), !isBoolean(number) else {
                return "\(name): must be an integer"
            }
            let double = number.doubleValue
            guard double.rounded() == double, abs(double) < 9.0e15 else {
                return "\(name): must be an integer"
            }
            if let minimum, number.intValue < minimum {
                return "\(name): must be at least \(minimum)"
            }
            if let maximum, number.intValue > maximum {
                return "\(name): must be at most \(maximum)"
            }
            return nil
        case .boolean:
            guard let number = value as? NSNumber, isBoolean(number) else {
                return "\(name): must be true or false"
            }
            return nil
        case let .array(items, _):
            guard let array = value as? [Any] else {
                return "\(name): must be an array"
            }
            for (index, element) in array.enumerated() {
                if let problem = items.violation(element, path: "\(name)[\(index)]") {
                    return problem
                }
            }
            return nil
        }
    }
}

/// `path.field`, or `field` at the top.
private func joined(_ path: String, _ field: String) -> String {
    path.isEmpty ? field : "\(path).\(field)"
}

/// Whether `value` is a number or boolean as Foundation holds them (strings never are).
private func isNumber(_ value: Any?) -> Bool {
    guard let value else {
        return false
    }
    let type = CFGetTypeID(value as CFTypeRef)
    return type == CFNumberGetTypeID() || type == CFBooleanGetTypeID()
}

/// Whether `number` is a boolean: JSONSerialization makes true and false CFBooleans.
private func isBoolean(_ number: NSNumber) -> Bool {
    CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
}

/// Whether `pattern` (an ECMA-style regular expression NSRegularExpression also reads) matches somewhere in `text`.
private func matches(_ text: String, _ pattern: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return false
    }
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}
