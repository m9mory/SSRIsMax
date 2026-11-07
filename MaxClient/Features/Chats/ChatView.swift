import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Экран переписки: пузыри, поле ввода, подгрузка истории, реакции.
struct ChatView: View {
    let chatID: MaxChatID

    @EnvironmentObject private var session: Session
    @State private var messages: [MaxMessage] = []
    @State private var draft = ""
    @State private var isLoadingOlder = false
    @State private var hasMoreHistory = true

    private var chat: MaxChat? {
        session.chats.first(where: { $0.id == chatID })
    }

    private var isTyping: Bool {
        session.typingUserIDs[chatID] != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if hasMoreHistory {
                            ProgressView()
                                .padding(.vertical, 8)
                                .onAppear {
                                    Task { await loadOlder() }
                                }
                        }

                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            let previous = index > 0 ? messages[index - 1] : nil
                            MessageBubble(message: message,
                                          isOutgoing: isOutgoing(message),
                                          showsTail: showsHead(index: index, previous: previous))
                                .id(message.id)
                                .contextMenu {
                                    if !message.text.isEmpty {
                                        Button {
                                            copy(message.text)
                                        } label: {
                                            Label("Копировать", systemImage: "doc.on.doc")
                                        }
                                    }
                                    if isOutgoing(message) {
                                        Button(role: .destructive) {
                                            Task {
                                                await session.deleteMessage(message, in: chatID)
                                                await reload()
                                            }
                                        } label: {
                                            Label("Удалить", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: isTyping) { _ in
                    scrollToBottom(proxy)
                }
            }

            typingIndicator
            composer
        }
        .background(Theme.chatBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(chat?.title ?? "Чат")
                        .font(.headline)
                    if isTyping {
                        Text("печатает…")
                            .font(.caption2)
                            .foregroundStyle(Theme.brand)
                    } else if chat?.type == .chat {
                        Text("\(chat?.participantsCount ?? 0) участников")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            await session.openChat(chatID)
            await reload()
            if let last = messages.last {
                session.markRead(chatID: chatID, message: last)
            }
        }
        .onDisappear {
            session.closeChat()
        }
    }

    // MARK: - Данные

    private func reload() async {
        messages = await session.messages(chatID: chatID)
    }

    private func loadOlder() async {
        guard hasMoreHistory, !isLoadingOlder, let first = messages.first else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }

        let older = await session.loadOlder(chatID: chatID, before: first.timestamp)
        let existing = Set(messages.map(\.id))
        let fresh = older.filter { !existing.contains($0.id) }
        // Пустая страница = история закончилась; иначе спиннер ушёл бы в цикл.
        hasMoreHistory = !fresh.isEmpty
        messages = fresh + messages
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = messages.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private func isOutgoing(_ message: MaxMessage) -> Bool {
        message.senderID == session.profile?.id
    }

    /// Начало серии сообщений одного автора — нужен отступ.
    private func showsHead(index: Int, previous: MaxMessage?) -> Bool {
        guard let previous else { return true }
        let current = messages[index]
        return previous.senderID != current.senderID
            || current.timestamp - previous.timestamp > 5 * 60 * 1000
    }

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    // MARK: - UI

    @ViewBuilder
    private var typingIndicator: some View {
        if isTyping {
            HStack {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 6, height: 6)
                            .opacity(0.6)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.incomingBubble, in: Capsule())
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .transition(.opacity)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Сообщение", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .onChange(of: draft) { _ in
                    session.sendTyping(chatID: chatID)
                }

            Button {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                draft = ""
                Task {
                    await session.send(text: text, to: chatID)
                    await reload()
                }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(canSend ? Theme.brand : Color.secondary.opacity(0.4), in: Circle())
            }
            .disabled(!canSend)
            .padding(.bottom, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Пузырь сообщения

struct MessageBubble: View {
    var message: MaxMessage
    var isOutgoing: Bool
    var showsTail: Bool

    var body: some View {
        HStack {
            if isOutgoing { Spacer(minLength: 48) }

            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                if let attachment = message.attachments.first(where: { $0.kind == .photo || $0.kind == .video }) {
                    AttachmentPreview(attachment: attachment)
                }

                if !message.text.isEmpty {
                    Text(MessageText.attributed(message))
                        .font(.system(size: 16))
                        .foregroundStyle(isOutgoing ? .white : .primary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 4) {
                    if message.status == .edited {
                        Text("изм.")
                    }
                    Text(ChatFormatter.time(message.timestamp))
                    if isOutgoing {
                        statusIcon
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(isOutgoing ? Color.white.opacity(0.75) : Color.secondary)

                if let reactions = message.reactions, !reactions.counters.isEmpty {
                    ReactionBar(info: reactions)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isOutgoing ? Theme.outgoingBubble : Theme.incomingBubble)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: 300, alignment: isOutgoing ? .trailing : .leading)

            if !isOutgoing { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
        .padding(.top, showsTail ? 8 : 1)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.status {
        case .sending:
            Image(systemName: "clock")
        case .failed:
            Image(systemName: "exclamationmark.circle").foregroundStyle(.yellow)
        default:
            Image(systemName: "checkmark")
        }
    }
}

// MARK: - Разметка текста

/// `elements[]` → AttributedString (ссылки, жирный, курсив, подчёркивание).
enum MessageText {
    static func attributed(_ message: MaxMessage) -> AttributedString {
        var result = AttributedString(message.text)
        let characters = Array(message.text)

        // Смещения из протокола — в символах Unicode.
        func index(at offset: Int) -> AttributedString.Index? {
            guard offset >= 0, offset <= characters.count else { return nil }
            let prefix = String(characters[0..<offset])
            return result.index(result.startIndex, offsetByCharacters: prefix.count)
        }

        for element in message.elements {
            guard let lower = index(at: element.range.lowerBound),
                  let upper = index(at: min(element.range.upperBound, characters.count)),
                  lower <= upper else { continue }
            var range = lower..<upper
            switch element.kind {
            case .strong:
                result[range].inlinePresentationIntent = .stronglyEmphasized
            case .emphasized:
                result[range].inlinePresentationIntent = .emphasized
            case .underline:
                result[range].underlineStyle = .single
            case .link:
                if let url = element.url {
                    result[range].link = url
                    result[range].underlineStyle = .single
                }
            case .unknown:
                break
            }
            _ = range
        }
        return result
    }
}

// MARK: - Реакции и вложения

struct ReactionBar: View {
    var info: MaxReactionInfo

    var body: some View {
        HStack(spacing: 4) {
            ForEach(info.counters) { counter in
                HStack(spacing: 2) {
                    Text(counter.reaction)
                    Text("\(counter.count)").font(.caption2)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: Capsule())
            }
        }
    }
}

struct AttachmentPreview: View {
    var attachment: MaxAttachment

    var body: some View {
        Group {
            if let url = attachment.thumbnailURL ?? attachment.url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    default:
                        placeholder.overlay(ProgressView())
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 220, height: 165)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            Color.primary.opacity(0.08)
            Image(systemName: "photo")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}