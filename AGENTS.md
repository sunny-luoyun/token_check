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

## 真正的根因（2026-08-14 确认）：ReloadState 表堆积

**之前所有清理（删缓存目录 + killall chronod + lsregister）都无效的原因：**
widget 实例注册在 **系统级数据库** 中，不在 widget 容器里：

```
~/Library/Group Containers/group.com.apple.chronod/chronod/chrono.sql
```

此路径受 TCC 保护（macOS 26 连 root/launchd 都被拦截，需给终端 App 授予
"完全磁盘访问权限"才能访问）。

**卡顿根源：`ReloadState` 表（BundleID, Kind, DateReloadRequested）堆积了 13 万条记录。**
- 2026-08-14 实测：133,594 条，其中 `com.apple.Notes.WidgetExtension` 占 119,253 条
  （119,251 条 Kind 为 NULL，SQLite 主键中的 NULL 不参与唯一约束 → 无限堆积）
- `com.bing.lyrics.lyricsWidget` 占 13,016 条
- 每次任何 widget reload 时 chronod 都要处理这些历史 reload 状态 → 通知中心卡 15-20 秒
- token_check 本身只有 4 条（正常，每 kind 1 条）

**清理方法（授权后可执行）：**
```bash
DB="$HOME/Library/Group Containers/group.com.apple.chronod/chronod/chrono.sql"
# 1. 备份
cp "$DB" /tmp/chrono.sql.full.bak
# 2. 每个 (BundleID, Kind) 只保留最新一条
sqlite3 "$DB" "DELETE FROM ReloadState WHERE rowid NOT IN (
  SELECT r.rowid FROM ReloadState r
  INNER JOIN (SELECT BundleID, Kind, MAX(DateReloadRequested) AS max_dt
              FROM ReloadState GROUP BY BundleID, Kind) l
  ON r.BundleID = l.BundleID AND (r.Kind IS l.Kind) AND r.DateReloadRequested = l.max_dt);"
# 3. 验证
sqlite3 "$DB" "SELECT COUNT(*) FROM ReloadState;"   # 应降到几十条
```
清理后 app 下次刷新会自动重建 token_check 的 4 条 ReloadState（正常行为）。

**注意：**
- 清理时若 chronod 正在运行，token_check 的 ReloadState 可能被并发删除（无害，
  下次刷新自动重建；测试库重放验证 DELETE 逻辑本身不删 token_check）
- 若 Notes/lyrics 等系统组件继续异常堆积，需定期清理或查其自身 bug

## 最终根因（2026-08-14 实测确认）：NotificationCenter 进程的 fd 缓存

**ReloadState 清理后卡顿依旧（10-20 秒），实测发现真正的元凶：**

`NotificationCenter` 进程持有 widget timeline 文件的**打开句柄（fd）缓存**，
缓存内容来自历史上所有添加过的实例（含已删除的幽灵实例）。

**实测证据链：**
1. 桌面/通知中心实际只有 1 个大组件（实例 ID = `4482360981193516153`）
2. 但 `lsof -p <NotificationCenter PID>` 显示它持有 **9 个** V3 timeline 文件 fd
   （正是 8/13 清理前的全部 9 个实例 ID，含已删除的幽灵实例）
3. 每次刷新：app → chronod → 从 NotificationCenter 取实例列表 → 对全部
   9 个实例逐个 reload → 幽灵实例无法匹配 descriptor → 重试 → 通知中心卡 10-20 秒
4. **删磁盘 timeline 文件后，NotificationCenter 仍持有 fd，刷新时通过 fd
   重新写回文件（"删了又恢复"的真相）**
5. 重启 chronod 无效（它从 NotificationCenter 拿列表，依旧 9 个）
6. **`killall NotificationCenter` 后 fd 缓存清空，只重建真实实例** → 卡顿消失

**验证方法：**
```bash
# 检查 NotificationCenter 持有的 token_check timeline fd 数量
sudo lsof -p $(pgrep -x NotificationCenter | head -1) | grep TokenCheckLargeWidgetV3
# 应与通知中心实际组件数一致（正常为 1）
```

**根除方法（实测有效）：**
```bash
# 1. 删除幽灵 timeline 文件（保留真实实例对应的文件）
cd ~/Library/Containers/com.luoyun.tokencheck.widget/Data/SystemData/com.apple.chrono/timelines/TokenCheckLargeWidgetV3/
ls   # 记录当前文件，保留通知中心真实存在的那个实例 ID
rm -f systemLarge--<幽灵ID>*.chrono-timeline

# 2. 重启 NotificationCenter 清空 fd 缓存（关键步骤！）
killall NotificationCenter
```

**通用流程（卡顿复发时按序执行）：**
1. `killall NotificationCenter`（清除幽灵实例 fd 缓存）
2. 若 ReloadState 表再堆积：按上面 SQL 清理（需完全磁盘访问权限）
3. 检查 `timelines/<kind>/` 文件数应与通知中心实际组件数一致

**结论：**
- 改 `kind` 只是触发因素，真正让幽灵实例"永生"的是 NotificationCenter 的 fd 缓存
- 代码层面无法预防（系统行为），复发时执行上述清理即可
- 2026-08-14 实测：清理后每次刷新卡顿 <1 秒，恢复正常

## 2026-08-16 复发确认：幽灵 kind 被 app 无差别 reload 重新喂毒

**现象：** 8/14 修复后短暂正常，随后通知中心/桌面小组件每次刷新再次卡顿 10 秒以上，
使用越久越严重（"垃圾堆积"感）。用户以为是 8/15 DSH 数据源更新引入的。

**排查结论（证据链）：**
1. 解码通知中心实例注册表
   `~/Library/Containers/com.apple.notificationcenterui/Data/Library/Preferences/com.apple.notificationcenterui.plist`
   的 `widgets.instances`（NSKeyedArchiver）：token_check 目前只有 **2 个存活实例**——
   `TokenCheckLargeWidgetV3`（desktop Large）和 `ClashTrafficWidget`（desktop Small）。
   **没有** `TokenCheckSmallWidgetV2`、也没有 `TokenCheckWidgetV2`。
2. `timelines/TokenCheckSmallWidgetV2/` 下的 timeline 文件冻结在 **2026-08-14 09:30**
   （上一次清理会话期间被移除），而 V3 / Clash 的文件每个刷新周期都在更新
   （如 16:10:01 / 16:10:02）。
3. app 每次数据变化都会对 **全部 4 个 kind** 调用 `WidgetCenter.reloadTimelines(ofKind:)`
   （TokenViewModel.reloadWidgetTimelines 硬编码列表）。对幽灵 kind 的 reload 会重新触发
   chronod "No matching descriptor" 重试与 pendingTasks 堆积 —— 正是 AGENTS.md 已记录的
   卡顿机制。8/14 的 `killall NotificationCenter` 清了一次存量，但 app 每个周期继续给
   幽灵 kind 喂 reload 请求，垃圾重新堆积，约一天后回到 10 秒+。
4. 8/15 DSH 提交对 reload 逻辑零改动（git diff 可证），只是时间上恰好撞上堆积过阈值的点。

**修复（代码，2026-08-16）：**
- `TokenViewModel.reloadWidgetTimelines` 不再无差别 reload 4 个 kind，
  新增 `liveWidgetKinds()` 过滤：只 reload `timelines/<kind>/` 下有 24 小时内更新
  文件的 kind（存活实例的 timeline 文件会随数据变化被 chronod 重写；幽灵文件永久冻结）。
- 读不到 chrono 容器时回退到全部 kind（保持旧行为）；kind 目录不存在则跳过。
- 小组件自带 `.after(nextUpdate)` 时间线策略，即使被暂时跳过，存活实例也会在
  下一个周期自动刷新并把文件变新，因此该过滤自愈、不会永久漏刷。

**复发时的清理步骤（终端执行，需要先退出 token_check 主程序可选）：**
```bash
# 1. 删除幽灵 timeline 文件（本例为小热力图 kind）
rm -f ~/Library/Containers/com.luoyun.tokencheck.widget/Data/SystemData/com.apple.chrono/timelines/TokenCheckSmallWidgetV2/*.chrono-timeline

# 2. 重启 NotificationCenter 清空 fd 缓存（关键步骤！）
killall NotificationCenter
```
清理后 app 下次刷新会自动重建真实实例的 4 条 ReloadState（正常行为）。
