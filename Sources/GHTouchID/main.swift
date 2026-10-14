import Darwin

do {
    let status = try run()
    exit(status)
} catch ToolError.usage {
    fputs("\(ToolError.usageText)\n", stderr)
    exit(2)
} catch {
    fputs("gh-touchid: \(error)\n", stderr)
    exit(1)
}
