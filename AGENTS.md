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

## 教训：改 kind 后即使清理也会再次堆积

2026-07-16 将 `TokenCheckLargeWidgetV2` 改为 `TokenCheckLargeWidgetV3`（提交 4631334），
提交说明声称"chronod 缓存自动清理旧 kind"，但实际写的 `cleanupWidgetTimelineCache()`
只删除旧 kind 目录下的文件，对 chronod 数据库（BoardServices）中注册的实例毫无作用。

2026-08-13 检查发现：`timelines/TokenCheckLargeWidgetV3/` 下积压了 **9 个实例文件**
（实际通知中心只有 1-3 个真实实例），每次 `reloadTimelines(ofKind:)` chronod 都要
逐个 reload，通知中心再次卡死 10-30 秒。

**教训：**
- 不要轻信"自动清理旧 kind"的实现，改 kind 后必须手动执行上面的清理命令
- 清理后检查 `~/Library/Containers/com.luoyun.tokencheck.widget/Data/SystemData/com.apple.chrono/timelines/<kind>/` 下实例文件数量，应与通知中心实际组件数一致（每个实例一个文件，文件名含不同实例 ID）
- 实例 ID 在 `_backup_old_instances` 等备份目录中出现过、又出现在当前 timelines 下，说明该实例从未真正从 chronod 数据库清除，是幽灵实例
- 该无效清理逻辑（`cleanupWidgetTimelineCache`）已于 2026-08-13 删除，widget 内不再尝试自动清理 chronod 缓存
