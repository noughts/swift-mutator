import Foundation

let code: Int32
do {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    if options.help {
        print(usage)
        code = 0
    } else if options.showVersion {
        print(toolVersion)
        code = 0
    } else {
        code = try await runMutation(options)
    }
} catch let error as CLIError {
    log(error.description)
    code = error.exitCode
} catch {
    log("\(error)")
    code = 1
}
exit(code)
