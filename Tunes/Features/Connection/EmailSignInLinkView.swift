import AppKit
import SwiftUI

struct EmailSignInLinkView: View {
    @Bindable var session: SamplyWebSession
    var usesCapsule = false
    @State private var link = ""
    @State private var message: String?
    @State private var showsManualEntry = false
    @State private var isError = false
    @State private var showsLinkDetails = false
    @FocusState private var isLinkFocused: Bool

    var body: some View {
        Group {
            if usesCapsule {
                capsule
            } else {
                standardEntry
            }
        }
        .disabled(session.isSigningOut)
        .onChange(of: showsManualEntry) { _, expanded in
            isLinkFocused = expanded
            if !expanded { link = "" }
        }
        .onChange(of: showsLinkDetails) { _, expanded in
            if !expanded { link = "" }
        }
        .onChange(of: session.snapshot?.account?.uid) { _, _ in
            link = ""
            message = nil
            showsManualEntry = false
            showsLinkDetails = false
        }
        .onDisappear {
            link = ""
            message = nil
        }
    }

    private var capsule: some View {
        HStack(spacing: 12) {
            pasteButton
                .buttonStyle(.plain)
                .padding(.leading, 6)
            Divider()
                .frame(height: 18)
                .accessibilityHidden(true)
            Button {
                showsLinkDetails.toggle()
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Email sign-in options")
            .help("Enter a sign-in link manually")
            .popover(isPresented: $showsLinkDetails, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 16) {
                    instructions
                    manualEntry
                    feedback
                }
                .padding(20)
                .frame(width: 340)
                .onAppear { isLinkFocused = true }
            }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .compatGlass(interactive: true, in: .capsule)
        .fixedSize()
    }

    private var standardEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    instructions
                    Spacer(minLength: 0)
                    pasteButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    instructions
                    pasteButton
                }
            }

            DisclosureGroup("Enter link manually", isExpanded: $showsManualEntry) {
                manualEntry.padding(.top, 8)
            }
            .font(.callout)

            feedback
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField("Paste the full sign-in link", text: $link)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .privacySensitive()
                .focused($isLinkFocused)
                .onSubmit { openLink(link) }
            Button("Continue Sign-In") { openLink(link) }
                .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isSigningOut)
        }
    }

    @ViewBuilder private var feedback: some View {
        if let message {
            Label(message, systemImage: isError ? "exclamationmark.circle" : "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(message)
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Have your sign-in email?")
                .font(.callout.weight(.semibold))
            Text("Copy the sign-in link from your Samply email.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pasteButton: some View {
        Button {
            guard let candidate = NSPasteboard.general.string(forType: .string),
                  !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                isError = true
                message = "Copy the sign-in link from your email first, or enter it manually below."
                if usesCapsule { showsLinkDetails = true }
                return
            }
            openLink(candidate)
        } label: {
            Label("Paste Sign-In Link", systemImage: "document.on.clipboard")
        }
        .controlSize(.large)
        .help("Open the copied email sign-in link in Samply")
    }

    private func openLink(_ candidate: String) {
        link = ""
        do {
            try session.openEmailSignInLink(candidate)
            isError = false
            showsManualEntry = false
            message = "Link opened. Finish signing in in the Samply window."
            showsLinkDetails = false
        } catch {
            isError = true
            message = error.localizedDescription
            if usesCapsule { showsLinkDetails = true }
        }
    }
}
