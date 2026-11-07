import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var session: Session
    @State private var showLogoutConfirm = false

    var body: some View {
        List {
            if let profile = session.profile {
                Section {
                    HStack(spacing: 16) {
                        AvatarView(url: profile.avatarURL, title: profile.fullName, id: profile.id, size: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.fullName).font(.title3.weight(.semibold))
                            if let phone = profile.phoneNumber {
                                Text(phone).font(.subheadline).foregroundStyle(.secondary)
                            }
                            if let about = profile.about, !about.isEmpty {
                                Text(about).font(.footnote).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("Аккаунт") {
                    LabeledContent("ID", value: String(profile.id))
                    LabeledContent("Соединение", value: connectionTitle)
                }
            }

            Section {
                Button(role: .destructive) {
                    showLogoutConfirm = true
                } label: {
                    Text("Выйти из аккаунта").frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Профиль")
        .confirmationDialog("Выйти из аккаунта?",
                            isPresented: $showLogoutConfirm,
                            titleVisibility: .visible) {
            Button("Выйти", role: .destructive) {
                Task { await session.logout() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Локальная копия переписки будет удалена, для входа понадобится новый SMS-код.")
        }
    }

    private var connectionTitle: String {
        switch session.connectionState {
        case .online: return "Подключено"
        case .connecting: return "Подключение…"
        case .offline: return "Офлайн"
        case .idle: return "Ожидание"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var session: Session
    @State private var showClearCacheConfirm = false

    var body: some View {
        Form {
            Section("Профиль") {
                if let profile = session.profile {
                    NavigationLink {
                        ProfileView()
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(url: profile.avatarURL, title: profile.fullName, id: profile.id, size: 44)
                            VStack(alignment: .leading) {
                                Text(profile.fullName).font(.headline)
                                Text(profile.phoneNumber ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Внешний вид") {
                Picker("Тема", selection: Binding(
                    get: { settings.settings.theme },
                    set: { newValue in settings.update { $0.theme = newValue } }
                )) {
                    Text("Системная").tag("system")
                    Text("Светлая").tag("light")
                    Text("Тёмная").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section("Соединение") {
                Picker("Транспорт", selection: Binding(
                    get: { settings.settings.transport },
                    set: { newValue in settings.update { $0.transport = newValue } }
                )) {
                    ForEach(AppSettings.TransportMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text("Изменение транспорта применится после перезапуска приложения. Если WebSocket не работает — попробуйте TCP (MessagePack), как в официальных клиентах.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Приватность") {
                Toggle("Отправлять отметки о прочтении", isOn: Binding(
                    get: { settings.settings.sendReadReceipts },
                    set: { newValue in settings.update { $0.sendReadReceipts = newValue } }
                ))
            }

            Section("Кеш") {
                Button(role: .destructive) {
                    showClearCacheConfirm = true
                } label: {
                    Text("Очистить локальную переписку")
                }
                Text("Серверные сообщения не удаляются: история подгрузится заново при открытии чата.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("О приложении") {
                LabeledContent("Версия", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                LabeledContent("Протокол", value: "api.oneme.ru · ver \(MaxProtocol.jsonVersion)/\(MaxProtocol.binaryVersion)")
                NavigationLink("О неофициальном клиенте") {
                    AboutView()
                }
            }
        }
        .navigationTitle("Настройки")
        .confirmationDialog("Очистить локальную переписку?",
                            isPresented: $showClearCacheConfirm,
                            titleVisibility: .visible) {
            Button("Очистить", role: .destructive) {
                Task { await session.clearLocalMessages() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Чаты останутся, сообщения подгрузятся с сервера при открытии.")
        }
    }
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Что это за клиент")
                    .font(.title3.weight(.semibold))
                Text("""
                    Это неофициальный клиент мессенджера MAX (VK) для iOS. Он написан на SwiftUI и общается \
                    с тем же сервером, что и официальные приложения, по протоколу, восстановленному \
                    сообществом по сетевому трафику.

                    Что это значит на практике:
                    • Сервер MAX может измениться в любой момент, и клиент перестанет работать — без предупреждения.
                    • Условия использования MAX могут запрещать сторонние клиенты. Аккаунт может быть заблокирован.
                    • Не вводите сюда чужой номер: SMS-код подтверждения — это доступ к аккаунту.

                    Код открытый: его можно изучить, поправить и запустить у себя.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .navigationTitle("О приложении")
        .navigationBarTitleDisplayMode(.inline)
    }
}
