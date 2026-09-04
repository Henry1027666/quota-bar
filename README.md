# Quota Bar

原生 macOS 26 菜单栏额度面板。自动读取本机已有认证，不要求用户录入账号或密钥。

当前支持：



* Codex：5 小时 / 周额度、重置时间、Credits/API 余额

* Cursor：套餐额度，以及接口实际返回的 token / 请求数

* Claude Code：5 小时 / 周额度与重置时间

* Kimi Code：同时发现 `~/.kimi-code`（VS Code 扩展 / 新版客户端）和 `~/.kimi`（旧版 CLI），展示 5 小时 / 周 / 月额度、Extra Usage，以及接口实际返回的 token / 请求数

* DeepSeek：同时发现环境变量、DeepSeek Harness 的 `~/.dsh/.credentials.yaml` 与常见客户端配置，展示 API 余额

未检测到认证的厂商不会出现在面板中。



```
swift build

swift test

swift run QuotaBar
```

一键启动（保证菜单栏图标显示，推荐）：



```
./run.sh
```

开机自启（登录时自动运行）：



```
\# 已安装：\~/Library/LaunchAgents/com.henryzhang.quotabar.plist

\# 卸载自启：

launchctl bootout gui/\$(id -u)/com.henryzhang.quotabar

rm \~/Library/LaunchAgents/com.henryzhang.quotabar.plist
```

> 说明：macOS 26 (Tahoe) 会把「打包成 
>
> `.app`
>
>  的第三方菜单栏应用」的图标
> 默认放入控制中心隐藏区（blocked host），且应用无法编程绕过；直接运行
> 可执行文件（不经 LaunchServices）则图标正常显示。因此本项目不打包 
>
> `.app`
>
> ，
> 统一通过 
>
> `run.sh`
>
>  / LaunchAgent 直接运行可执行文件。

所有认证仅在本机内存中用于请求对应厂商接口，不写入 Quota Bar 自有存储。