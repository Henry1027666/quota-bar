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

    /// DeepSeek 会话的持久化 WebKit 数据存储标识（固定 UUID，保证登录窗口会话跨次保持）。
    private static let dataStoreID = UUID(uuidString: "1B4E7A92-6C3D-4F8A-B5E0-2D9C47F61A83")!

    private static let usageURL = URL(string: "https://platform.deepseek.com/usage")!

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

    // MARK: - Token 收割（后台纯 HTTP 的凭据来源）

    // DeepSeek 网页端登录态认证**不依赖 cookie**（cookie 里只有 HWWAFSESID/smidV2 等 WAF/追踪项），
    // 真正的登录凭据是存在 localStorage 的 `userToken`（JWT），请求时以 `Authorization: Bearer` 发送。
    // 因此收割目标是 localStorage 里的 JWT，而非 httpCookieStore。

    /// 收割的 JWT 落盘路径（= 现有 bearer token 路径，DeepSeekProvider.discoverWebToken 读取）。
    private static var tokenFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".deepseek/web_token")
    }

    /// 从登录窗口 webView 的存储区收割 DeepSeek JWT，原子写盘 `~/.deepseek/web_token`。
    /// 页面此刻加载于 platform.deepseek.com，同源可读 localStorage / sessionStorage。
    /// 返回 nil 时调用方应读取诊断（本方法会把两个 storage 的 key/value 前缀写日志）。
    private func harvestToken(from webView: WKWebView) async -> String? {
        // 同时探测 localStorage 与 sessionStorage：
        // 1) 精确取名为 userToken 的项（DeepSeek 网页端认证凭据）；
        // 2) 否则遍历取第一个以 eyJ 开头（JWT）的值；
        // 3) 顺带把两处所有 key + value 前缀回传，供收割失败时精确定位真实存储。
        let js = #"""
        (function () {
          function dump(store) {
            var arr = [];
            try {
              for (var i = 0; i < store.length; i++) {
                var k = store.key(i);
                var v = store.getItem(k) || '';
                arr.push(k + '=[' + v.substring(0, 60) + ']');
              }
            } catch (e) {}
            return arr;
          }
          // DeepSeek 的 userToken 存的是 JSON 包装：{"value":"<token>","__version":"0"}，
          // 直接取整个字符串当 Bearer 会 40003。这里解包 value 字段。
          function unwrap(v) {
            if (v && typeof v === 'string' && v.charAt(0) === '{') {
              try {
                var o = JSON.parse(v);
                if (o && typeof o.value === 'string') return o.value;
              } catch (e) {}
            }
            return v;
          }
          function firstJwt(store) {
            try {
              for (var i = 0; i < store.length; i++) {
                var k = store.key(i);
                var v = store.getItem(k);
                if (v && typeof v === 'string') {
                  var u = unwrap(v);
                  if (u && u.indexOf('eyJ') === 0) return u;
                }
              }
            } catch (e) {}
            return null;
          }
          var LS = null, SS = null;
          try { LS = window.localStorage; } catch (e) {}
          try { SS = window.sessionStorage; } catch (e) {}
          var explicit = null;
          if (LS) { try { var e1 = LS.getItem('userToken'); explicit = unwrap(e1); } catch (e) {} }
          if (!explicit && SS) { try { var e2 = SS.getItem('userToken'); explicit = unwrap(e2); } catch (e) {} }
          var token = explicit || (LS ? firstJwt(LS) : null) || (SS ? firstJwt(SS) : null);
          var diag = {
            ls: LS ? dump(LS) : ['<unavailable>'],
            ss: SS ? dump(SS) : ['<unavailable>'],
            got: !!token,
            prefix: token ? token.substring(0, 20) : null
          };
          try { window.webkit.messageHandlers.dsUsage.postMessage({ id: '__storage__', data: diag }); } catch (e) {}
          return token;
        })()
        """#
        let token: String? = await withCheckedContinuation { cont in
            let box = ContinuationBox(cont)
            webView.evaluateJavaScript(js) { result, _ in
                box.resume(result as? String)
            }
            // 兜底：evaluateJavaScript 回调缺失时 3s 后释放续体，
            // 否则收割 Task 永久挂起、登录窗口永不关闭（表现为「卡死」）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                box.resume(nil)
            }
        }
        guard let t = token?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            log("token收割: 两处存储均未定位到 JWT（详见 __storage__ 诊断）")
            return nil
        }
        do {
            let dir = Self.tokenFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try t.write(to: Self.tokenFileURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.tokenFileURL.path)
            log("token收割: 已写盘 \(Self.tokenFileURL.lastPathComponent) (JWT \(t.prefix(20))…)")
            return t
        } catch {
            log("token收割: 写盘失败 \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 登录成功处理

    /// 页面发起了用量接口，且响应体确为「已登录」才判定登录成功。
    /// 仅发起请求不代表登录——未登录访问 /usage 也会向后端发这些接口（返回 code!=0）。
    /// 因此必须校验顶层 `code == 0` 且含有真实数据，再收割 cookie、自动关窗、通知刷新。
    private func handleUsageData(_ endpoint: String, data: Any) {
        guard isLoginWindowLoading, loginWindow != nil, !didLogin else { return }
        // 确认真实登录：顶层 code == 0（DeepSeek 未登录/过期会返回 code != 0）。
        guard let dict = data as? [String: Any],
              let code = (dict["code"] as? NSNumber)?.intValue
                  ?? (dict["code"] as? Int),
              code == 0 else {
            log("登录判定: \(endpoint) 返回 code!=0，尚未登录，继续等待")
            return
        }
        isLoginWindowLoading = false
        didLogin = true
        log("登录判定: \(endpoint) code==0 ✅ 判定登录成功，开始收割 JWT")
        // 登录成功 → 收割 localStorage 的 JWT（认证凭据），供后台纯 HTTP 用 Bearer 复用。
        if let wv = loginWebView {
            Task { [weak self] in
                // 稍候片刻确保页面登录完成、存储 token 已写入。
                try? await Task.sleep(nanoseconds: 800_000_000)
                let token = await self?.harvestToken(from: wv)
                self?.log("登录成功，token 收割结果: \(token != nil ? "成功" : "失败(未定位到JWT)")")
                self?.teardownLoginWindow()
                NotificationCenter.default.post(name: .dsWebUsageUpdated, object: nil)
            }
        } else {
            log("登录判定: webView 已为空，跳过收割")
            teardownLoginWindow()
            NotificationCenter.default.post(name: .dsWebUsageUpdated, object: nil)
        }
    }

    private func teardownLoginWindow() {
        // 先解除 delegate 与引用，再 close：close 会触发 windowWillClose，
        // 若不先置 nil/解 delegate，windowWillClose 又回调 teardown → 无限递归导致栈溢出崩溃。
        guard let window = loginWindow else {
            loginWebView = nil
            loginWindow = nil
            isLoginWindowLoading = false
            return
        }
        loginWindow = nil
        window.delegate = nil
        loginWebView?.stopLoading()
        loginWebView = nil
        isLoginWindowLoading = false
        window.close()
    }

    // MARK: - WKScriptMessageHandler（页面拦截脚本回传，用于判定登录完成）

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "dsUsage",
              let body = message.body as? [String: Any],
              let id = body["id"] as? String else { return }
        // 存储区诊断上报（收割 JWT 失败时定位真实 key）
        if id == "__storage__" {
            if let data = body["data"] as? [String: Any] {
                let ls = (data["ls"] as? [String]) ?? []
                let ss = (data["ss"] as? [String]) ?? []
                log("存储诊断 localStorage: \(ls.joined(separator: " ; "))")
                log("存储诊断 sessionStorage: \(ss.joined(separator: " ; "))")
                log("存储诊断 命中JWT: \(data["got"] ?? false) 前缀: \(data["prefix"] ?? "nil")")
            }
            return
        }
        // 用量接口响应体（未登录也会发请求，但 code!=0；登录成功才 code==0）
        let payload = body["data"]
        if let dict = payload as? [String: Any],
           let code = (dict["code"] as? NSNumber)?.intValue ?? (dict["code"] as? Int) {
            log("接口 \(id) 返回 code=\(code)")
        } else {
            log("接口 \(id) 响应非标准(无code): \(String(describing: (payload as? [String: Any])?.keys))")
        }
        // 登录页发起了核心用量接口 → 依据响应体 code 判定是否真已登录。
        if id == Endpoint.amount || id == Endpoint.cost || id == Endpoint.summary {
            handleUsageData(id, data: payload ?? [:])
        }
    }

    // MARK: - WKNavigationDelegate（未登录跳转检测 / 完成兜底）

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("登录窗口导航完成: \(webView.url?.absoluteString ?? "?")")
        // 注意：此处不触发登录判定——页面加载完成 ≠ 已登录。
        // 登录与否只由 userContentController 收到的接口响应体 code==0 判定（见 handleUsageData）。
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("登录窗口导航失败: \(error.localizedDescription)")
    }

    // MARK: - NSWindowDelegate（用户手动关窗时清理）

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === loginWindow else { return }
        // 用户主动点关闭按钮。只清引用、不再次 close（避免与 teardownLoginWindow 相互递归）。
        loginWindow = nil
        window.delegate = nil
        loginWebView?.stopLoading()
        loginWebView = nil
        isLoginWindowLoading = false
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
        Log.append("DSWeb", message)
    }

    /// 页面注入脚本：拦截 DeepSeek 用量接口的 fetch/XHR，把**完整响应体**回传，
    /// 用于确认真实登录态（仅请求到接口不代表已登录——未登录访问也会发请求）。
    private static let interceptScript = #"""
    (function () {
      var endpoints = ['/api/v0/users/get_user_summary', '/api/v0/usage/by_api_key/amount', '/api/v0/usage/by_api_key/cost'];
      function post(id, data) {
        try { window.webkit.messageHandlers.dsUsage.postMessage({ id: id, data: data }); } catch (e) {}
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
        if (!ep) { return origFetch.apply(this, arguments); }
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
        var u = '';
        var origOpen = xhr.open;
        xhr.open = function (method, url) { u = url; return origOpen.apply(xhr, arguments); };
        xhr.addEventListener('load', function () {
          var ep = match(u);
          if (ep && xhr.status >= 200 && xhr.status < 300) {
            try { post(ep, JSON.parse(xhr.responseText)); } catch (e) {}
          }
        });
        return xhr;
      };
      window.XMLHttpRequest.prototype = OrigXHR.prototype;
    })();
    """#
}

extension DeepSeekWebSession: NSWindowDelegate {}

/// 恰好 resume 一次的续体容器：收割 JS 回调与 3s 超时兜底竞争，先到者生效。
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    private var done = false

    init(_ c: CheckedContinuation<String?, Never>) {
        continuation = c
    }

    func resume(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard !done, let c = continuation else { return }
        done = true
        continuation = nil
        c.resume(returning: value)
    }
}

extension Notification.Name {
    /// DeepSeek 登录窗口内完成登录并取得用量数据后发出，面板应刷新。
    static let dsWebUsageUpdated = Notification.Name("DeepSeekWebUsageUpdated")
}
