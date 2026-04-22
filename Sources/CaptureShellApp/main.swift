import AppKit
import Foundation

if let exitCode = OfflineFrameExportCommand.runIfRequested(arguments: CommandLine.arguments) {
    exit(Int32(exitCode))
}

if let exitCode = OfflineROISelectionCommand.runIfRequested(arguments: CommandLine.arguments) {
    exit(Int32(exitCode))
}

if let exitCode = OfflineAnalysisCommand.runIfRequested(arguments: CommandLine.arguments) {
    exit(Int32(exitCode))
}

if let exitCode = LiveAnalysisCommand.runIfRequested(arguments: CommandLine.arguments) {
    exit(Int32(exitCode))
}

let app = NSApplication.shared
let delegate = AppDelegate()

app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
