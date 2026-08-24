import SwiftUI
import UIKit
import UserNotifications

/// Notification preferences.
///
/// Every switch here controls something real. For CloudKit-backed alerts (messages, reviews,
/// community, coverage) turning one off deletes the matching `CKQuerySubscription` from the public
/// database (see `PushService`), so the alerts genuinely stop. **Booking requests** are the exception:
/// those pushes come from the booking backend, so this toggle is sent to it
/// (`FloweBackendClient.setBookingNotifications`) and honoured server-side via `devices.notify_bookings`
/// — either way, the alerts truly stop rather than being hidden client-side.
///
/// Two switches were removed rather than left decorative:
/// - **Payouts.** Flowe processes no session money at all; students settle with the instructor
///   directly (BOOKING-SYSTEM.md § Payments). Offering payout alerts implies a capability the app
///   does not have, and every one of those notifications would have been a notification that never
///   arrives.
/// - **Product news & offers.** Nothing in the app or the CloudKit container can send a marketing
///   push — there is no campaign mechanism of any kind behind it.
///
/// A **Community replies** switch was added, because that notification does exist.
struct NotificationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(AppSession.self) private var session
    @Environment(PushService.self) private var push

    @AppStorage(NotificationPreference.bookings)  private var bookings = true
    @AppStorage(NotificationPreference.messages)  private var messages = true
    @AppStorage(NotificationPreference.reviews)   private var reviews = true
    @AppStorage(NotificationPreference.community) private var community = true
    @AppStorage(NotificationPreference.events)    private var events = true
    @AppStorage(NotificationPreference.reminders) private var reminders = true
    @AppStorage(NotificationPreference.coverage)  private var coverage = true
    @AppStorage(NotificationPreference.presence)  private var presence = false   // "last seen" is opt-in

    private var isInstructor: Bool { session.authState == .instructor }

    var body: some View {
        NavigationStack {
            Form {
                permissionSection

                Section {
                    toggle("Booking requests", "calendar", $bookings, id: "notifications.bookings")
                    toggle("Messages", "bubble.left", $messages, id: "notifications.messages")
                    // Reviews are written about instructors; a student never receives one.
                    if isInstructor {
                        toggle("Reviews", "star", $reviews, id: "notifications.reviews")
                    } else {
                        toggle("Community replies", "person.3", $community, id: "notifications.community")
                        toggle("New events", "calendar.badge.plus", $events, id: "notifications.events")
                    }
                    // Both roles: an instructor is offered cover and told when a claim lands; a
                    // student is told when their session will be taught by someone else.
                    toggle("Coverage", "arrow.triangle.2.circlepath", $coverage, id: "notifications.coverage")
                } header: {
                    Text("Activity")
                } footer: {
                    // One literal, never a `+` concatenation: `Text("a" + "b")` resolves to the
                    // `String` initializer and silently skips localization.
                    Text("Flowe doesn't process session payments — they're settled directly between student and instructor — so there are no payment alerts to send.")
                }

                Section {
                    toggle("Session reminders", "bell", $reminders, id: "notifications.reminders")
                } header: {
                    Text("Reminders")
                } footer: {
                    Text("An alert an hour before each confirmed session. Scheduled on this device, so it works offline.")
                }

                Section {
                    toggle("Show when I'm active", "dot.radiowaves.left.and.right", $presence, id: "notifications.presence")
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Let people you message see when you were last active. If you turn this off, you won't see their activity either.")
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
            .task { await push.refreshAuthorizationStatus() }
            // One observer for all five: each change is applied the same way, and grouping them
            // keeps a toggle from ever being added without being wired up.
            .onChange(of: [bookings, messages, reviews, community, events, reminders, coverage, presence]) { apply() }
        }
    }

    /// iOS asks for notification permission exactly once, so this screen has to be able to explain
    /// both outcomes: not yet asked (offer the prompt) and refused (only Settings can undo it).
    @ViewBuilder
    private var permissionSection: some View {
        switch push.authorizationStatus {
        case .notDetermined:
            Section {
                Button {
                    Task {
                        await push.requestAuthorization()
                        apply()
                    }
                } label: {
                    Label {
                        Text("Turn on notifications").font(FloweFont.sans(15))
                    } icon: {
                        Image(systemName: "bell.badge").foregroundStyle(Color.flowePinkDeep)
                    }
                }
                .accessibilityIdentifier("notifications.authorize")
            } footer: {
                Text("Flowe needs your permission before it can alert you.")
            }
        case .denied:
            Section {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Label {
                        Text("Open Settings").font(FloweFont.sans(15))
                    } icon: {
                        Image(systemName: "gear").foregroundStyle(Color.flowePinkDeep)
                    }
                }
                .accessibilityIdentifier("notifications.openSettings")
            } footer: {
                Text("Notifications are turned off for Flowe. The switches below stay saved, but nothing can be delivered until you allow notifications in iOS Settings.")
            }
        default:
            EmptyView()
        }
    }

    /// `LocalizedStringKey`, not `String` — `Text(someString)` renders the literal and never looks
    /// up a translation.
    private func toggle(_ title: LocalizedStringKey,
                        _ icon: String,
                        _ value: Binding<Bool>,
                        id: String) -> some View {
        Toggle(isOn: value) {
            Label {
                Text(title).font(FloweFont.sans(15))
            } icon: {
                Image(systemName: icon).foregroundStyle(Color.flowePinkDeep)
            }
        }
        .accessibilityIdentifier(id)
    }

    /// Push the preferences at the server. Creating and deleting subscriptions is idempotent, so
    /// this is safe to run on every flip.
    private func apply() {
        Task {
            await push.refreshSubscriptions(ownerID: session.ownerID, isInstructor: isInstructor)
            await push.scheduleSessionReminders()
            // Booking + review pushes come from the backend now, so their per-device preferences sync there.
            await FloweBackendClient.shared.setBookingNotifications(bookings)
            await FloweBackendClient.shared.setReviewNotifications(reviews)
            // Presence "last seen" opt-out is server-enforced (WhatsApp reciprocity).
            await FloweBackendClient.shared.setPresenceVisible(presence)
        }
    }
}
