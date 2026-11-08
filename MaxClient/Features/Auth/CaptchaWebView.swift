import SwiftUI
import WebKit

// MARK: - Прохождение VK Captcha

/// Показывает страницу капчи во встроенном браузере.
///
/// Пройти капчу за пользователя нельзя: это серверная проверка на
/// «человечность», и MAX выдаёт SMS только после неё. Что можно — не
/// выкидывать человека в Safari: страница открывается прямо в
/// приложении, а `captchaToken`, который она получает после решения,
/// подхватывается автоматически и уходит в VERIFICATION_REQUEST.
///
/// Страница `id.vk.ru/not_robot_captcha` — JS-приложение без серверного
/// редиректа, поэтому токен вычитывается опросом (адрес, хранилища,
/// известные глобальные переменные), а не одним перехватом навигации.
struct CaptchaWebView: UIViewRepresentable {
    let url: URL
    let onToken: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Капча VK живёт в своём домене и ставит куки — без этого
        // проверка не завершится.
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    /// Делегат WebKit вызывает методы на главном потоке, поэтому весь
    /// класс помечен @MainActor — иначе `finished`/`pollTask` менялись бы
    /// из разных потоков без синхронизации.
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onToken: (String) -> Void
        private var finished = false
        private var pollTask: Task<Void, Never>?

        init(onToken: @escaping (String) -> Void) {
            self.onToken = onToken
        }

        deinit {
            pollTask?.cancel()
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Быстрый путь: если капча вернула токен редиректом —
            // забираем прямо из адреса.
            if let url = navigationAction.request.url,
               let token = MaxAuthService.captchaToken(from: url),
               !token.isEmpty {
                finish(token)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Страница id.vk.ru — это JS-приложение: серверного редиректа
            // с токеном нет, токен появляется в JS после решения капчи.
            // Поэтому периодически опрашиваем страницу.
            startPolling(webView)
        }

        private func startPolling(_ webView: WKWebView) {
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard let self, !self.finished else { return }
                    if let token = await self.readToken(from: webView), !token.isEmpty {
                        self.finish(token)
                        return
                    }
                }
            }
        }

        /// Ищет токен в известных местах, куда его кладёт страница VK.
        private func readToken(from webView: WKWebView) async -> String? {
            let script = """
            (function () {
              try {
                var href = (location.href || '');
                var m = href.match(/[?&](captcha_token|captchaToken|token)=([^&#]+)/);
                if (m) { return decodeURIComponent(m[2]); }
                var store = window.localStorage, sess = window.sessionStorage;
                var keys = ['captcha_token','captchaToken','not_robot_token'];
                for (var i = 0; i < keys.length; i++) {
                  var v = (store && store.getItem(keys[i])) || (sess && sess.getItem(keys[i]));
                  if (v) { return v; }
                }
                if (window.__captchaToken) { return window.__captchaToken; }
              } catch (e) {}
              return null;
            })();
            """
            return await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(script) { value, _ in
                    continuation.resume(returning: value as? String)
                }
            }
        }

        private func finish(_ token: String) {
            guard !finished else { return }
            finished = true
            pollTask?.cancel()
            pollTask = nil
            onToken(token)
        }
    }
}

// MARK: - Экран проверки

struct CaptchaSheet: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        NavigationStack {
            Group {
                if let url = session.auth.captchaURL {
                    CaptchaWebView(url: url) { token in
                        Task { await session.completeCaptcha(token: token) }
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView("Готовим проверку…")
                }
            }
            .navigationTitle("Проверка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        session.cancelCaptcha()
                    }
                }
            }
        }
    }
}
