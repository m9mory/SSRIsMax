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
/// Страница `id.vk.ru/not_robot_captcha` — это JS-приложение
/// (VK Captcha), которое встраивает виджет в iframe. После галочки
/// виджет отправляет родительскому окну сообщение
/// `{type: "vk-sak-sdk", handler: "VKCaptchaGetResult", params: {token}}`.
/// В адресе и в хранилищах токена нет — страница отдаёт его только этим
/// сообщением и сразу использует, нигде не сохраняя. Поэтому мы ставим
/// свой слушатель `message` и складываем токен в
/// `window.__ssrismaxCaptchaToken`, откуда его и забирает опрос.
struct CaptchaWebView: UIViewRepresentable {
    let url: URL
    let onToken: (String) -> Void
    let onTimeout: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken, onTimeout: onTimeout)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Капча VK живёт в своём домене и ставит куки — без этого
        // проверка не завершится.
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // Виджет отдаёт токен только сообщением в родительское окно —
        // в адресе и хранилищах его нет. Слушателя ставим на каждый
        // документ, чтобы он существовал до того, как пользователь
        // поставит галочку.
        let bridge = """
        (function () {
          if (window.__ssrismaxCaptchaHook) { return; }
          window.__ssrismaxCaptchaHook = true;
          window.__ssrismaxCaptchaToken = null;

          function grab(data) {
            try {
              if (!data || data.type !== 'vk-sak-sdk') { return; }
              var params = data.params || {};
              var token = params.token || params.value;
              if (data.handler === 'VKCaptchaGetResult' && token) {
                window.__ssrismaxCaptchaToken = String(token);
              }
            } catch (err) {}
          }

          // 1) Сообщения виджета (если VK вернётся к схеме с iframe).
          window.addEventListener('message', function (e) { grab(e && e.data); }, true);

          // 2) Главный путь: токен приходит в ответе на проверку капчи.
          //    Перехватываем fetch и XHR и вытаскиваем токен из тела.
          function scan(text) {
            try {
              if (!text) { return; }
              // Проверка на подстроку «токен» регистронезависима:
              // в camelCase-виде (captchaToken) нижнего «token» нет,
              // и жадный предфильтр отбрасывал бы верный ответ.
              var lower = String(text).toLowerCase();
              if (lower.indexOf('token') < 0) { return; }
              // Регулярка собирается из строк: обратный слэш в Swift-
              // литерале пришлось бы экранировать, и легко получить
              // невалидную последовательность. Здесь его нет вовсе.
              var ws = "[" + String.fromCharCode(32) + String.fromCharCode(9) + String.fromCharCode(10) + String.fromCharCode(13) + "]*";
              var re = new RegExp('"(?:captcha_?[Tt]oken|token)"' + ws + ":" + ws + '"([^"]{8,})"');
              var m = text.match(re);
              if (m) { window.__ssrismaxCaptchaToken = m[1]; }
            } catch (err) {}
          }

          var rawFetch = window.fetch;
          if (rawFetch) {
            window.fetch = function () {
              return rawFetch.apply(this, arguments).then(function (resp) {
                try {
                  resp.clone().text().then(scan, function () {});
                } catch (err) {}
                return resp;
              });
            };
          }

          var rawSend = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.send = function () {
            var xhr = this;
            xhr.addEventListener('load', function () {
              try { scan(xhr.responseText); } catch (err) {}
            });
            return rawSend.apply(this, arguments);
          };
        })();
        """
        configuration.userContentController.addUserScript(
            WKUserScript(source: bridge,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )

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
        private let onTimeout: () -> Void
        private var finished = false
        private var pollTask: Task<Void, Never>?

        init(onToken: @escaping (String) -> Void, onTimeout: @escaping () -> Void) {
            self.onToken = onToken
            self.onTimeout = onTimeout
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
                // ~30 с: если токена так и нет, лучше честно сказать,
                // что страница не отдала результат, чем держать пустое
                // окно. Пользователь хотя бы узнает, что делать дальше.
                let deadline = Date().addingTimeInterval(30)
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self, !self.finished else { return }
                    if let token = await self.readToken(from: webView), !token.isEmpty {
                        self.finish(token)
                        return
                    }
                    if Date() > deadline {
                        self.onTimeout()
                        return
                    }
                }
            }
        }

        /// Ищет токен, который страница получает после решения капчи.
        ///
        /// Надёжного места, куда VK его кладёт, нет: в отданном документе
        /// нет ни `callback`, ни `success_url`, ни iframe — только
        /// скрипт антибот-проверки, а токен живёт в памяти его JS.
        /// Поэтому проверяем всё, что может появиться: сохранённое
        /// перехваченное сообщение, адрес, хранилища.
        private func readToken(from webView: WKWebView) async -> String? {
            let script = """
            (function () {
              try {
                if (window.__ssrismaxCaptchaToken) {
                  return String(window.__ssrismaxCaptchaToken);
                }
                var href = (location.href || '');
                var m = href.match(/[?&](captcha_token|captchaToken|token)=([^&#]+)/);
                if (m) { return decodeURIComponent(m[2]); }
                var store = window.localStorage, sess = window.sessionStorage;
                var keys = ['captcha_token','captchaToken','not_robot_token'];
                for (var i = 0; i < keys.length; i++) {
                  var v = (store && store.getItem(keys[i])) || (sess && sess.getItem(keys[i]));
                  if (v) { return v; }
                }
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
                    CaptchaWebView(url: url,
                                   onToken: { token in
                                       Task { await session.completeCaptcha(token: token) }
                                   },
                                   onTimeout: {
                                       session.captchaTimedOut()
                                   })
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
