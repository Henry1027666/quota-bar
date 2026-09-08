#!/bin/zsh
# Quota Bar 一键启动/重启（macOS 26 下保证菜单栏图标显示的方式）
#
# 背景：macOS 26 (Tahoe) 会把「打包成 .app 的第三方菜单栏应用」的图标
# 默认放入隐藏区（Control Center blocked host），且应用无法编程绕过；
# 而直接运行可执行文件（不经 LaunchServices）时图标正常显示。
# 因此用 launchctl 直接管理 release 可执行文件，保证图标出现在菜单栏。
#
# 为什么用 launchctl 而不是 nohup：项目已注册 LaunchAgent
# com.henryzhang.quotabar（登录自启 + 崩溃自动重启 + KeepAlive）。若本脚本
# 再用 pkill + nohup 另起进程，会与 LaunchAgent 抢管同一可执行文件，
# 在 kill 后 KeepAlive 拉新实例与 nohup 新实例短暂并存 → 出现双图标/双进程。
# 统一由 launchctl kickstart 重启即可保证恒为单实例。
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"
launch_label="com.henryzhang.quotabar"

# 确保 release 构建存在
if [[ ! -x .build/release/QuotaBar ]]; then
    swift build -c release
fi

uid="$(id -u)"
# 若 LaunchAgent 已注册，走 launchctl（登录自启、崩溃自愈、单实例都由系统保证）
if launchctl print "gui/${uid}/${launch_label}" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/${uid}/${launch_label}"
    echo "Quota Bar 已通过 launchctl 重启（单实例，菜单栏图标应在右上角）。"
else
    # 兜底：没有 LaunchAgent 时直接后台运行（仅此分支会 nohup）
    pkill -f "$project_dir/.build/release/QuotaBar" 2>/dev/null || true
    nohup "$project_dir/.build/release/QuotaBar" >/dev/null 2>&1 &
    echo "Quota Bar 已启动（无 LaunchAgent 兜底模式），图标应出现在右上角菜单栏。"
fi
echo "提示：如果图标未出现，请点击菜单栏右上角「控制中心」→ 底部「菜单栏」区域，把 QuotaBar 点亮。"
