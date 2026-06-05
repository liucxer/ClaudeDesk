import SwiftUI
import Foundation

struct PermissionDialog: View {
    let request: PendingPermission

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude wants to use")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(request.toolName)
                        .font(.title3.monospaced())
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Input")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(request.inputDescription)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 220)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Button("Deny", role: .destructive) {
                    PermissionGateway.shared.resolve(.deny(reason: "User denied"))
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Always Allow") {
                    Self.persistAllowRule(toolName: request.toolName, input: request.rawInput)
                    PermissionGateway.shared.resolve(.allow)
                }
                .help("Add a rule to ~/.claude/settings.json so this isn't asked again")

                Button("Allow Once") {
                    PermissionGateway.shared.resolve(.allow)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private static func persistAllowRule(toolName: String, input: [String: Any]) {
        let rule = formatAllowRule(toolName: toolName, input: input)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")

        // Make sure ~/.claude/ exists, otherwise the atomic write silently fails
        // on fresh installs that haven't run the CLI yet.
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = obj
        }

        var permissions = (settings["permissions"] as? [String: Any]) ?? [:]
        var allow = (permissions["allow"] as? [String]) ?? []
        if !allow.contains(rule) {
            allow.append(rule)
        }
        permissions["allow"] = allow
        settings["permissions"] = permissions

        if let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func formatAllowRule(toolName: String, input: [String: Any]) -> String {
        if toolName == "Bash", let cmd = input["command"] as? String {
            return "Bash(\(cmd))"
        }
        return toolName
    }
}
