import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let captureController = DisplayCaptureController(
        permissionManager: ScreenRecordingPermissionManager(),
        timingLogger: FrameTimingLogger(),
        pipeline: NoOpFramePipeline()
    )

    private var window: NSWindow?
    private var statusLabel = NSTextField(labelWithString: "Starting...")
    private let displayPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let requestPermissionButton = NSButton(title: "Request Screen Permission", target: nil, action: nil)
    private let refreshDisplaysButton = NSButton(title: "Refresh Displays", target: nil, action: nil)
    private let startStopButton = NSButton(title: "Start Capture", target: nil, action: nil)

    private var displays: [DisplayTarget] = []
    private var isCapturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installAppMenu()
        configureUI()
        bindCaptureCallbacks()

        Task {
            await refreshDisplays()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task {
            await captureController.stopCapture()
        }
    }

    @objc
    private func requestPermissionTapped() {
        let granted = captureController.requestScreenRecordingPermission()
        statusLabel.stringValue = granted
            ? "Screen Recording permission granted."
            : "Permission not granted. Enable Screen Recording for this app in System Settings."

        if granted {
            Task {
                await refreshDisplays()
            }
        }
    }

    @objc
    private func refreshDisplaysTapped() {
        Task {
            await refreshDisplays()
        }
    }

    @objc
    private func startStopTapped() {
        if isCapturing {
            Task {
                await captureController.stopCapture()
            }
            return
        }

        guard let selected = selectedDisplay else {
            statusLabel.stringValue = "Select a display target first."
            return
        }

        Task {
            await captureController.startCapture(displayID: selected.id)
        }
    }

    private var selectedDisplay: DisplayTarget? {
        guard displays.indices.contains(displayPopUp.indexOfSelectedItem) else {
            return nil
        }
        return displays[displayPopUp.indexOfSelectedItem]
    }

    private func configureUI() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 280),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "CaptureShell Wave 1"
        window.center()
        window.makeKeyAndOrderFront(nil)

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        let titleLabel = NSTextField(labelWithString: "ScreenCaptureKit Display Capture")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 16)

        let scopeLabel = NSTextField(labelWithString: "Wave 1 scope: display capture, permission flow, and frame timing logs.")
        scopeLabel.textColor = .secondaryLabelColor

        statusLabel.textColor = .labelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2

        requestPermissionButton.target = self
        requestPermissionButton.action = #selector(requestPermissionTapped)

        refreshDisplaysButton.target = self
        refreshDisplaysButton.action = #selector(refreshDisplaysTapped)

        startStopButton.target = self
        startStopButton.action = #selector(startStopTapped)

        let buttonsRow = NSStackView(views: [requestPermissionButton, refreshDisplaysButton, startStopButton])
        buttonsRow.orientation = .horizontal
        buttonsRow.spacing = 10

        let stack = NSStackView(views: [titleLabel, scopeLabel, displayPopUp, buttonsRow, statusLabel])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20)
        ])

        self.window = window
    }

    private func bindCaptureCallbacks() {
        captureController.onDisplaysUpdated = { [weak self] targets in
            guard let self else {
                return
            }

            displays = targets
            displayPopUp.removeAllItems()
            displayPopUp.addItems(withTitles: targets.map(\.title))

            if targets.isEmpty {
                statusLabel.stringValue = "No displays found. Confirm Screen Recording permission and retry."
            } else {
                statusLabel.stringValue = "Select a display target and start capture."
            }
        }

        captureController.onStatus = { [weak self] message in
            self?.statusLabel.stringValue = message
        }

        captureController.onCaptureStateChanged = { [weak self] active in
            guard let self else {
                return
            }
            isCapturing = active
            startStopButton.title = active ? "Stop Capture" : "Start Capture"
        }
    }

    private func refreshDisplays() async {
        statusLabel.stringValue = "Loading display targets..."
        await captureController.reloadDisplays()
    }

    private func installAppMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let quitTitle = "Quit \(ProcessInfo.processInfo.processName)"
        appMenu.addItem(withTitle: quitTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        appMenuItem.submenu = appMenu
        NSApplication.shared.mainMenu = mainMenu
    }
}
