import Darwin

do {
    let status = try run()
    exit(status)
} catch ToolError.usage {
    fputs("\(Usage.all)\n", stderr)
    exit(2)
} catch let ToolError.commandUsage(command) {
    fputs("\(Usage.of(command) ?? Usage.all)\n", stderr)
    exit(2)
} catch {
    fputs("gh-touchid: \(error)\n", stderr)
    exit(1)
}
