import AppKit
import ServiceManagement

// `uninstall.sh` runs the installed binary with this flag to remove the login item before deleting the app.
if CommandLine.arguments.contains("--unregister-login-item") {
    do {
        try SMAppService.mainApp.unregister()
        print("Removed Snap It from Open at Login.")
    } catch {
        print("Open at Login was not registered (\(error.localizedDescription)).")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
