# token_check

macOS 菜单栏应用：统计 [opencode](https://opencode.ai) 与本地 DSH（deveco）数据库的 token 用量、费用与会话数据，并提供 WidgetKit 桌面小组件（今日用量热力图、月/年热力图、Clash 订阅流量）。

## 功能

- 今日 / 月 / 年 token 用量与费用统计（含回滚校正、按模型 / 项目 / Agent 维度）
- 会话历史列表、费用面板、每日趋势图表
- 桌面小组件：大尺寸年度热力图（`TokenCheckLargeWidgetV3`）、小尺寸热力图（`TokenCheckSmallWidgetV2`）、Clash 订阅流量（`ClashTrafficWidget`）
- DeepSeek 余额查询、OpenCode 订阅用量（官方 API）、Clash 订阅流量监控

## 构建

- Xcode 26+（`MACOSX_DEPLOYMENT_TARGET = 26.0`，Swift 5）
- 打开 `token_check.xcodeproj`，选择 `token_check` scheme 直接 Build & Run
- 主 App 与 Widget 扩展共用 App Group `group.com.luoyun.tokencheck` 交换数据

## 目录结构

```
token_check/            主 App（SwiftUI + MVVM）
  Models/               数据模型
  Services/             数据库、用量统计、widget 数据服务等
  ViewModels/           视图模型
  Views/                界面与组件
token_checkWidget/      WidgetKit 扩展
go-page-monitor/        独立的 opencode Go 页面更新监控脚本（Python + launchd）
```

## 注意事项

- **Widget kind 改名**会触发 chronod 幽灵实例导致通知中心卡顿，改名前必读 [AGENTS.md](AGENTS.md) 的清理流程
- API Key（DeepSeek / OpenCode）明文存储于 App Group UserDefaults：个人工具的已知取舍（单用户设备 + widget 跨进程读取），如需分发请迁移 Keychain
- `go-page-monitor/config.json` 含邮件授权码，已被 gitignore，不会入库

## 维护记录

Widget chronod 幽灵实例、ReloadState 堆积、NotificationCenter fd 缓存等排查结论与清理命令见 [AGENTS.md](AGENTS.md)。
