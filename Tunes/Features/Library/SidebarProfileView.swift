import SwiftUI

/// Profile layout adapted from Kaset's SidebarProfileView, without account controls.
struct SidebarProfileView: View {
    let account: WebSnapshot.Account
    var avatarData: Data?

    private var avatar: NSImage? { avatarData.flatMap(NSImage.init(data:)) }

    private var displayName: String {
        let name = account.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Samply Account" : name
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color(hue: account.avatarHue, saturation: 6.0 / 7.0, brightness: 0.63))
                if let avatar {
                    Image(nsImage: avatar)
                        .resizable()
                        .scaledToFill()
                } else if !account.avatarInitials.isEmpty {
                    Text(account.avatarInitials)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(.circle)
            .accessibilityHidden(true)

            Text(displayName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Profile: \(displayName)")
        .accessibilityIdentifier("sidebarProfile")
        .help(displayName)
    }
}
