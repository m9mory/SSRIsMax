import SwiftUI

struct ChatListView: View {
    @EnvironmentObject private var session: Session
    @State private var search = ""

    private var filtered: [MaxChat] {
        guard !search.isEmpty else { return session.chats }
        return session.chats.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if let profile = session.profile {
                Section {
                    NavigationLink(value: Route.profile) {
                        ProfileHeaderRow(profile: profile,
                                         connection: session.connectionState)
                    }
                    .listRowBackground(Theme.brand.opacity(0.08))
                }
            }

            if session.connectionState == .offline {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "wifi.slash")
                        Text("Нет соединения — показываем сохранённые чаты")
                            .font(.footnote)
                        Spacer()
                        Button("Повторить") {
                            Task { await session.reconnect() }
                        }
                        .font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(.orange)
                }
            }

            Section {
                ForEach(filtered) { chat in
                    NavigationLink(value: Route.chat(chat.id)) {
                        ChatRow(chat: chat)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            Task { await session.markChatRead(chat.id) }
                        } label: {
                            Label("Прочитано", systemImage: "checkmark.message.fill")
                        }
                        .tint(.green)
                    }
                }
            } header: {
                Text(filtered.isEmpty && !search.isEmpty ? "Ничего не найдено" : "Чаты")
            }
        }
        .listStyle(.plain)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск чатов")
        .refreshable {
            await session.pullChats()
        }
        .navigationTitle("SSRIsMax")
        .navigationDestination(for: Route.self) { route in
            switch route {
            case .chat(let id):
                ChatView(chatID: id)
            case .profile:
                ProfileView()
            }
        }
        .overlay {
            if session.chats.isEmpty && session.connectionState != .offline {
                EmptyStateView(systemImage: "bubble.left.and.bubble.right",
                               title: "Пока нет чатов",
                               message: "Чаты появятся здесь после первой синхронизации с сервером.")
                    .overlay(alignment: .bottom) {
                        Button("Обновить") {
                            Task { await session.pullChats() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.brand)
                        .padding(.bottom, 60)
                    }
            }
        }
    }
}

enum Route: Hashable {
    case chat(MaxChatID)
    case profile
}

struct ProfileHeaderRow: View {
    var profile: MaxUser
    var connection: MaxClient.ConnectionState

    var body: some View {
        HStack(spacing: 14) {
            AvatarView(url: profile.avatarURL, title: profile.fullName, id: profile.id, size: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.fullName)
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    private var statusText: String {
        switch connection {
        case .online: return "Онлайн · " + (profile.phoneNumber ?? "")
        case .connecting: return "Подключаемся…"
        case .offline: return "Нет соединения"
        case .idle: return profile.phoneNumber ?? ""
        }
    }
}

struct ChatRow: View {
    var chat: MaxChat

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(url: chat.avatarURL, title: chat.title, id: chat.id, size: 56)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(chat.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    if chat.type == .channel {
                        Image(systemName: "megaphone.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if chat.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(ChatFormatter.time(chat.lastMessage?.timestamp ?? chat.lastEventTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Text(ChatFormatter.preview(chat.lastMessage))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Spacer(minLength: 4)

                    if chat.unreadCount > 0 {
                        Text("\(min(chat.unreadCount, 999))")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.brand, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
