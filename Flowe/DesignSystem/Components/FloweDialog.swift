import SwiftUI

// ============================================================================
// FloweDialog — the app's own confirmation/message dialog.
//
// Replaces `.alert` and `.confirmationDialog`, which render in the SYSTEM's
// chrome: SF Pro, iOS blue, square-cornered sheet. Every one of those was a
// hole in the brand — the user leaves Flowe's world for a moment at exactly
// the point they are being asked to commit to something.
//
// WHAT THIS CANNOT REPLACE. These are drawn by the OS, out of process, and no
// app can restyle or pre-empt them:
//   • Sign in with Apple
//   • StoreKit purchase / "Confirm with Face ID"
//   • Notification, photo, camera and location permission prompts
//   • The share sheet
// Where one of those is coming, the honest move is to prepare the user with a
// Flowe screen FIRST (as the paywall and the push pre-prompt already do), not
// to pretend the system sheet isn't about to appear.
// ============================================================================

/// One button in a `FloweDialog`.
struct FloweDialogAction: Identifiable {
    enum Role { case normal, destructive, cancel }

    let id = UUID()
    let title: LocalizedStringKey
    let role: Role
    let action: () -> Void

    init(_ title: LocalizedStringKey, role: Role = .normal, action: @escaping () -> Void = {}) {
        self.title = title
        self.role = role
        self.action = action
    }
}

// MARK: - The dialog surface

private struct FloweDialogSurface: View {
    let title: Text
    let message: Text?
    let actions: [FloweDialogAction]
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Cancel is rendered last and quietly, matching the ordering people already expect from iOS.
    private var ordered: [FloweDialogAction] {
        actions.filter { $0.role != .cancel } + actions.filter { $0.role == .cancel }
    }

    var body: some View {
        ZStack {
            // Scrim. Tapping it is equivalent to Cancel — but ONLY when a cancel exists, so a
            // dialog that demands an explicit choice can't be dismissed by a stray tap.
            Color.floweInk.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture {
                    guard let cancel = actions.first(where: { $0.role == .cancel }) else { return }
                    cancel.action()
                    dismiss()
                }
                .accessibilityHidden(true)

            VStack(spacing: FlowSpacing.lg) {
                VStack(spacing: FlowSpacing.sm) {
                    title
                        .flowFont(.titleLarge)
                        .foregroundStyle(Color.floweInk)
                        .multilineTextAlignment(.center)

                    if let message {
                        message
                            .flowFont(.bodyMedium)
                            .foregroundStyle(Color.floweMuted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, FlowSpacing.xs)

                VStack(spacing: FlowSpacing.sm) {
                    ForEach(ordered) { action in
                        Button {
                            // Warning haptic on a destructive commit, a plain tick otherwise — the
                            // same split the rest of the app uses.
                            if action.role == .destructive { Haptic.warning() } else { Haptic.tap() }
                            // ACTION FIRST, then dismiss — never the other way round. Callers routinely
                            // drive this dialog from an optional (`deleteTarget != nil`) whose binding
                            // setter clears that optional on dismiss, and then read it back inside the
                            // action. Dismissing first nils the value before the action can see it, so
                            // the action silently does nothing — which is exactly how "Delete
                            // conversation" became a no-op. The `.alert(_:isPresented:presenting:)` API
                            // this replaced handed the value to the action for precisely this reason;
                            // running in this order restores that guarantee for every caller at once.
                            action.action()
                            dismiss()
                        } label: {
                            Text(action.title)
                                .flowFont(.titleMedium)
                                .foregroundStyle(foreground(action.role))
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(background(action.role))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(stroke(action.role), lineWidth: 1)
                                )
                        }
                        .flowePressable()
                        .accessibilityIdentifier("dialog.\(action.role)")
                    }
                }
            }
            .padding(FlowSpacing.xl)
            .frame(maxWidth: 340)
            .background(Color.floweCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.floweBorder, lineWidth: 1)
            )
            .shadow(color: Color.flowePink.opacity(0.18), radius: 28, x: 0, y: 12)
            .shadow(color: Color.floweInk.opacity(0.10), radius: 6, x: 0, y: 2)
            .padding(.horizontal, FlowSpacing.xl)
            // Under Reduce Motion the scale is dropped and only the fade remains, matching
            // `FlowePressStyle`.
            .scaleEffect(reduceMotion ? 1 : 1)
            .transition(
                reduceMotion
                    ? .opacity
                    : .scale(scale: 0.94).combined(with: .opacity)
            )
        }
        // One container the reader lands in, rather than 4 loose elements behind the scrim.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func foreground(_ role: FloweDialogAction.Role) -> Color {
        switch role {
        case .normal:      return Color.flowWhite
        case .destructive: return Color.flowWhite
        case .cancel:      return Color.floweInk
        }
    }

    private func background(_ role: FloweDialogAction.Role) -> some ShapeStyle {
        switch role {
        // `flowePinkDeep`, not `flowePink`: white-on-pink fails AA at the lighter tint.
        case .normal:      return AnyShapeStyle(Color.flowePinkDeep)
        case .destructive: return AnyShapeStyle(Color.floweCancel)
        case .cancel:      return AnyShapeStyle(Color.clear)
        }
    }

    private func stroke(_ role: FloweDialogAction.Role) -> Color {
        role == .cancel ? Color.floweBorder : .clear
    }
}

// MARK: - Modifiers

extension View {
    /// General N-button dialog taking pre-built `Text` — the form to use when the copy is a RUNTIME
    /// string (a validation reason, a server error). Passing such a string as `LocalizedStringKey`
    /// would send it through the String Catalog as a lookup key and render it raw on a miss.
    func floweDialog(
        isPresented: Binding<Bool>,
        titleText: Text,
        messageText: Text? = nil,
        actions: [FloweDialogAction]
    ) -> some View {
        overlay {
            if isPresented.wrappedValue {
                FloweDialogSurface(title: titleText, message: messageText, actions: actions) {
                    isPresented.wrappedValue = false
                }
            }
        }
        .animation(FloweMotion.spring, value: isPresented.wrappedValue)
    }

    /// General N-button dialog with localized copy. Prefer the convenience forms below.
    func floweDialog(
        isPresented: Binding<Bool>,
        title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        actions: [FloweDialogAction]
    ) -> some View {
        floweDialog(isPresented: isPresented,
                    titleText: Text(title),
                    messageText: message.map { Text($0) },
                    actions: actions)
    }

    /// The common case: confirm-or-cancel. `isDestructive` colours the commit button and
    /// switches the haptic.
    func floweConfirm(
        isPresented: Binding<Bool>,
        title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        confirmTitle: LocalizedStringKey,
        isDestructive: Bool = false,
        cancelTitle: LocalizedStringKey = "Cancel",
        onConfirm: @escaping () -> Void
    ) -> some View {
        floweDialog(isPresented: isPresented, title: title, message: message, actions: [
            FloweDialogAction(confirmTitle, role: isDestructive ? .destructive : .normal, action: onConfirm),
            FloweDialogAction(cancelTitle, role: .cancel),
        ])
    }

    /// Acknowledge-only with a RUNTIME message (validation reason, server error). The title stays a
    /// localized key; only the body varies at runtime.
    func floweMessage(
        isPresented: Binding<Bool>,
        title: LocalizedStringKey,
        detail: String?,
        buttonTitle: LocalizedStringKey = "OK",
        onDismiss: @escaping () -> Void = {}
    ) -> some View {
        floweDialog(
            isPresented: isPresented,
            titleText: Text(title),
            messageText: (detail?.isEmpty == false) ? Text(verbatim: detail!) : nil,
            actions: [FloweDialogAction(buttonTitle, role: .cancel, action: onDismiss)]
        )
    }

    /// Acknowledge-only — the replacement for a one-button error `.alert`.
    func floweMessage(
        isPresented: Binding<Bool>,
        title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        buttonTitle: LocalizedStringKey = "OK",
        onDismiss: @escaping () -> Void = {}
    ) -> some View {
        floweDialog(isPresented: isPresented, title: title, message: message, actions: [
            FloweDialogAction(buttonTitle, role: .cancel, action: onDismiss),
        ])
    }
}

#Preview("Destructive") {
    Color.flowWarmCream.ignoresSafeArea()
        .floweConfirm(
            isPresented: .constant(true),
            title: "Log out of Flowe?",
            message: "Your profile, sessions and messages stay on your account — signing back in brings everything back.",
            confirmTitle: "Log Out",
            isDestructive: true
        ) {}
}

#Preview("Message") {
    Color.flowWarmCream.ignoresSafeArea()
        .floweMessage(
            isPresented: .constant(true),
            title: "Couldn't send",
            message: "Check your connection and try again."
        )
}
