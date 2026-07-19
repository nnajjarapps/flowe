import SwiftUI

/// Notification preferences. Toggles persist via `@AppStorage` (UserDefaults) so choices
/// survive relaunch. Shared by student and instructor settings.
struct NotificationSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("notif.bookings")  private var bookings = true
    @AppStorage("notif.messages")  private var messages = true
    @AppStorage("notif.reviews")   private var reviews = true
    @AppStorage("notif.payouts")   private var payouts = true
    @AppStorage("notif.reminders") private var reminders = true
    @AppStorage("notif.marketing") private var marketing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Activity") {
                    toggle("Booking requests", "calendar", $bookings)
                    toggle("Messages", "bubble.left", $messages)
                    toggle("Reviews", "star", $reviews)
                    toggle("Payouts", "dollarsign.circle", $payouts)
                }
                Section("Reminders") {
                    toggle("Session reminders", "bell", $reminders)
                }
                Section {
                    toggle("Product news & offers", "megaphone", $marketing)
                } footer: {
                    Text("Turn off anything you'd rather not hear about. Session and payment alerts are recommended.")
                }
            }
            .tint(Color.flowePinkDeep)
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Color.flowePinkDeep).fontWeight(.semibold)
                }
            }
        }
    }

    private func toggle(_ title: String, _ icon: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Label {
                Text(title).font(FloweFont.sans(15))
            } icon: {
                Image(systemName: icon).foregroundStyle(Color.flowePinkDeep)
            }
        }
    }
}

#Preview {
    NotificationSettingsView()
}
