import SwiftUI

/// Главный экран: чаты, контакты, настройки.
struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                ChatListView()
            }
            .tabItem { Label("Чаты", systemImage: "bubble.left.and.bubble.right.fill") }

            NavigationStack {
                ContactsPlaceholderView()
            }
            .tabItem { Label("Контакты", systemImage: "person.2.fill") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Ещё", systemImage: "ellipsis.circle.fill") }
        }
        .tint(Theme.brand)
    }
}

struct ContactsPlaceholderView: View {
    var body: some View {
        EmptyStateView(systemImage: "person.2",
                       title: "Контакты",
                       message: "Раздел в работе: поиск по номеру (opcode 46) и импорт адресной книги.")
            .navigationTitle("Контакты")
    }
}

/// Контакты — экран-заглушка, поэтому свой простой empty state
/// вместо `ContentUnavailableView` (тот добавили только в iOS 17).
struct EmptyStateView: View {
    var systemImage: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
