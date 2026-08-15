import AppKit
import SwiftUI

enum XerTheme {
    static let action = Color(red: 0.196, green: 0.392, blue: 0.910)
    static var workspace: Color { Color(nsColor: .windowBackgroundColor) }
    static var inspector: Color { Color(nsColor: .textBackgroundColor) }
}

struct FullWidthMenuLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .contentShape(Rectangle())
    }
}

struct FullWidthMenuControl<MenuItems: View>: View {
    let title: String
    let systemImage: String
    private let menuItems: () -> MenuItems

    init(
        title: String,
        systemImage: String,
        @ViewBuilder menuItems: @escaping () -> MenuItems
    ) {
        self.title = title
        self.systemImage = systemImage
        self.menuItems = menuItems
    }

    var body: some View {
        ZStack {
            FullWidthMenuLabel(title: title, systemImage: systemImage)
                .allowsHitTesting(false)

            Menu {
                menuItems()
            } label: {
                Color.clear
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: 34)
        .contentShape(Rectangle())
    }
}
