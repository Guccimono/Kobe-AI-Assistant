import SwiftUI
import KobeKit

/// Settings › Connections › GitHub: the personal access token.
struct GitHubSettingsSection: View {
    let app: AppModel

    var body: some View {
        Card(eyebrow: "Integration", title: "GitHub") {
            KeyRow(app: app, service: .github, title: "Personal Access Token",
                   hint: "Classic token with repo scope, or fine-grained with read access to Pull requests, commit statuses, and Actions.",
                   create: GitHubLinks.tokens)
        }
    }
}
