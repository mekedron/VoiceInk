// Injected by patch.sh from the `patch` branch.
// Provides a clipslop-style launch-time permission alert that re-checks
// Microphone, Accessibility, and Screen Recording permissions on every launch
// and on app re-activation. Automation is intentionally excluded — on this
// patched build there is no reliable way to fix a broken automation entry from
// the UI (System Settings has no “–” button for Automation), so it would only
// surface a Grant button that can't actually fix anything.

import AppKit
import SwiftUI
import AVFoundation
import ApplicationServices
import os.log

// MARK: - Permission state

struct LaunchPermissionStates: Equatable {
    var microphone: Bool = false
    var accessibility: Bool = false
    var screenRecording: Bool = false

    var allGranted: Bool {
        microphone && accessibility && screenRecording
    }

    var anyMissing: Bool { !allGranted }
}

// MARK: - Monitor

final class LaunchPermissionMonitor: ObservableObject {
    static let shared = LaunchPermissionMonitor()

    @Published private(set) var states = LaunchPermissionStates()

    private var alertWindow: LaunchPermissionAlertWindow?
    private var hasBootstrapped = false

    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "LaunchPermissionMonitor"
    )

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Called once from `AppDelegate.applicationDidFinishLaunching`.
    func bootstrap() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        DispatchQueue.main.async { [weak self] in
            self?.runInitialCheck()
        }
    }

    private func runInitialCheck() {
        guard UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else {
            logger.debug("Skipping launch permission check — onboarding not complete")
            return
        }
        guard !UserDefaults.standard.bool(forKey: "suppressLaunchPermissionAlert") else {
            logger.debug("Skipping launch permission check — suppressed by user")
            return
        }

        refreshAll()
        if states.anyMissing {
            showAlert()
        }
    }

    func refreshAll() {
        let newStates = LaunchPermissionStates(
            microphone: Self.isMicrophoneGranted,
            accessibility: Self.isAccessibilityGranted,
            screenRecording: Self.isScreenRecordingGranted
        )
        if newStates != states {
            states = newStates
        }
    }

    private func refreshAndMaybeDismiss() {
        refreshAll()
        if states.allGranted, alertWindow != nil {
            dismissAlert()
        }
    }

    @objc private func applicationDidBecomeActive() {
        guard alertWindow != nil else { return }
        refreshAndMaybeDismiss()
    }

    // MARK: - Presentation

    func showAlert() {
        if alertWindow == nil {
            alertWindow = LaunchPermissionAlertWindow(monitor: self)
        }
        alertWindow?.center()
        alertWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func dismissAlert() {
        alertWindow?.close()
        alertWindow = nil
    }

    /// Slide the alert window to the left edge so System Settings prompts are
    /// visible. Called when the user clicks Grant or Recheck.
    func moveAlertAside() {
        alertWindow?.moveAside()
    }

    // MARK: - Checks (side-effect-free)

    static var isMicrophoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static var isScreenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    // MARK: - Requests

    func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshAndMaybeDismiss() }
            }
        default:
            openPrivacyPane("Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacyPane("Privacy_Accessibility")
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        openPrivacyPane("Privacy_ScreenCapture")
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Window

final class LaunchPermissionAlertWindow: NSWindow {
    init(monitor: LaunchPermissionMonitor) {
        let rootView = LaunchPermissionAlertView(monitor: monitor)
        let hosting = DragSafeHostingView(rootView: rootView)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 660),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        level = .floating
        contentView = hosting
        center()
    }

    /// Slide the window to the left edge of the visible screen so System
    /// Settings prompts (typically centered) are not occluded.
    func moveAside() {
        guard let screen = screen ?? NSScreen.main else { return }
        var f = self.frame
        f.origin.x = screen.visibleFrame.minX + 20
        setFrame(f, display: true, animate: true)
    }
}

// MARK: - Hosting view

/// Disables window dragging when the cursor is over an interactive control,
/// so clicks on buttons land on the button instead of starting a drag.
final class DragSafeHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let hit, Self.isInteractiveControl(hit) {
            window?.isMovableByWindowBackground = false
        } else {
            window?.isMovableByWindowBackground = true
        }
        return hit
    }

    private static func isInteractiveControl(_ view: NSView) -> Bool {
        var current: NSView? = view
        for _ in 0..<6 {
            guard let v = current else { break }
            if v is NSButton || v is NSTextField || v is NSSlider
                || v is NSSegmentedControl || v is NSPopUpButton
                || v is NSSecureTextField || v is NSStepper {
                return true
            }
            current = v.superview
        }
        return false
    }
}

// MARK: - Button style

/// Stays accent-colored even when the window is inactive — `.borderedProminent`
/// dims to a flat translucent style when the window loses key, which makes the
/// Grant button nearly invisible after System Settings steals focus.
struct AlwaysProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isEnabled ? Color.accentColor : Color.accentColor.opacity(0.5))
                    .opacity(configuration.isPressed ? 0.8 : 1.0)
            )
    }
}

// MARK: - View

private struct LaunchPermissionAlertView: View {
    @ObservedObject var monitor: LaunchPermissionMonitor
    @AppStorage("suppressLaunchPermissionAlert") private var suppressAlert = false

    @State private var microphonePending = false
    @State private var accessibilityPending = false
    @State private var screenRecordingPending = false

    var body: some View {
        VStack(spacing: 16) {
            header

            firstTimeNotice

            VStack(spacing: 10) {
                row(
                    title: "Microphone",
                    description: "Required to record audio for transcription.",
                    icon: "mic.fill",
                    isGranted: { monitor.states.microphone },
                    pending: $microphonePending,
                    request: { monitor.requestMicrophone() }
                )
                row(
                    title: "Accessibility",
                    description: "Required to paste transcribed text at the cursor and read selected text.",
                    icon: "hand.raised.fill",
                    isGranted: { monitor.states.accessibility },
                    pending: $accessibilityPending,
                    request: { monitor.requestAccessibility() }
                )
                row(
                    title: "Screen Recording",
                    description: "Used by AI Enhancement to read on-screen context from the active window.",
                    icon: "rectangle.on.rectangle",
                    isGranted: { monitor.states.screenRecording },
                    pending: $screenRecordingPending,
                    request: { monitor.requestScreenRecording() }
                )
            }

            Spacer(minLength: 0)

            HStack {
                Toggle("Don't show this on launch", isOn: $suppressAlert)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Close") {
                    monitor.dismissAlert()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 540, height: 660)
        .onAppear { monitor.refreshAll() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Permissions Needed")
                .font(.title2)
                .fontWeight(.semibold)
            Text("VoiceInk needs the following access to work properly. Click Grant to open the system prompt or settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var firstTimeNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("First time on this build?", systemImage: "info.circle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.orange)

            Text("This is a community-patched build. Because it is signed with a different certificate than the official VoiceInk, macOS treats it as a different app — your existing permissions don't carry over.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                step("1.", "Open System Settings → Privacy & Security.")
                step("2.", "In each list below (Microphone, Accessibility, Screen Recording), find the existing VoiceInk entry and remove it with the “–” button.")
                step("3.", "Click Grant on each row here. macOS will re-add this build with the correct signature.")
            }

            Divider()
                .padding(.vertical, 2)

            Text("Automation (used for the AppleScript paste fallback and browser-URL detection) is handled separately — macOS prompts for it on first use. If you upgraded from the official build and that prompt never appears, run this in Terminal once, then relaunch VoiceInk:")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            Text("tccutil reset AppleEvents com.prakashjoshipax.voiceink")
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    private func step(_ num: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(num)
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(.orange)
                .frame(width: 16, alignment: .leading)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(
        title: String,
        description: String,
        icon: String,
        isGranted: @escaping () -> Bool,
        pending: Binding<Bool>,
        request: @escaping () -> Void
    ) -> some View {
        let granted = isGranted()
        return HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(granted ? .green : .orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else if pending.wrappedValue {
                Button("Recheck") {
                    monitor.refreshAll()
                    if isGranted() {
                        pending.wrappedValue = false
                    } else {
                        monitor.moveAlertAside()
                        request()
                    }
                }
                .buttonStyle(AlwaysProminentButtonStyle())
            } else {
                Button("Grant") {
                    pending.wrappedValue = true
                    monitor.moveAlertAside()
                    request()
                }
                .buttonStyle(AlwaysProminentButtonStyle())
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    granted ? Color.green.opacity(0.3) : Color.orange.opacity(0.4),
                    lineWidth: 1
                )
        )
    }
}
