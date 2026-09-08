import AppKit
import WebKit

/// DeepSeek 网页用量会话：QuotaBar 内嵌 WKWebView，用户在本应用内登录 DeepSeek 开放平台，
/// 之后由会话持久化（cookie/token 存在 QuotaBar 自己的 WebKit 数据目录，不触碰外部浏览器）。
/// 页面加载时会自动请求 /api/v0 用量接口，本类在 document-start 注入拦截脚本，
/// 把页面自身发起的用量响应转发给 Swift 解析——QuotaBar 不接触任何认证材料本身。
///
/// 内存说明：WKWebView 会派生 WebContent/GPU/Network 多个辅助进程，冷启动完整 usage 页
/// 内存可达数百 MB。因此本类 **常驻复用单个后台 webView**（懒加载后整个会话期间复用），
/// 绝不每个刷新周期 `new` 一个——否则辅助进程组反复重建、缓存不释放，内存会滚雪球到数百 MB 并卡死
/// （曾在实测中从 ~40MB 飙升至 ~800MB 无响应）。
@MainActor
final class DeepSeekWebSession: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = DeepSeekWebSession()

    /// 已登录标志：上次会话成功取到过数据，则后台刷新时尝试静默加载；否则直接提示登录。
    private var isLoggedIn: Bool {
        get { UserDefaults.standard.bool(forKey: "dsWebLoggedIn") }
        set { UserDefaults.standard.set(newValue, forKey: "dsWebLoggedIn") }
    }

    private enum Endpoint {
        static let summary = "/api/v0/users/get_user_summary"
        static let amount = "/api/v0/usage/by_api_key/amount"
        static let cost = "/api/v0/usage/by_api_key/cost"
        static let all = [summary, amount, cost]
    }

    enum SessionResult: Sendable {
        /// 三个接口解析后的用量数据
        case data(DeepSeekProvider.WebUsage)
        case notLoggedIn
        case timeout
    }

    /// 常驻复用的后台 webView。仅在首次需要时创建一次；后台 fetch 与登录窗口共用同一个，
    /// 绝不为每次后台刷新新建。此成员是内存问题的根治点。
    private var persistentWebView: WKWebView?
    /// 登录窗口持有的 webView 视图引用（登录窗口关闭即释放，与后台复用实例解耦）。
    private var loginWebView: WKWebView?
    private var loginWindow: NSWindow?
    private var pending: CheckedContinuation<SessionResult?, Never>?
    private var collected: [String: Any] = [:]
    private var received = Set<String>()
    private var timeoutTask: Task<Void, Never>?
    private var isLoginWindowLoading = false

    private static let usageURL = URL(string: "https://platform.deepseek.com/usage")!
    /// DeepSeek 会话的持久化 WebKit 数据存储标识（固定 UUID，保证重启后登录态仍在）。
    private static let dataStoreID = UUID(uuidString: "1B4E7A92-6C3D-4F8A-B5E0-2D9C47F61A83")!

    private override init() {
        super.init()
    }

    // MARK: - 后台静默获取（QuotaStore 刷新时调用）

    func fetchUsage() async -> SessionResult {
        guard isLoggedIn else { log("fetchUsage: 未登录，直接跳过"); return .notLoggedIn }
        // 并发互斥：已有后台 fetch 或登录窗口正在加载时，直接返回，不重复创建/加载 WebView。
        guard !isLoginWindowLoading else { log("fetchUsage: 登录窗口加载中，跳过"); return .timeout }
        guard pending == nil else { log("fetchUsage: 已有请求进行中"); return .timeout }

        received = []
        collected = [:]
        let result: SessionResult? = await withCheckedContinuation { [weak self] cont in
            guard let self else { cont.resume(returning: .timeout); return }
            self.pending = cont
            // 复用常驻后台实例；不存在才懒创建。
            let wv = self.persistentWebView ?? self.makePersistentWebView()
            self.persistentWebView = wv
            log("fetchUsage: 后台加载(复用实例) \(Self.usageURL.absoluteString)")
            wv.stopLoading()
            wv.load(URLRequest(url: Self.usageURL))
            self.scheduleCheckpoints()
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                self?.log("fetchUsage: 25s 超时")
                self?.finish(.timeout)
            }
        }
        return result ?? .timeout
    }

    // MARK: - 登录窗口（用户点击「登录 DeepSeek」时）

    func showLoginWindow() {
        if let window = loginWindow {
            log("登录窗口已存在，前置")
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // 登录窗口是用户显式操作，使用独立轻量 webView（用完释放），不复用后台实例，
        // 避免后台刷新恰好在同一时刻触发时互相干扰导航与收集状态。
        isLoginWindowLoading = true
        let wv = makeWebView()
        loginWebView = wv
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "登录 DeepSeek · 开启今日用量统计"
        window.isReleasedWhenClosed = false
        window.contentView = wv
        window.center()
        window.setFrameAutosaveName("DeepSeekLoginWindow")
        loginWindow = window
        // 窗口关闭时清理登录专用 webView，避免泄漏。
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        log("打开登录窗口，加载 \(Self.usageURL.absoluteString)")
        wv.load(URLRequest(url: Self.usageURL))
    }

    // MARK: - WKScriptMessageHandler（页面拦截脚本回传）

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "dsUsage",
              let body = message.body as? [String: Any],
              let id = body["id"] as? String else {
            log("收到未知消息: \(message.name)")
            return
        }
        // 诊断模式：页面所有 API 请求 URL 上报，用于定位真实用量接口
        if id == "__req__", let data = body["data"] as? [String: Any] {
            let kind = data["kind"] as? String ?? "?"
            let url = data["url"] as? String ?? "?"
            log("页面请求(\(kind)): \(url)")
            return
        }
        guard let data = body["data"] else { return }
        collected[id] = data
        received.insert(id)
        isLoggedIn = true
        // 诊断：打印响应结构（确认 by_api_key 接口的字段布局）
        if let dict = data as? [String: Any] {
            if let payload = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) {
                log("收到接口数据: \(id) body=\(String(data: payload, encoding: .utf8)?.prefix(500) ?? "")")
            }
        } else {
            log("收到接口数据: \(id) body=\(String(describing: data).prefix(400))")
        }
        attemptFinishIfReady()
    }

    // MARK: - 完成判定

    /// 只要收到核心用量接口（amount/cost 任一）就尝试完成，避免页面未发全三个接口时永远等待。
    private func attemptFinishIfReady() {
        let hasCore = received.contains(Endpoint.amount) || received.contains(Endpoint.cost)
        guard hasCore else { return }
        if isLoginWindowLoading {
            guard loginWindow != nil else { return }
            isLoginWindowLoading = false
            // 登录成功即回收登录专用实例，避免窗口关闭后仍常驻吃内存。
            loginWebView?.stopLoading()
            loginWebView = nil
            loginWindow?.close()
            loginWindow = nil
            log("登录窗口: 用量数据已取得，自动关闭并通知面板刷新")
            NotificationCenter.default.post(name: .dsWebUsageUpdated, object: nil)
        } else {
            guard pending != nil else { return }
            let web = DeepSeekProvider.parseWebPayload(collected)
            log("后台获取: 数据齐，返回 \(web.map { "数据(请求\($0.requestCount ?? 0)/Token\($0.tokenUsage ?? 0))" } ?? "空")")
            finish(web.map(SessionResult.data) ?? .timeout)
        }
    }

    /// 页面加载后定时兜底检查（页面可能没发全接口，3s/8s/15s 各检查一次）。
    private func scheduleCheckpoints() {
        for delay in [3.0, 8.0, 15.0] {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.log("checkpoint \(Int(delay))s：已收 \(self?.received.sorted() ?? [])")
                self?.attemptFinishIfReady()
            }
        }
    }

    // MARK: - WKNavigationDelegate（未登录跳转检测）

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? "?"
        log("导航开始: \(url)")
        let lower = url.lowercased()
        if lower.contains("signin") || lower.contains("login") || lower.contains("auth") {
            isLoggedIn = false
            if !isLoginWindowLoading {
                log("检测到未登录跳转 → notLoggedIn")
                finish(.notLoggedIn)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("导航完成: \(webView.url?.absoluteString ?? "?")")
        attemptFinishIfReady()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("导航失败: \(error.localizedDescription)")
        if !isLoginWindowLoading {
            finish(.timeout)
        }
    }

    // MARK: - NSWindowDelegate（登录窗口关闭时清理）

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === loginWindow else { return }
        log("登录窗口关闭，清理登录专用资源")
        isLoginWindowLoading = false
        loginWebView?.stopLoading()
        loginWebView = nil
        loginWindow = nil
        // 若后台 fetch 正在等待（正常不会，因互斥），兜底释放。
        if pending != nil {
            finish(.timeout)
        }
    }

    // MARK: - 私有

    /// 创建后台复用实例。相较登录窗口实例，额外把 `webView` 保持弱引用到 self 之外的生命周期——
    /// 这里用类持有的强引用 `persistentWebView` 保证其跨刷新存活（内存稳定的关键）。
    private func makePersistentWebView() -> WKWebView {
        let webView = makeWebView()
        // 后台实例：为避免挂载到窗口，保持独立存在即可；WKWebView 无需加进视图层级即可 load。
        return webView
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(self, name: "dsUsage")
        let script = WKUserScript(
            source: Self.interceptScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(script)
        config.userContentController = controller
        // 独立持久化会话（QuotaBar 自己的 WebKit 数据，非外部浏览器）
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreID)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        return webView
    }

    private func finish(_ result: SessionResult) {
        guard let cont = pending else { return }
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        cont.resume(returning: result)
        // 后台实例保持复用，不销毁——下一个周期继续复用同一实例，WebKit 辅助进程组只初始化一次。
        // 但取完数据立即导航到空白页，卸载 usage 站点的图表/数据卷渲染，把渲染内存释放回系统，
        // 只保留轻量的 WebKit 进程骨架。这样既避免反复冷启动，又不让重型页面常驻吃内存。
        persistentWebView?.stopLoading()
        persistentWebView?.load(URLRequest(url: URL(string: "about:blank")!))
    }

    private func log(_ message: String) {
        NSLog("[DSWeb] %@", message)
    }

    /// 页面注入脚本：拦截 DeepSeek 用量接口的 fetch/XHR 响应，转发给 Swift；
    /// 同时上报所有含 /api/ 或 usage 的请求 URL（诊断模式）。
    private static let interceptScript = #"""
    (function () {
      var endpoints = ['/api/v0/users/get_user_summary', '/api/v0/usage/by_api_key/amount', '/api/v0/usage/by_api_key/cost'];
      function match(url) {
        for (var i = 0; i < endpoints.length; i++) {
          if (url.indexOf(endpoints[i]) !== -1) return endpoints[i];
        }
        return null;
      }
      function post(id, data) {
        try { window.webkit.messageHandlers.dsUsage.postMessage({ id: id, data: data }); } catch (e) {}
      }
      function report(kind, url) {
        if (url && (url.indexOf('/api/') !== -1 || url.indexOf('usage') !== -1)) {
          post('__req__', { kind: kind, url: url });
        }
      }
      var origFetch = window.fetch;
      window.fetch = function (input, init) {
        var url = typeof input === 'string' ? input : (input && input.url) || '';
        var ep = match(url);
        if (!ep) {
          report('fetch', url);
          return origFetch.apply(this, arguments);
        }
        return origFetch.apply(this, arguments).then(function (resp) {
          if (resp && resp.ok) {
            resp.clone().json().then(function (j) { post(ep, j); }).catch(function () {});
          }
          return resp;
        });
      };
      var OrigXHR = window.XMLHttpRequest;
      window.XMLHttpRequest = function () {
        var xhr = new OrigXHR();
        var m = 'GET', u = '';
        var origOpen = xhr.open;
        xhr.open = function (method, url) {
          m = method; u = url;
          return origOpen.apply(xhr, arguments);
        };
        xhr.addEventListener('load', function () {
          var ep = match(u);
          if (ep && xhr.status >= 200 && xhr.status < 300) {
            try { post(ep, JSON.parse(xhr.responseText)); } catch (e) {}
          } else if (!ep) {
            report('xhr', u);
          }
        });
        return xhr;
      };
      window.XMLHttpRequest.prototype = OrigXHR.prototype;
    })();
    """#
}

extension DeepSeekWebSession: NSWindowDelegate {}

extension Notification.Name {
    /// DeepSeek 登录窗口内完成登录并取得用量数据后发出，面板应刷新。
    static let dsWebUsageUpdated = Notification.Name("DeepSeekWebUsageUpdated")
}
