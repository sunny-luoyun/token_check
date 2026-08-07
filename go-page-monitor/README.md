# OpenCode Go 页面更新监控

监控 [https://opencode.ai/docs/zh-cn/go/](https://opencode.ai/docs/zh-cn/go/) 的订阅付费计划页面，
页面有更新（模型增删、价格调整、隐私政策变化等）时自动提醒。

## 工作原理

该页面对应 GitHub 仓库 `anomalyco/opencode` 中的源文件
`packages/web/src/content/docs/zh-cn/go.mdx`，每次页面更新必然先改这个文件。
脚本通过 GitHub API 精确追踪该文件的最新提交，与本地记录的 SHA 比对，
检测到更新时：

1. 解析 diff，提取涉及模型价格表格行的变更摘要
2. 发送 macOS 通知中心提醒
3. 发送 QQ 邮箱邮件（正文含完整摘要 + 链接）

## 文件说明

| 文件 | 作用 |
|---|---|
| `check.py` | 主脚本，仅依赖 Python 标准库 |
| `config.json` | SMTP 邮件配置（含授权码，已加入 .gitignore） |
| `state.json` | 本地状态：上次检测的 SHA（自动生成，已 gitignore） |
| `history.log` | 每次更新的提交记录 + 变更摘要（自动追加） |
| `logs/run.log` | 运行日志 |
| `com.langqin.opencode-go-monitor.plist` | launchd 定时任务模板 |

## 首次配置（一次性）

### 1. 生成 QQ 邮箱授权码

1. 登录 [QQ 邮箱](https://mail.qq.com) → 设置 → 账号
2. 找到「POP3/IMAP/SMTP/Exchange/CardDAV/CalDAV 服务」
3. 开启「SMTP 服务」，按提示发送短信验证后生成**授权码**（16 位字符串）

### 2. 填写 config.json

```json
{
  "smtp": {
    "host": "smtp.qq.com",
    "port": 465,
    "sender": "你的QQ号@qq.com",
    "auth_code": "你的16位授权码"
  },
  "recipients": ["你的QQ号@qq.com"]
}
```

文件权限建议收紧：`chmod 600 config.json`

### 3. 安装定时任务

```bash
cp com.langqin.opencode-go-monitor.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.langqin.opencode-go-monitor.plist
```

验证：

```bash
launchctl list | grep opencode
```

## 使用说明

- 默认**每 6 小时**检查一次（plist 中 `StartInterval = 21600` 秒，改后需 reload）
- 首次运行自动建立基线（记录当前最新提交），**不会**发送提醒
- 邮件发送失败不会丢失：状态会挂起，下次运行自动补发
- 手动立即检查：`python3 check.py`
- 卸载：`launchctl unload ~/Library/LaunchAgents/com.langqin.opencode-go-monitor.plist`

## 注意

- 邮件授权码是敏感信息，**不要提交到 git**（config.json 已在 .gitignore）
- GitHub API 未认证限额 60 次/小时，每 6 小时 1 次绰绰有余
