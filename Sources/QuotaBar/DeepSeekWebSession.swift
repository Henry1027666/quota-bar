import AppKit
import WebKit

/// DeepSeek 网页用量会话的职责边界（本类在 2026-09-08 重构后大幅收窄）：
///
/// 曾经后台刷新会反复 `new`/复用 WKWebView 加载 platform.deepseek.com/usage 整站来触发三个用量接口，
/// WKWebView 派生 WebContent/GPU/Network 辅助进程、SPA 整页渲染内存极高且不随导航释放，
/// 导致进程内存从 ~40MB 滚雪球到 ~800MB 并卡死（实测两次复发）。
///
/// 现在架构改为「登录一次、收割会话 cookie、后台全走轻量 HTTP」：
///   1. `showLoginWindow()`——用户**主动**点击「登录 DeepSeek」时弹出的 WKWebView，仅此一处会创建 WebView，
///      一次性、用完即回收。登录成功后页面会请求三接口，脚本拦截到即认为登录完成，随即自动关闭窗口。
///   2. 登录完成即刻 `harvestCookies(from:)`：把 WebKit 会话 cookie 收割、编码成 `Cookie:` 头写入
///      `~/.deepseek/web_cookies`。
///   3. 后台刷新不再触碰 WebView——`DeepSeekProvider` 读取该 cookie 头，用纯 URLSession 直调三接口；
///      若 cookie 过期则由 `harvestStoredCookies()` 尝试从持久化 WebKit 数据存储重新收割，仍无则提示重新登录。
@MainActor
final class DeepSeekWebSession: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = DeepSeekWebSession()

    /// 收割的网页会话 Cookie 头落盘路径（DeepSeekProvider 读取复用做纯 HTTP 拉取）。
    nonisolated static let cookieFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".deepseek/web_cookies")

    /// DeepSeek 会话的持久化 WebKit 数据存储标识（固定 UUID，保证重启后登录态仍在）。
    private static let dataStoreID = UUID(uuidString: "1B4E7A92-6C3D-4F8A-B5E0-2D9C47F61A83")!

    private static let usageURL = URL(string: "https://platform.deepseek.com/usage")!
    private static let cookieDomains = ["platform.deepseek.com", ".deepseek.com", "deepseek.com"]

    /// 登录窗口持有的 webView（一次性，关闭即释放）。
    private var loginWebView: WKWebView?
    private var loginWindow: NSWindow?
    private var isLoginWindowLoading = false
    /// 登录成功是否已通知（避免重复收割/通知）。
    private var didLogin = false

    private enum Endpoint {
        static let summary = "/api/v0/users/get_user_summary"
        static let amount = "/api/v0/usage/by_api_key/amount"
        static let cost = "/api/v0/usage/by_api_key/cost"
    }

    private override init() {
        super.init()
    }

    // MARK: - 登录窗口（用户主动登录，本类唯一创建 WebView 的入口）

    func showLoginWindow() {
        if let window = loginWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        didLogin = false
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
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        log("打开登录窗口，加载 \(Self.usageURL.absoluteString)")
        wv.load(URLRequest(url: Self.usageURL))
    }

    // MARK: - Cookie 收割（后台纯 HTTP 的凭据来源）

    /// 从给定 dataStore 收割 DeepSeek 会话 cookie，编码为 `Cookie:` 头写盘；成功返回头部，否则 nil。
    private func harvestCookies(from store: WKWebsiteDataStore) async -> String? {
        let cookies = await store.httpCookieStore.allCookies()
        guard !cookies.isEmpty else { log("harvest: 无 cookie"); return nil }
        let relevant = cookies.filter { cookie in
            cookie.domain.lowercased().contains("deepseek.com")
        }
        guard !relevant.isEmpty else { log("harvest: 无 deepseek cookie"); return nil }
        // 只保留登录会话相关（排除无值的）；按标准 Cookie 头拼装。
        let parts = relevant.compactMap { c -> String? in
            let v = c.value.trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : "\(c.name)=\(v)"
        }
        guard !parts.isEmpty else { return nil }
        let header = parts.joined(separator: "; ")
        // 原子写盘，0600 权限（含会话凭据，不落宽权限）。
        do {
            let dir = Self.cookieFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try header.write(to: Self.cookieFileURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.cookieFileURL.path)
            log("harvest: 已收割 \(relevant.count) 个 deepseek cookie → \(Self.cookieFileURL.lastPathComponent)")
            return header
        } catch {
            log("harvest: 写盘失败 \(error.localizedDescription)")
            return nil
        }
    }

    /// 从持久化 WebKit 数据存储直接重新收割（不创建任何 WebView）。
    /// DeepSeekProvider 在 cookie 头缺失/过期时调用；app 内直接读持久化 dataStore 的 cookieStore 即可。
    func harvestStoredCookies() async -> String? {
        // 注意：持久化 dataStore 需在进程内被使用过才落库；直接用 identifier 取 store 并读 httpCookieStore。
        let store = WKWebsiteDataStore(forIdentifier: Self.dataStoreID)
        return await harvestCookies(from: store)
    }

    // MARK: - 登录成功处理

    /// 页面请求到了核心用量接口 → 判定登录成功：收割 cookie、自动关窗、通知刷新。
    private func handleLoginSuccess() {
        guard isLoginWindowLoading, loginWindow != nil, !didLogin else { return }
        isLoginWindowLoading = false
        didLogin = true
        // 优先从登录窗口 webView 的 dataStore 收割（此刻 cookie 最新、必已写入）。
        if let store = loginWebView?.configuration.websiteDataStore {
            Task { [weak self] in
                let harvested = await self?.harvestCookies(from: store)
                self?.log("登录成功，收割结果: \(harvested != nil ? "成功" : "失败(无cookie)")")
                self?.teardownLoginWindow()
                NotificationCenter.default.post(name: .dsWebUsageUpdated, object: nil)
            }
        } else {
            teardownLoginWindow()
            NotificationCenter.default.post(name: .dsWebUsageUpdated, object: nil)
        }
    }

    private func teardownLoginWindow() {
        loginWebView?.stopLoading()
        loginWebView = nil
        loginWindow?.close()
        loginWindow = nil
        isLoginWindowLoading = false
    }

    // MARK: - WKScriptMessageHandler（页面拦截脚本回传，用于判定登录完成）

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "dsUsage",
              let body = message.body as? [String: Any],
              let id = body["id"] as? String else { return }
        // 诊断上报不参与登录判定
        if id == "__req__" { return }
        // 登录页发起了核心用量接口 → 说明已具备会话，视为登录成功。
        if id == Endpoint.amount || id == Endpoint.cost || id == Endpoint.summary {
            handleLoginSuccess()
        }
    }

    // MARK: - WKNavigationDelegate（未登录跳转检测 / 完成兜底）

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 若导航落在 usage 且已有 cookie，尝试判定；纯兜底，避免脚本偶发漏触发。
        handleLoginSuccess()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("登录窗口导航失败: \(error.localizedDescription)")
    }

    // MARK: - NSWindowDelegate（用户手动关窗时清理）

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === loginWindow else { return }
        teardownLoginWindow()
    }

    // MARK: - 私有

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

    private func log(_ message: String) {
        NSLog("[DSWeb] %@", message)
    }

    /// 页面注入脚本：拦截 DeepSeek 用量接口的 fetch/XHR，仅用于判定登录完成。
    private static let interceptScript = #"""
    (function () {
      var endpoints = ['/api/v0/users/get_user_summary', '/api/v0/usage/by_api_key/amount', '/api/v0/usage/by_api_key/cost'];
      function post(id) {
        try { window.webkit.messageHandlers.dsUsage.postMessage({ id: id, data: {} }); } catch (e) {}
      }
      function match(url) {
        for (var i = 0; i < endpoints.length; i++) {
          if (url.indexOf(endpoints[i]) !== -1) return endpoints[i];
        }
        return null;
      }
      var origFetch = window.fetch;
      window.fetch = function (input, init) {
        var url = typeof input === 'string' ? input : (input && input.url) || '';
        var ep = match(url);
        var p = origFetch.apply(this, arguments);
        if (ep) { p.then(function () { post(ep); }).catch(function () {}); }
        return p;
      };
      var OrigXHR = window.XMLHttpRequest;
      window.XMLHttpRequest = function () {
        var xhr = new OrigXHR();
        var u = '';
        var origOpen = xhr.open;
        xhr.open = function (method, url) { u = url; return origOpen.apply(xhr, arguments); };
        xhr.addEventListener('load', function () {
          if (match(u) && xhr.status >= 200 && xhr.status < 300) { post(match(u)); }
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
