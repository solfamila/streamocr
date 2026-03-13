import CoreGraphics

enum ScreenRecordingPermissionStatus {
    case granted
    case denied
}

struct ScreenRecordingPermissionManager {
    func currentStatus() -> ScreenRecordingPermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    @discardableResult
    func requestPermissionIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess()
    }
}
