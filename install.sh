#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="trae-checkin"
PY="python3"

echo "==== TRAE 自动签到系统 安装向导 ===="
echo "安装目录：$HERE"

if [ -d /data/data/com.termux ] || command -v termux-info >/dev/null 2>&1; then
    PLATFORM="termux"
else
    PLATFORM="linux"
fi
echo "检测到平台：$PLATFORM"

if ! command -v "$PY" >/dev/null 2>&1; then
    echo "[1/4] 未找到 python3，正在安装..."
    if [ "$PLATFORM" = "termux" ]; then
        pkg update -y
        pkg install -y python
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -y || apt-get update -y
        sudo apt-get install -y python3 python3-pip || apt-get install -y python3 python3-pip
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y python3 python3-pip
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y python3 python3-pip
    else
        echo "未识别的包管理器，请手动安装 python3 后重新运行本脚本"
        exit 1
    fi
else
    echo "[1/4] python3 已就绪"
fi

echo "[2/4] 安装 cryptography 依赖（用于解密 storage.json）"
if [ "$PLATFORM" = "termux" ]; then
    pip install cryptography || pkg install -y python-cryptography || echo "安装 cryptography 失败，可用 refresh_token 方式代替（无需解密）"
else
    pip3 install --break-system-packages cryptography 2>/dev/null || pip3 install cryptography || echo "安装 cryptography 失败，可用 refresh_token 方式代替（无需解密）"
fi

echo "[3/4] 生成配置文件"
if [ -f "$HERE/config.json" ]; then
    echo "config.json 已存在，跳过复制"
else
    cp "$HERE/config.example.json" "$HERE/config.json"
    echo "已生成 config.json，请编辑填写 TRAE 凭据（见部署说明.md 第三章）"
fi

echo "[4/4] 配置每日定时任务"
if [ "$PLATFORM" = "termux" ]; then
    if ! command -v crond >/dev/null 2>&1 && ! command -v cron >/dev/null 2>&1; then
        echo "未检测到 cron，正在安装 cronie..."
        pkg install -y cronie || echo "cronie 安装失败，请手动执行：pkg install cronie"
    fi
    LINE="5 9 * * * cd $HERE && $PY $HERE/trae_checkin.py >> $HERE/logs/cron.log 2>&1"
    ( crontab -l 2>/dev/null | grep -v "trae_checkin.py" ; echo "$LINE" ) | crontab -
    echo "已写入 Termux crontab：每天 09:05 自动签到"
    echo "请手动启动 cron 服务：crond 或 termux-services 中启用 cron"
    echo "（完整说明见部署说明.md 第五章）"
else
    SERVICE_DIR="$HOME/.config/systemd/user"
    mkdir -p "$SERVICE_DIR"
    cat > "$SERVICE_DIR/$NAME.service" <<EOF
[Unit]
Description=TRAE auto checkin service

[Service]
Type=oneshot
ExecStart=$PY $HERE/trae_checkin.py
EOF
    cat > "$SERVICE_DIR/$NAME.timer" <<EOF
[Unit]
Description=TRAE auto checkin timer

[Timer]
OnCalendar=*-*-* 09:05:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl --user daemon-reload || true
    systemctl --user enable --now "$NAME.timer" || true
    echo "已创建并启用 systemd 定时器（每天 09:05）"
    echo "查看状态：systemctl --user list-timers | grep $NAME"
    echo "如需免登录自启，请执行：sudo loginctl enable-linger $(whoami)"
fi

echo
echo "==== 安装完成 ===="
echo "下一步："
echo "1. 编辑 $HERE/config.json 填写 TRAE 凭据"
echo "2. 手动试跑一次：$PY $HERE/trae_checkin.py"
echo "3. 确认输出正常后即可交给定时任务"
