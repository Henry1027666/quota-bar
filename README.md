# Quota Bar

原生 macOS 26 菜单栏额度面板。自动读取本机已有认证，不要求用户录入账号或密钥。

当前支持：

* Codex：5 小时 / 周额度、重置时间、Credits/API 余额
* Cursor：套餐额度，以及接口实际返回的 token / 请求数
* Claude Code：5 小时 / 周额度与重置时间
* Kimi Code：同时发现 `~/.kimi-code`（VS Code 扩展 / 新版客户端）和 `~/.kimi`（旧版 CLI），展示 5 小时 / 周 / 月额度、Extra Usage，以及接口实际返回的 token / 请求数
* DeepSeek：同时发现环境变量、DeepSeek Harness 的 `~/.dsh/.credentials.yaml` 与常见客户端配置，展示 API 余额

未检测到认证的厂商不会出现在面板中。

```bash
swift build
swift test
swift run QuotaBar
```

一键构建 + 打包 .app + 启动（推荐）：

```bash
./run.sh
```

`run.sh` 会按源码新旧自动增量构建 release、组装 `.build/QuotaBar.app`（LSUIElement，无 Dock 图标）、
ad-hoc 签名、退出旧实例并经 LaunchServices 启动（保证单实例）。

前置要求：`xcode-select` 指向 Xcode（CommandLineTools 缺少 SwiftUIMacros 插件，无法编译 SwiftUI），
并已执行过 `sudo xcodebuild -license accept`。

> 注意：以 .app 启动时不继承 shell 环境变量（如 `DEEPSEEK_API_KEY`、`CODEX_HOME`）。
> 各厂商认证按「环境变量 → 本机配置文件」顺序发现，依赖环境变量的场景请落盘到对应配置文件。

> 提示：macOS 可能把第三方菜单栏应用的图标默认收入控制中心隐藏区，
> 若启动后看不到图标，请在「控制中心 → 菜单栏」中把 QuotaBar 点亮。

所有认证仅在本机内存中用于请求对应厂商接口，不写入 Quota Bar 自有存储。
