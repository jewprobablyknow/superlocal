// Native macOS shell for Superlocal.
// Starts the local host + Claude bridge (`bun run start:claude`) in the background,
// shows the web UI in a WKWebView window, and stops the server when the app quits.
import AppKit
import WebKit

let appURL = URL(string: "http://localhost:5178/")!

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var server: Process?
    var ownsServer = false
    var logHandle: FileHandle?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.loadHTMLString(loadingPage, baseURL: nil)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Superlocal"
        window.titlebarAppearsTransparent = false
        window.contentView = webView
        window.setFrameAutosaveName("SuperlocalMainWindow")
        if !window.setFrameUsingName("SuperlocalMainWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Task { await startAndLoad() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard ownsServer, let server, server.isRunning else { return }
        server.interrupt() // SIGINT: the bridge stops the app, which drains the SDK host.
        let deadline = Date().addingTimeInterval(8)
        while server.isRunning && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        if server.isRunning { server.terminate() }
    }

    // MARK: Server

    func serverIsUp() async -> Bool {
        var request = URLRequest(url: appURL)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    @MainActor
    func startAndLoad() async {
        if await serverIsUp() { webView.load(URLRequest(url: appURL)); return }
        do { try launchServer() } catch { showError("Could not start Superlocal: \(error.localizedDescription)"); return }
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await serverIsUp() { webView.load(URLRequest(url: appURL)); return }
            if let server, !server.isRunning { break }
        }
        showError("Superlocal did not start. See ~/Library/Logs/Superlocal.log")
    }

    func launchServer() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        let repo = info["SuperlocalRepo"] as? String ?? (NSHomeDirectory() + "/superlocal")
        let bun = info["SuperlocalBun"] as? String ?? "/opt/homebrew/bin/bun"
        let home = NSHomeDirectory()

        let logURL = URL(fileURLWithPath: home + "/Library/Logs/Superlocal.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try FileHandle(forWritingTo: logURL)
        logHandle?.truncateFile(atOffset: 0)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bun)
        // Run the bridge directly (not via `bun run`), so the quit signal reaches it.
        process.arguments = ["--no-env-file", "scripts/claude-bridge.ts", "--with-app"]
        process.currentDirectoryURL = URL(fileURLWithPath: repo)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(home)/.local/bin:\((bun as NSString).deletingLastPathComponent):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN"] { env.removeValue(forKey: key) }
        process.environment = env
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        server = process
        ownsServer = true
    }

    @MainActor
    func showError(_ message: String) {
        let escaped = message.replacingOccurrences(of: "<", with: "&lt;")
        webView.loadHTMLString(loadingPage.replacingOccurrences(of: "Starting Superlocal…", with: escaped), baseURL: nil)
    }

    // MARK: Web view

    // Open external links (target=_blank or other hosts) in the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated,
           let host = url.host, !["localhost", "127.0.0.1"].contains(host) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = message
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    // MARK: Menu

    @objc func reload() { webView.reload() }
    @objc func openInBrowser() { NSWorkspace.shared.open(appURL) }
    @objc func showLog() { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Superlocal.log")) }
    @objc func zoomIn() { webView.pageZoom += 0.1 }
    @objc func zoomOut() { webView.pageZoom = max(0.5, webView.pageZoom - 0.1) }
    @objc func zoomReset() { webView.pageZoom = 1 }

    func buildMenu() {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        let appMenu = NSMenu()
        appMenu.addItem(item("About Superlocal", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide Superlocal", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Superlocal", #selector(NSApplication.terminate(_:)), "q"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))

        let view = NSMenu(title: "View")
        view.addItem(item("Reload", #selector(reload), "r", target: self))
        view.addItem(item("Actual Size", #selector(zoomReset), "0", target: self))
        view.addItem(item("Zoom In", #selector(zoomIn), "+", target: self))
        view.addItem(item("Zoom Out", #selector(zoomOut), "-", target: self))
        view.addItem(.separator())
        view.addItem(item("Open in Browser", #selector(openInBrowser), "o", [.command, .shift], target: self))
        view.addItem(item("Show Server Log", #selector(showLog), "l", [.command, .shift], target: self))
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))

        for (title, menu) in [("Superlocal", appMenu), ("Edit", edit), ("View", view), ("Window", windowMenu)] {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = menu
            main.addItem(top)
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}

let loadingPage = """
<!doctype html><html><head><meta charset="utf-8"><style>
:root{color-scheme:light dark}
body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
font:15px -apple-system,system-ui,sans-serif;color:#888;background:Canvas}
</style></head><body>Starting Superlocal…</body></html>
"""

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
