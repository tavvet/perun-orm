/// Returns the normalized transaction-control command that begins the first meaningful statement.
///
/// Leading whitespace, UTF-8 byte-order marks, empty semicolons, line comments, and nested block
/// comments are ignored.
/// Block comments are scanned with both nested and flat semantics; a command found under either
/// interpretation is rejected conservatively for the paired PostgreSQL and SQLite adapters.
/// Later statements are intentionally not inspected. Atomic enforcement of the executor's
/// single-statement contract remains the paired driver's responsibility.
package func sqlTransactionControlCommand(in sql: String) -> String? {
    for blockCommentMode in [SQLBlockCommentMode.nested, .flat] {
        let keywords = leadingSQLKeywords(
            in: sql,
            limit: 2,
            blockCommentMode: blockCommentMode
        )
        if let command = transactionControlCommand(from: keywords) {
            return command
        }
    }
    return nil
}

/// Returns false only when PostgreSQL nested-comment rules prove that no statement is present.
///
/// Malformed trivia returns true so the PostgreSQL driver preserves its original syntax error.
package func sqlContainsMeaningfulStatement(in sql: String) -> Bool {
    let bytes = Array(sql.utf8)
    var index = 0
    let triviaWasWellFormed = skipSQLTrivia(
        bytes,
        index: &index,
        semicolonsAreTrivia: true,
        blockCommentMode: .nested
    )
    return !triviaWasWellFormed || index < bytes.count
}

private enum SQLBlockCommentMode: Sendable {
    case nested
    case flat
}

private func transactionControlCommand(from keywords: [String]) -> String? {
    guard let first = keywords.first else { return nil }

    switch first {
    case "BEGIN", "COMMIT", "END", "ROLLBACK", "ABORT", "SAVEPOINT", "RELEASE":
        return first
    case "START", "PREPARE", "SET":
        guard keywords.count == 2, keywords[1] == "TRANSACTION" else { return nil }
        return "\(first) TRANSACTION"
    default:
        return nil
    }
}

private func leadingSQLKeywords(
    in sql: String,
    limit: Int,
    blockCommentMode: SQLBlockCommentMode
) -> [String] {
    let bytes = Array(sql.utf8)
    var index = 0
    var keywords: [String] = []

    while keywords.count < limit {
        skipSQLTrivia(
            bytes,
            index: &index,
            semicolonsAreTrivia: keywords.isEmpty,
            blockCommentMode: blockCommentMode
        )
        let start = index
        while index < bytes.count, isSQLIdentifierByte(bytes[index]) {
            index += 1
        }
        guard start < index else { break }
        keywords.append(String(decoding: bytes[start ..< index], as: UTF8.self).uppercased())
    }
    return keywords
}

@discardableResult
private func skipSQLTrivia(
    _ bytes: [UInt8],
    index: inout Int,
    semicolonsAreTrivia: Bool,
    blockCommentMode: SQLBlockCommentMode
) -> Bool {
    while index < bytes.count {
        if isSQLByteOrderMark(bytes, at: index) {
            index += 3
            continue
        }
        if isSQLWhitespace(bytes[index])
            || (semicolonsAreTrivia && bytes[index] == UInt8(ascii: ";")) {
            index += 1
            continue
        }
        if index + 1 < bytes.count,
           bytes[index] == UInt8(ascii: "-"),
           bytes[index + 1] == UInt8(ascii: "-") {
            index += 2
            while index < bytes.count,
                  bytes[index] != UInt8(ascii: "\n"),
                  bytes[index] != UInt8(ascii: "\r") {
                index += 1
            }
            continue
        }
        if index + 1 < bytes.count,
           bytes[index] == UInt8(ascii: "/"),
           bytes[index + 1] == UInt8(ascii: "*") {
            guard skipSQLBlockComment(
                bytes,
                index: &index,
                mode: blockCommentMode
            ) else {
                return false
            }
            continue
        }
        break
    }
    return true
}

private func isSQLByteOrderMark(_ bytes: [UInt8], at index: Int) -> Bool {
    index + 2 < bytes.count
        && bytes[index] == 0xEF
        && bytes[index + 1] == 0xBB
        && bytes[index + 2] == 0xBF
}

private func skipSQLBlockComment(
    _ bytes: [UInt8],
    index: inout Int,
    mode: SQLBlockCommentMode
) -> Bool {
    index += 2
    var depth = 1
    while index < bytes.count, depth > 0 {
        if case .nested = mode,
           index + 1 < bytes.count,
           bytes[index] == UInt8(ascii: "/"),
           bytes[index + 1] == UInt8(ascii: "*") {
            depth += 1
            index += 2
        } else if index + 1 < bytes.count,
                  bytes[index] == UInt8(ascii: "*"),
                  bytes[index + 1] == UInt8(ascii: "/") {
            depth -= 1
            index += 2
        } else {
            index += 1
        }
    }
    return depth == 0
}

private func isSQLWhitespace(_ byte: UInt8) -> Bool {
    byte == UInt8(ascii: " ") || (UInt8(ascii: "\t") ... UInt8(ascii: "\r")).contains(byte)
}

private func isSQLIdentifierByte(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
        || (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte)
        || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
        || byte == UInt8(ascii: "_")
        || byte == UInt8(ascii: "$")
}
