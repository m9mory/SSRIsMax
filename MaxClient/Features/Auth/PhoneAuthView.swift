import SwiftUI

// MARK: - Вход по номеру телефона

struct PhoneAuthView: View {
    @EnvironmentObject private var session: Session
    @State private var phone = "+7 "
    @FocusState private var focused: Bool

    private var isPhoneValid: Bool {
        PhoneFormatter.normalize(phone) != nil
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 28) {
                Spacer()

                logo

                VStack(spacing: 8) {
                    Text("Войдите в MAX")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Введите номер телефона — пришлём код в SMS")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                phoneField

                if let error = session.auth.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }

                Button {
                    Task { await session.requestCode() }
                } label: {
                    HStack {
                        if session.auth.isLoading {
                            ProgressView().tint(.white)
                        }
                        Text("Получить код")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .disabled(session.auth.isLoading || !isPhoneValid)
                .opacity(isPhoneValid ? 1 : 0.5)

                Spacer()

                Text("Неофициальный клиент. Вход — по вашему номеру MAX, данные не покидают устройство, кроме самого мессенджера.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .sheet(isPresented: Binding(get: { session.auth.pendingToken != nil },
                                        set: { _ in })) {
                CodeEntryView()
                    .environmentObject(session)
                    .interactiveDismissDisabled()
            }
        }
        .onAppear { focused = true }
    }

    private var background: some View {
        LinearGradient(colors: [Theme.brand.opacity(0.16), Color.clear],
                       startPoint: .top,
                       endPoint: .center)
            .ignoresSafeArea()
    }

    private var logo: some View {
        Image(systemName: "bubble.left.and.bubble.right.fill")
            .font(.system(size: 58, weight: .semibold))
            .foregroundStyle(LinearGradient(colors: [Theme.brandGradientStart, Theme.brandGradientEnd],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing))
            .padding(.bottom, 4)
    }

    private var phoneField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Телефон")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("+7 999 123-45-67", text: $phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .focused($focused)
                .onChange(of: phone) { newValue in
                    let masked = PhoneFormatter.mask(newValue)
                    if masked != newValue { phone = masked }
                }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Код из SMS

struct CodeEntryView: View {
    @EnvironmentObject private var session: Session
    @State private var code = ""
    @FocusState private var focused: Bool
    @State private var shake = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "envelope.badge")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.brand)

                VStack(spacing: 6) {
                    Text("Введите код")
                        .font(.title2.weight(.bold))
                    Text("Мы отправили SMS на \(session.auth.phone)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                codeField

                if let error = session.auth.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task {
                        await session.confirmCode(code)
                        if session.auth.errorMessage != nil {
                            withAnimation(.default) { shake.toggle() }
                        }
                    }
                } label: {
                    HStack {
                        if session.auth.isLoading { ProgressView().tint(.white) }
                        Text("Войти").font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .disabled(code.count < session.auth.codeLength || session.auth.isLoading)
                .opacity(code.count < session.auth.codeLength ? 0.5 : 1)

                Button {
                    Task { await session.requestCode(isResend: true) }
                } label: {
                    if session.auth.resendAvailableIn > 0 {
                        Text("Отправить снова через \(session.auth.resendAvailableIn) с")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Отправить код повторно")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.brand)
                    }
                }
                .disabled(session.auth.resendAvailableIn > 0)

                Spacer()
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Назад") {
                        // Только отменяем ввод: Phase остаётся .unauthenticated,
                        // а phone сохраняется, чтобы не вводить его заново.
                        session.cancelCodeEntry()
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.large])
        .modifier(ShakeEffect(animatableData: CGFloat(shake ? 1 : 0)))
    }

    private var codeField: some View {
        VStack(spacing: 12) {
            ZStack {
                TextField("", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .opacity(0.01)
                    .frame(height: 1)
                    .onChange(of: code) { newValue in
                        let digits = String(newValue.filter(\.isNumber).prefix(session.auth.codeLength))
                        if digits != newValue {
                            code = digits
                            return
                        }
                        if digits.count == session.auth.codeLength {
                            Task { await session.confirmCode(digits) }
                        }
                    }

                HStack(spacing: 10) {
                    ForEach(0..<session.auth.codeLength, id: \.self) { index in
                        digitBox(index)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
            }
        }
        .padding(.vertical, 8)
    }

    private func digitBox(_ index: Int) -> some View {
        let characters = Array(code)
        let isFilled = index < characters.count
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isFilled ? Theme.brand : Color(uiColor: .separator), lineWidth: 1.5)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .frame(width: 46, height: 58)
            .overlay {
                Text(isFilled ? String(characters[index]) : "")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
            }
    }
}

/// Тряска при ошибке.
struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 3), y: 0))
    }
}
