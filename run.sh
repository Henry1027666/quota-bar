#!/bin/zsh
# Quota Bar 一键构建 / 打包 .app / 启动
#
# 运行方式（macOS 27）：打包为标准 .app（LSUIElement 菜单栏应用），经 LaunchServices 启动。
# LaunchServices 保证单实例；二进制变更时本脚本会重新构建并重打包。
#
# 前置要求：xcode-select 指向 Xcode（CommandLineTools 缺少 SwiftUIMacros 插件，无法编译
# SwiftUI），且已执行过 sudo xcodebuild -license accept。
#
# 注意：以 .app 启动时不继承 shell 环境变量（如 DEEPSEEK_API_KEY、CODEX_HOME）。
# 各厂商认证均按「环境变量 → 本机配置文件」顺序发现，依赖环境变量的场景请落盘到对应配置文件。
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"

APP_DIR="$project_dir/.build/QuotaBar.app"
BINARY="$project_dir/.build/release/QuotaBar"

# 1. release 构建：二进制缺失或源码比二进制新时重新构建
if [[ ! -x "$BINARY" ]] || [[ -n "$(find Sources -name '*.swift' -newer "$BINARY" -print -quit 2>/dev/null)" ]]; then
    echo "构建 release…"
    if ! swift build -c release; then
        echo "构建失败。请确认：xcode-select 指向 Xcode 且已执行 sudo xcodebuild -license accept" >&2
        exit 1
    fi
fi

# 2. 组装 .app bundle（Info.plist 见 Support/Info.plist，LSUIElement = 无 Dock 图标）
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/QuotaBar"
cp "$project_dir/Support/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$project_dir/Support/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
# 刷新 mtime，促使 LaunchServices 更新图标缓存
touch "$APP_DIR"

# 3. 用稳定的自签名证书签名。
#    不用 ad-hoc（codesign -s -）：adhoc 无固定身份，每次重建 macOS 都把 app 当成新应用，
#    会在「系统设置 → 菜单栏」里累积重复条目，钥匙串授权也无法继承。
#    固定证书签名后 designated requirement 恒定，菜单栏条目与钥匙串授权跨构建保持。
SIGN_IDENTITY="QuotaBar Development"
if ! security find-identity -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "首次运行：创建自签名代码签名证书（存入登录钥匙串，仅本机使用）…"
    tmpdir="$(mktemp -d)"
    cat > "$tmpdir/openssl.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = QuotaBar Development
[ ext ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
EOF
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$tmpdir/key.pem" -out "$tmpdir/cert.pem" \
        -config "$tmpdir/openssl.cnf" >/dev/null 2>&1
    openssl pkcs12 -export -out "$tmpdir/qb.p12" -inkey "$tmpdir/key.pem" \
        -in "$tmpdir/cert.pem" -passout pass:quotabar-dev
    security import "$tmpdir/qb.p12" -k ~/Library/Keychains/login.keychain-db \
        -P quotabar-dev -T /usr/bin/codesign -T /usr/bin/security
    rm -rf "$tmpdir"
fi
codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR"

# 4. 退出旧实例：应用会拒绝非用户发起的 terminate（SIGTERM 会被取消），
#    先走 quit AppleEvent（应用放行），再兜底强杀；同时清理历史上裸可执行文件运行的实例。
osascript -e 'tell application id "com.henryzhang.quotabar" to quit' >/dev/null 2>&1 || true
pkill -f "$APP_DIR/Contents/MacOS/QuotaBar" 2>/dev/null || true
pkill -f "$project_dir/.build/release/QuotaBar" 2>/dev/null || true
sleep 1
pkill -9 -f "$APP_DIR/Contents/MacOS/QuotaBar" 2>/dev/null || true
pkill -9 -f "$project_dir/.build/release/QuotaBar" 2>/dev/null || true

# 5. 启动
open "$APP_DIR"
echo "Quota Bar 已启动（$APP_DIR），图标应出现在右上角菜单栏。"
