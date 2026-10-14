# Quota Bar

原生 macOS 菜单栏额度面板（SwiftUI，LSUIElement 无 Dock 图标）。自动读取本机已有认证，不要求录入账号或密钥。

## 界面

单页面板：顶部为今日 / 近 7 天 / 近 30 天 token 总用量（滚动窗口），下方为综合趋势曲线与厂商卡片。

## 当前支持

* **Codex**：5 小时 / 周额度与重置时间；token 用量由本地会话日志（`~/.codex/sessions`）逐日精确统计
* **Kimi Code**：同时发现 `~/.kimi-code`（VS Code 扩展 / 新版客户端）和 `~/.kimi`（旧版 CLI），
  展示 5 小时 / 周 / 月额度、Extra Usage 余额；token 用量由本地会话日志（`~/.kimi-code/sessions`）逐日精确统计
* **DeepSeek**：**登录凭据直接取自 DeepSeek Harness（`~/.dsh/.credentials.yaml`）**，
  用户在 DSH 里登录后即可自动统计，本应用不再提供单独的登录入口，也不需要 API Key。
  展示余额（充值 / 赠送 / 累计消费）与逐日 token 用量、按模型拆分。

> DeepSeek 的账户接口用 DSH 的自定义头 `x-dsh-auth-token` 认证——它的凭据不是 JWT，
> 用 `Authorization: Bearer` 会被拒（`code 40003`）。早期版本靠内嵌 WKWebView 登录并收割
> localStorage JWT，现已整套移除。

综合趋势曲线展示近 7 天逐日 token 用量（每家一条彩色曲线），鼠标悬停浮出当天各厂商用量明细。

切换到单个厂商时，图表改为该厂商的**逐模型堆叠柱**：每个模型是柱中的一段，柱高即当日（或当小时）总量。
只显示有数据的模型，图例按用量降序；**总用量不在图中单独画出**，鼠标悬停时在气泡里给出总量与各模型明细。
模型来源：Codex 取会话日志 `turn_context.model`、Kimi Code 取 `usage.record.model`、DeepSeek 取用量接口 `series[].model`。

> 采用堆叠柱而非多条曲线，是因为当某个模型占绝对多数（如 DeepSeek 单一模型占 100%）时，
> 总量曲线会与该模型曲线完全重合、互相遮挡，既看不出总量也看不出各模型占比。

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

> 注意：以 .app 启动时不继承 shell 环境变量（如 `CODEX_HOME`、`DSH_HOME`）。
> 各厂商认证均从本机配置文件发现；DeepSeek 依赖 DeepSeek Harness 的登录态，
> 请先在其应用内登录。

> 提示：macOS 可能把第三方菜单栏应用的图标默认收入控制中心隐藏区，
> 若启动后看不到图标，请在「控制中心 → 菜单栏」中把 QuotaBar 点亮。

所有认证仅在本机内存中用于请求对应厂商接口，不写入 Quota Bar 自有存储。
