import SwiftUI
import PluginKitUI

/// Shown along the bottom of the window, below the status bar, while the vault runs in safe mode. Part of the host, not a plugin: it must
/// show when plugins are left out.
struct SafeModeBanner: View {
    let restart: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(symbol: "exclamationmark.shield")
            Text("Safe mode: only essential plugins are loaded; plugins from this vault are off.")
            Spacer(minLength: 0)
            Button("Restart Normally") { restart() }
                .controlSize(.small)
        }
        .font(.ui(.label))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.18))
    }
}
