import AppKit
import Foundation

let cliArgs = Array(CommandLine.arguments.dropFirst())
if !cliArgs.isEmpty {
    CLI.run(cliArgs)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
