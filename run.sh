#!/bin/zsh
# Quota Bar 一键启动（macOS 26 下保证菜单栏图标显示的方式）
#
# 背景：macOS 26 (Tahoe) 会把「打包成 .app 的第三方菜单栏应用」的图标
# 默认放入隐藏区（Control Center blocked host），且应用无法编程绕过；
# 而直接运行可执行文件（不经 LaunchServices）时图标正常显示。
# 因此本脚本直接启动 release 可执行文件，保证图标出现在菜单栏。
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"

# 确保 release 构建存在
if [[ ! -x .build/release/QuotaBar ]]; then
    swift build -c release
fi

# 已有实例则先退出，避免重复
pkill -f "$project_dir/.build/release/QuotaBar" 2>/dev/null || true

# 后台启动，图标直接出现在菜单栏
nohup "$project_dir/.build/release/QuotaBar" >/dev/null 2>&1 &
echo "Quota Bar 已启动，图标应出现在右上角菜单栏。"
echo "提示：如果图标未出现，请点击菜单栏右上角「控制中心」→ 底部「菜单栏」区域，把 QuotaBar 点亮。"
