# Widget Kind 改名注意事项

## 问题

`chronod`（macOS WidgetKit 守护进程）会将 widget 实例信息持久化到系统内部的 BoardServices SQLite 数据库中。
**修改 widget 的 `kind: String` 值后，chronod 数据库中的旧实例不会自动清理。**
每次 app 刷新时 chronod 都会尝试 reload 这些旧实例，通知中心会因此卡死 10-30 秒。

## 根因

- widget 的 `kind` 属性（如 `TokenCheckLargeWidgetV2`）被修改后，旧 kind 名对应的实例仍留在 chronod 数据库中
- chronod reload 旧实例 → `"No matching descriptor"` 错误 → 定时重试 → 循环
- `pendingTasks` 堆积 → 通知中心打开时等待 chronod 处理完毕 → 卡顿

## 改名前必须执行

```bash
# 1. 彻底清除 chronod 旧缓存
rm -rf ~/Library/Containers/com.luoyun.tokencheck.widget/Data/SystemData/com.apple.chrono

# 2. 重启 chronod 和重新注册 LaunchServices
killall chronod 2>/dev/null
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -R -f -trusted /Applications/token_check.app
```

## 不改名就没事

如果只修改 widget 内部 UI 逻辑、不改 `kind` 值，不会触发此问题。
