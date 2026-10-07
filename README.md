# TRAE 自动签到系统

把 TRAE 和有道龙虾（LobsterAI）的每日签到做成一套可以一键部署的开源工具。填好配置、挂上定时任务，每天自动帮你把积分领到手。

## 它能干什么

| 模块 | 方式 | 说明 |
| --- | --- | --- |
| TRAE 签到 | 接口签到 | 读取本机登录凭据，自动解密、自动刷新 token，每日领取积分并上报余额（基础额度 + 额外额度合计） |
| 有道龙虾签到 | 界面点击 | 用 UI Automation 点击客户端右上角「每日积分礼」，找不到按钮时用系统 OCR 兜底，点击前后自动截图存证 |

## 项目结构

```
TRAE自动签到系统开源/
├── README.md              本文件，项目门面
├── 部署说明.md            最详细的操作手册，从零开始三平台部署
├── trae_checkin.py        TRAE 签到主程序（Python，跨平台）
├── lobster_checkin.ps1    有道龙虾签到脚本（Windows PowerShell）
├── config.example.json    配置模板，复制为 config.json 后填写
├── install.sh             Linux / Termux 一键安装
└── install.ps1            Windows 一键安装
```

## 一键开始（速览）

- **Windows**：装 Python → 复制 `config.example.json` 为 `config.json` 并填写 → 右键管理员运行 `install.ps1` → 完成
- **Linux**：`bash install.sh` → 编辑 `config.json` → 完成（systemd 定时器已就绪）
- **Termux（安卓）**：`bash install.sh` → 编辑 `config.json` → 启动 cron → 完成

### 两行命令装（不用先 clone）

```bash
# Linux / macOS
curl -fsSL https://github.com/furrynaling-alt/trae-lobster-checkin/archive/refs/heads/main.tar.gz | tar xz && cd trae-lobster-checkin-main && bash install.sh

# Termux（安卓）
pkg install -y curl && curl -fsSL https://github.com/furrynaling-alt/trae-lobster-checkin/archive/refs/heads/main.tar.gz | tar xz && cd trae-lobster-checkin-main && bash install.sh
```

Windows 不用命令行：下载本仓库的 zip 解压，然后右键管理员运行 `install.ps1`。

详细到每一步的图文说明见 `部署说明.md`。

## 关键事实

- TRAE 凭据位于本机 `%APPDATA%\Trae CN\User\globalStorage\storage.json`（Linux 同类客户端在 `~/.config/<客户端名>/User/globalStorage/storage.json`），其中 `iCubeAuthInfo://icube.cloudide` 字段为 AES-128-CBC 加密的登录凭据
- TRAE 签到接口为 `POST https://api.trae.cn/trae/api/v2/ug/checkin_credits/status` 与 `.../claim`
- 有道龙虾必须用 `--force-renderer-accessibility` 参数启动，否则界面元素树只有两三个节点，按钮无法定位

## 免责声明

本项目仅供学习交流。请遵守各平台服务条款，合理使用，勿滥用接口；凭据仅保存在你自己的机器上，本项目不会上传任何数据。
