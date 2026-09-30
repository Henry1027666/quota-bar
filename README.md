# Quota Bar

原生 macOS 菜单栏额度面板（SwiftUI，LSUIElement 无 Dock 图标）。自动读取本机已有认证，不要求录入账号或密钥。

## 界面

单页面板：顶部为今日 / 本周 / 本月 token 总用量，下方为厂商卡片。每张卡片展示额度窗口进度条、
余额，以及近 7 天逐日 token 用量迷你趋势曲线——鼠标悬停曲线可浮出「日期 · 当日用量」气泡。

## 当前支持

* **Codex**：5 小时 / 周额度与重置时间；token 用量由本地会话日志（`~/.codex/sessions`）逐日精确统计
* **Claude Code**：5 小时 / 周额度与重置时间
* **Kimi Code**：同时发现 `~/.kimi-code`（VS Code 扩展 / 新版客户端）和 `~/.kimi`（旧版 CLI），
  展示 5 小时 / 周 / 月额度、Extra Usage 余额；token 用量由本地会话日志（`~/.kimi-code/sessions`）逐日精确统计
* **DeepSeek**：同时发现环境变量、DeepSeek Harness 的 `~/.dsh/.credentials.yaml` 与常见客户端配置；
  展示 API 余额、累计 / 今日消费。面板内嵌登录开放平台后，token 用量按接口逐日 bucket 精确统计

未检测到认证的厂商不会出现在面板中。后台每 5 分钟自动刷新，面板中可手动刷新。

## 下载

从 [Releases](https://github.com/Henry1027666/quota-bar/releases) 下载 zip，
解压后将 `QuotaBar.app` 拖入「应用程序」。首次运行如被 Gatekeeper 拦截，右键 → 打开。

## 自行构建

```bash
swift build
swift test
./run.sh    # 增量构建 release + 组装 .build/QuotaBar.app + 签名 + 启动（推荐）
```

发布新版本（打 tag、推送、创建 GitHub Release 并上传 zip）：

```bash
./release.sh <版本号>   # 例如 ./release.sh 0.2.0
```

前置要求：`xcode-select` 指向 Xcode（CommandLineTools 缺少 SwiftUIMacros 插件，无法编译 SwiftUI），
并已执行过 `sudo xcodebuild -license accept`。

> 注意：以 .app 启动时不继承 shell 环境变量（如 `DEEPSEEK_API_KEY`、`CODEX_HOME`）。
> 各厂商认证按「环境变量 → 本机配置文件」顺序发现，依赖环境变量的场景请落盘到对应配置文件。

> 提示：macOS 可能把第三方菜单栏应用的图标默认收入控制中心隐藏区，
> 若启动后看不到图标，请在「控制中心 → 菜单栏」中把 QuotaBar 点亮。

所有认证仅在本机内存中用于请求对应厂商接口，不写入 Quota Bar 自有存储。
