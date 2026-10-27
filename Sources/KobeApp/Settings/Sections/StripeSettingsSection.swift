import SwiftUI
import KobeKit

/// Settings › Connections › Stripe: the read-only key Kobe uses for the balance and the last charges.
struct StripeSettingsSection: View {
    let app: AppModel

    var body: some View {
        @Bindable var settings = app.settings
        Card(eyebrow: "Integration", title: "Stripe") {
            KeyRow(app: app, service: .stripe, title: "Restricted key",
                   hint: "A restricted key with read access to Balance and Charges (rk_…). Full secret keys are refused.",
                   create: URL(string: "https://dashboard.stripe.com/apikeys"))
            SettingRow(title: "Hide amounts", detail: "Bank-style: every amount shows as €••• on the Stripe page and on Home. The eye on the page and ⌘H toggle it too.") {
                Toggle("", isOn: $settings.hideAmounts).toggleStyle(.switch).labelsHidden().tint(K.lime)
            }
        }
    }
}
