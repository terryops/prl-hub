import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// ============================================================
// Screen-capture protection for the seed (助记词)
// ------------------------------------------------------------
// The mnemonic is the wallet's only backup. We:
//   • macOS — exclude the hosting window from screenshots AND screen recording
//     by flipping NSWindow.sharingType to .none while the seed is on screen.
//     This is a genuine hard block: captures of the window come back blank.
//   • iOS  — there is NO public API to block a user screenshotting their own
//     screen, so we do the two things the platform DOES allow:
//       (1) redact the seed while the screen is being recorded / AirPlay-mirrored
//           (UIScreen.isCaptured), so it never lands in a recording;
//       (2) detect the screenshot (userDidTakeScreenshotNotification) and tell the
//           caller to immediately re-hide the seed + warn the user.
//     Combined with removing the "copy mnemonic" button, this is the strongest
//     protection available without private APIs.
// ============================================================

/// Observes live screen-capture state and screenshot events for the current screen.
@MainActor
final class ScreenCaptureMonitor: ObservableObject {
    /// True while the screen is being recorded or mirrored (iOS). Always false on macOS
    /// (there the window is hard-excluded from capture instead).
    @Published var isCaptured = false
    /// Invoked when the user takes a screenshot (iOS only).
    var onScreenshot: () -> Void = {}

    private var tokens: [NSObjectProtocol] = []

    init() {
        #if os(iOS)
        isCaptured = UIScreen.main.isCaptured
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: UIScreen.capturedDidChangeNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isCaptured = UIScreen.main.isCaptured }
        })
        tokens.append(nc.addObserver(forName: UIApplication.userDidTakeScreenshotNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onScreenshot() }
        })
        #endif
    }

    deinit {
        let nc = NotificationCenter.default
        tokens.forEach { nc.removeObserver($0) }
    }
}

extension View {
    /// Protect sensitive content (the seed) from screen capture while `active`.
    /// On iOS, `onScreenshot` fires when a screenshot is taken so the caller can
    /// re-hide the content and warn.
    func screenCaptureProtected(active: Bool, onScreenshot: @escaping () -> Void = {}) -> some View {
        modifier(ScreenCaptureProtection(active: active, onScreenshot: onScreenshot))
    }
}

private struct ScreenCaptureProtection: ViewModifier {
    let active: Bool
    let onScreenshot: () -> Void
    @StateObject private var monitor = ScreenCaptureMonitor()

    func body(content: Content) -> some View {
        content
            .onAppear { monitor.onScreenshot = active ? onScreenshot : {} }
            .onChange(of: active) { _, a in monitor.onScreenshot = a ? onScreenshot : {} }
        #if os(iOS)
            .overlay {
                if active && monitor.isCaptured {
                    ZStack {
                        Rectangle().fill(.ultraThickMaterial)
                        VStack(spacing: Pearl.Space.sm) {
                            Image(systemName: "eye.slash.fill").font(.title)
                            Text(Loc("检测到录屏 / 投屏，已隐藏助记词"))
                                .font(.callout).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.secondary)
                        .padding(Pearl.Space.lg)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.snappy, value: monitor.isCaptured)
        #elseif os(macOS)
            .background(WindowSharingGuard(active: active))
        #endif
    }
}

#if os(iOS)
// ------------------------------------------------------------
// Genuine capture block for the seed (iOS): host the content inside a secure
// UITextField's render canvas. iOS blanks secure-entry content in BOTH screenshots
// AND screen recordings, so the wrapped content never lands in a capture — unlike the
// post-screenshot re-hide, which is too late (the shot already has the seed). If the
// private canvas view can't be located on this OS version, the content still renders
// normally — the legitimate user must never lose sight of their own seed.
// ------------------------------------------------------------
struct CaptureProtected<Content: View>: UIViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeUIView(context: Context) -> CaptureProtectedView {
        let v = CaptureProtectedView()
        v.mount(context.coordinator.host.view)
        return v
    }
    func updateUIView(_ uiView: CaptureProtectedView, context: Context) {
        context.coordinator.host.rootView = content()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CaptureProtectedView, context: Context) -> CGSize? {
        context.coordinator.host.sizeThatFits(in: proposal.replacingUnspecifiedDimensions())
    }
    func makeCoordinator() -> Coordinator { Coordinator(content()) }

    final class Coordinator {
        let host: UIHostingController<Content>
        init(_ content: Content) {
            host = UIHostingController(rootView: content)
            host.view.backgroundColor = .clear
        }
    }
}

/// UIView whose subtree lives inside a secure text field's canvas → excluded from captures.
final class CaptureProtectedView: UIView {
    private let field = UITextField()
    private var content: UIView?
    private var securelyMounted = false
    private var mountAttempts = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        field.isSecureTextEntry = true
        field.isUserInteractionEnabled = false
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        pin(field, to: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func mount(_ view: UIView) {
        content = view
        view.backgroundColor = .clear
        view.alpha = 0          // stay invisible until reparented into the secure canvas, so
        addSubview(view)        // the seed can't be captured in the gap before that happens
        pin(view, to: self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !securelyMounted, let content else { return }
        guard let canvas = field.subviews.first(where: {
            String(describing: type(of: $0)).contains("Canvas")
        }) else {
            // Canvas not ready yet → retry next pass. If it never appears (a future iOS
            // renamed the private view), reveal the content unprotected after a few passes
            // rather than leave the legitimate user unable to see their own seed.
            mountAttempts += 1
            if mountAttempts >= 8 { content.alpha = 1; securelyMounted = true }
            return
        }
        content.removeFromSuperview()
        canvas.addSubview(content)
        canvas.isUserInteractionEnabled = false
        pin(content, to: canvas)
        content.alpha = 1
        securelyMounted = true
    }

    private func pin(_ v: UIView, to parent: UIView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: parent.topAnchor),
            v.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }
}
#endif

#if os(macOS)
/// Flips the hosting NSWindow's `sharingType` so screenshots & screen recordings
/// of this window are blocked while `active`, restoring normal sharing otherwise.
private struct WindowSharingGuard: NSViewRepresentable {
    let active: Bool

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        apply(from: v)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(from: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.window?.sharingType = .readWrite
    }

    private func apply(from view: NSView) {
        let want: NSWindow.SharingType = active ? .none : .readWrite
        // Apply synchronously when the window is already attached (the usual case once the
        // seed view is on screen) so there's no one-runloop gap of capturable frames; fall
        // back to async only on first make, before the view has joined a window.
        if let window = view.window {
            if window.sharingType != want { window.sharingType = want }
            return
        }
        DispatchQueue.main.async {
            guard let window = view.window, window.sharingType != want else { return }
            window.sharingType = want
        }
    }
}
#endif
