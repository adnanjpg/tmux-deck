import AppKit
import SwiftTerm
import SwiftUI

/// Shows a session's terminal and keeps it on the selected window.
struct TerminalPane: View {
    let controller: TerminalController
    let window: TmuxWindow
    @State private var alive = true

    var body: some View {
        terminal
    }

    private var terminal: some View {
        TerminalHost(controller: controller)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: controller.view.nativeBackgroundColor))
            .overlay {
                if !alive {
                    ContentUnavailableView {
                        Label("Disconnected", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("Your tmux windows are still running on \(controller.remote.host).")
                    } actions: {
                        Button("Reconnect") { controller.reconnect(window: window.windowID) }
                            .keyboardShortcut(.defaultAction)
                    }
                    .background(.regularMaterial)
                }
            }
            .onAppear {
                DispatchQueue.main.async { controller.view.window?.makeFirstResponder(controller.view) }
                controller.onStateChange = { alive = controller.alive }
                controller.show(windowID: window.windowID, paneID: window.isPane ? window.paneID : nil)
                alive = controller.alive
            }
            .onChange(of: window.id) { _, _ in
                controller.show(windowID: window.windowID, paneID: window.isPane ? window.paneID : nil)
            }
            .onDisappear { controller.releaseZoom() }
    }
}

struct TerminalHost: NSViewRepresentable {
    let controller: TerminalController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if controller.view.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        let term = controller.view
        term.removeFromSuperview()
        term.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(term)
        NSLayoutConstraint.activate([
            term.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            term.topAnchor.constraint(equalTo: container.topAnchor),
            term.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
