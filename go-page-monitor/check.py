#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenCode Go 订阅页面更新监控

监控 https://opencode.ai/docs/zh-cn/go/ 及其 console 订阅页相关的
仓库源文件提交变更，检测到更新时发送 macOS 通知中心提醒 + QQ 邮箱邮件。

监控范围（多路径）：
- packages/web/src/content/docs/go.mdx        英文文档
- packages/web/src/content/docs/zh-cn/go.mdx  中文文档
- packages/console/app/src/routes/go/index.tsx 订阅页组件
- packages/console/app/src/routes/go/index.css  订阅页样式
- packages/console/app/src/i18n/en.ts          i18n 英文文案
- packages/console/app/src/i18n/zh.ts          i18n 中文文案

依赖：仅 Python 3 标准库（urllib / smtplib / ssl / osascript）。
由 launchd 定时调用（见 com.langqin.opencode-go-monitor.plist）。
"""

import json
import os
import re
import ssl
import smtplib
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

# ---------- 常量 ----------

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = os.path.join(BASE_DIR, "state.json")
CONFIG_FILE = os.path.join(BASE_DIR, "config.json")
HISTORY_FILE = os.path.join(BASE_DIR, "history.log")
LOG_FILE = os.path.join(BASE_DIR, "logs", "run.log")

REPO = "anomalyco/opencode"
PAGE_URL = "https://opencode.ai/docs/zh-cn/go/"

# 需要监控的仓库源文件路径（有提交变更即触发提醒）
WATCH_PATHS = (
    "packages/web/src/content/docs/go.mdx",
    "packages/web/src/content/docs/zh-cn/go.mdx",
    "packages/console/app/src/routes/go/index.tsx",
    "packages/console/app/src/routes/go/index.css",
    "packages/console/app/src/i18n/en.ts",
    "packages/console/app/src/i18n/zh.ts",
)

API_LATEST = f"https://api.github.com/repos/{REPO}/commits?path={{path}}&per_page=1"
API_COMMIT = f"https://api.github.com/repos/{REPO}/commits/{{sha}}"

# 价格表格中的模型名关键词（用于从 diff 里筛出模型行）
MODEL_KEYWORDS = (
    "DeepSeek", "MiMo", "Qwen", "Kimi", "MiniMax",
    "GPT", "Claude", "Grok", "Gemini", "Hy3", "GLM", "Llama",
)
# i18n / 文案行关键词（fallback 摘要用）
TEXT_KEYWORDS = (
    "usage", "price", "pricing", "model", "quota", "limit",
    "subscription", "plan", "credit", "balance", "2x", "usage",
)

MAX_SUMMARY_LINES = 12  # 摘要里最多展示多少行 diff


# ---------- 工具函数 ----------

def now_str() -> str:
    return datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S")


def log(message: str) -> None:
    """追加到运行日志，同时打印到 stdout（launchd 也会重定向）。"""
    line = f"{now_str()} | {message}"
    print(line)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def http_get_json(url: str, token: str = "", timeout: int = 30) -> dict:
    """GET 请求并解析 JSON，失败抛异常。带 token 时走认证接口（5000 次/小时限额）。"""
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "opencode-go-page-monitor",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def load_json(path: str, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return default


def save_json(path: str, data) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def load_state() -> dict:
    state = load_json(STATE_FILE, {})
    # 兼容旧版单一 last_sha 状态：迁移为按路径记录
    if "last_shas" not in state and state.get("last_sha"):
        state["last_shas"] = {path: state["last_sha"] for path in WATCH_PATHS}
        state["last_sha"] = None
    return state


def load_config() -> dict:
    return load_json(CONFIG_FILE, {})


def get_token(config: dict) -> str:
    """优先读环境变量 GITHUB_TOKEN，其次读 config.json 的 github_token。"""
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not token:
        token = (config.get("github_token") or "").strip()
    return token


def has_cjk(text: str) -> bool:
    """判断文本是否包含中文字符（占位符检测用）。"""
    return any('\u4e00' <= ch <= '\u9fff' for ch in text)


def looks_like_code(content: str) -> bool:
    """粗略判断一行 diff 内容是否像代码而非人类可读文案。"""
    if content.startswith(("|", "@@", "import", "export", "const", "return")):
        return False
    if '"' not in content and "=>" in content:
        return True
    return False


def extract_summary(patch: str) -> list:
    """从 diff patch 中提取价格表格相关的增删行摘要。

    表格行特征：包含竖线分隔符且包含 $ 价格标记，或包含模型关键词。
    若没有表格行（如 i18n 文案改动），退回提取人类可读的字符串行。
    不同语言版本的文档会重复出现同一模型行（仅空格差异），
    因此按压缩空白后的内容去重。返回格式化为文本的行列表。
    """
    lines = []
    seen = set()
    for raw in patch.splitlines():
        if not raw or raw.startswith("@@"):
            continue
        marker = raw[0]
        if marker not in ("+", "-"):
            continue
        content = raw[1:].strip()
        has_model = any(kw.lower() in content.lower() for kw in MODEL_KEYWORDS)
        has_price = "$" in content
        if has_model and has_price and content.startswith("|"):
            normalized = re.sub(r"\s+", " ", content)
            if normalized in seen:
                continue
            seen.add(normalized)
            lines.append(f"{marker} {content}")
            if len(lines) >= MAX_SUMMARY_LINES:
                break
    if lines:
        return lines

    # fallback：提取引号包裹的字符串行（i18n 文案 / 组件文本）
    for raw in patch.splitlines():
        if not raw or raw.startswith("@@"):
            continue
        marker = raw[0]
        if marker not in ("+", "-"):
            continue
        content = raw[1:].strip()
        if not content or looks_like_code(content) or len(content) > 150:
            continue
        has_text_kw = any(kw.lower() in content.lower() for kw in TEXT_KEYWORDS)
        has_model = any(kw.lower() in content.lower() for kw in MODEL_KEYWORDS)
        if not (has_text_kw or has_model):
            continue
        normalized = re.sub(r"\s+", " ", content)
        if normalized in seen:
            continue
        seen.add(normalized)
        lines.append(f"{marker} {content}")
        if len(lines) >= MAX_SUMMARY_LINES:
            break
    return lines


def send_notification(title: str, body: str) -> bool:
    """通过 osascript 发送 macOS 通知中心提醒。"""
    escaped_title = title.replace("\\", "\\\\").replace('"', '\\"')
    escaped_body = body.replace("\\", "\\\\").replace('"', '\\"')
    script = (
        'display notification "{}" with title "{}"'
    ).format(escaped_body, escaped_title)
    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        log(f"通知发送失败: {result.stderr.strip()}")
        return False
    return True


def send_email(config: dict, title: str, body: str) -> bool:
    """通过 SMTP 发送邮件（默认 smtp.qq.com:465 SSL）。

    未配置授权码（或仍是中文占位符）时直接返回 False，不抛异常。
    """
    from email.message import EmailMessage

    smtp_cfg = config.get("smtp") or {}
    sender = smtp_cfg.get("sender", "")
    auth_code = smtp_cfg.get("auth_code", "")
    recipients = config.get("recipients") or ([sender] if sender else [])
    # 授权码应为英数字符串，sender 应为邮箱格式；含中文说明还是占位符
    if (
        not sender or not auth_code or not recipients
        or has_cjk(sender) or has_cjk(auth_code)
        or "@" not in sender
    ):
        log("邮件未发送：config.json 中 SMTP 授权码未配置（见 README）")
        return False
    host = smtp_cfg.get("host", "smtp.qq.com")
    port = int(smtp_cfg.get("port", 465))

    msg = EmailMessage()
    msg["From"] = sender
    msg["To"] = ", ".join(recipients)
    msg["Subject"] = title
    msg.set_content(body)

    try:
        context = ssl.create_default_context()
        with smtplib.SMTP_SSL(host, port, context=context, timeout=30) as server:
            server.login(sender, auth_code)
            server.send_message(msg)
        log(f"邮件已发送至 {', '.join(recipients)}")
        return True
    except Exception as exc:  # noqa: BLE001
        log(f"邮件发送失败: {exc}")
        return False


# ---------- GitHub API ----------

def fetch_latest_per_path(token: str) -> dict:
    """查询每个监控路径的最新提交，返回 {path: {sha, title, date}}。

    任一路径查询失败时抛异常（由调用方决定是否重试）。
    """
    result = {}
    for path in WATCH_PATHS:
        url = API_LATEST.format(path=path)
        commits = http_get_json(url, token)
        if not commits:
            continue
        c = commits[0]
        result[path] = {
            "sha": c["sha"],
            "title": (c.get("commit", {}).get("message", "") or "").splitlines()[0],
            "date": (c.get("commit", {}).get("committer", {}) or {}).get("date", ""),
        }
    return result


def pick_latest(per_path: dict) -> tuple:
    """从 {path: {...}} 里挑出日期最新的那条，返回 (path, info)。

    若某路径无数据则跳过；全部为空时返回 (None, None)。
    """
    best_path, best_info = None, None
    for path, info in per_path.items():
        if best_info is None or (info.get("date") or "") > (best_info.get("date") or ""):
            best_path, best_info = path, info
    return best_path, best_info


# ---------- 主流程 ----------

def check_for_updates() -> int:
    state = load_state()
    config = load_config()
    token = get_token(config)
    if token:
        log("使用 GitHub token 认证（认证限额 5000 次/小时）")
    else:
        log("警告: 未配置 GitHub token，将使用匿名接口（限额 60 次/小时，易 403）")

    # 1. 补发上次失败的邮件（配置好授权码后会自动补上）
    pending = state.get("email_pending")
    if pending and pending.get("sha"):
        log(f"补发上次未送达的邮件 ({pending['sha'][:8]})")
        title = f"[OpenCode Go] 页面更新: {pending.get('title', '')[:40]}"
        body = pending.get("body", "")
        if send_email(config, title, body):
            state["email_pending"] = None
            save_json(STATE_FILE, state)

    # 2. 查询各监控路径的最新提交
    try:
        per_path = fetch_latest_per_path(token)
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        log(f"查询最新提交失败（网络或限流）: {exc}")
        return 0
    if not per_path:
        log("查询最新提交失败：所有路径均返回为空")
        return 0

    last_shas = state.get("last_shas") or {}

    # 3. 找出相对旧基线新增/变化的路径
    changed = []
    for path, info in per_path.items():
        old = last_shas.get(path)
        if old != info["sha"]:
            changed.append((path, info))

    if not changed:
        latest_path, latest_info = pick_latest(per_path)
        log(f"无更新，当前最新仍为 {latest_info['sha'][:8]} ({latest_info['title'][:40]})")
        return 0

    # 4. 取变化路径里最新的一条作为本次主角
    changed_sorted = sorted(changed, key=lambda x: x[1].get("date") or "", reverse=True)
    _, latest = changed_sorted[0]
    sha = latest["sha"]
    title = latest["title"]
    author = "opencode-agent[bot]"  # 由 commit 详情覆盖
    date = latest.get("date", "")

    # 5. 拉取 commit 详情生成摘要（合并所有变化路径的 patch）
    summary_lines = []
    try:
        detail = http_get_json(API_COMMIT.format(sha=sha), token)
        author = (detail.get("commit", {}).get("author", {}) or {}).get("name", "?")
        date = (detail.get("commit", {}).get("committer", {}) or {}).get("date", "") or date
        all_patch = "\n".join(
            fi.get("patch", "") for fi in detail.get("files", [])
        )
        summary_lines = extract_summary(all_patch)
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        log(f"获取提交详情失败: {exc}")

    # 6. 组装提醒内容
    short = sha[:8]
    summary_text = "\n".join(summary_lines) if summary_lines else "（本次变更未涉及模型价格表格行）"
    commit_url = f"https://github.com/{REPO}/commit/{sha}"
    changed_hint = f"变更文件: {', '.join(p.split('/')[-1] for p, _ in changed)}"

    notify_body = f"{title[:60]}\n{commit_url}"
    if summary_lines:
        notify_body = f"{title[:60]}\n{summary_text[:200]}"

    email_body = (
        f"OpenCode Go 订阅页面有更新！\n\n"
        f"提交: {title}\n"
        f"作者: {author}    时间: {date}\n"
        f"提交链接: {commit_url}\n\n"
        f"变更摘要:\n{summary_text}\n\n"
        f"{changed_hint}\n"
        f"页面: {PAGE_URL}\n"
        f"（本邮件由 go-page-monitor 自动发送）\n"
    )

    # 7. 通知 + 邮件（邮件失败则挂起待补发）
    notify_ok = send_notification("OpenCode Go 页面更新", notify_body)
    email_ok = send_email(config, f"[OpenCode Go] 页面更新: {title[:50]}", email_body)
    if not email_ok:
        state["email_pending"] = {
            "sha": sha,
            "title": title,
            "body": email_body,
        }
    else:
        state["email_pending"] = None

    # 8. 更新状态与历史记录（按路径保存各自最新 sha）
    state["last_shas"] = {p: info["sha"] for p, info in per_path.items()}
    state["last_checked"] = now_str()
    save_json(STATE_FILE, state)

    with open(HISTORY_FILE, "a", encoding="utf-8") as f:
        f.write(f"{now_str()} | {short} | {title}\n")
        for line in summary_lines:
            f.write(f"    {line}\n")
        f.write(f"    变更文件: {', '.join(p.split('/')[-1] for p, _ in changed)}\n")
        f.write("\n")

    log(f"检测到更新 {short}: {title}")
    log(changed_hint)
    log(f"通知: {'OK' if notify_ok else 'FAILED'}, 邮件: {'OK' if email_ok else 'PENDING'}")
    return 0


def establish_baseline() -> int:
    """首次运行 / 状态重置：查询各路径最新提交并记录为基线，不发送任何提醒。"""
    config = load_config()
    token = get_token(config)
    try:
        per_path = fetch_latest_per_path(token)
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        log(f"建立基线失败: {exc}")
        return 1
    if not per_path:
        log("建立基线失败：所有路径均返回为空")
        return 1

    state = load_state()
    state["last_shas"] = {p: info["sha"] for p, info in per_path.items()}
    state["last_checked"] = now_str()
    save_json(STATE_FILE, state)

    latest_path, latest_info = pick_latest(per_path)
    log(f"基线已建立: {latest_info['sha'][:8]} ({latest_info['title'][:40]})，后续有更新将提醒")
    for path, info in per_path.items():
        log(f"  {path.split('/')[-1]:<18} {info['sha'][:8]} ({info['title'][:40]})")
    return 0


def main() -> int:
    os.makedirs(os.path.join(BASE_DIR, "logs"), exist_ok=True)

    # 手动触发一次提醒链路（验证通知 + 邮件）
    if "--test-notify" in sys.argv:
        ok_n = send_notification("OpenCode Go 监控测试", "这是一条测试通知。配置已就绪。")
        config = load_config()
        ok_e = send_email(config, "[OpenCode Go] 监控测试", "这是一封测试邮件，说明监控链路正常。")
        log(f"测试通知: 通知 {'OK' if ok_n else 'FAILED'}, 邮件 {'OK' if ok_e else 'FAILED'}")
        return 0

    state = load_state()
    if not state.get("last_shas"):
        return establish_baseline()
    return check_for_updates()


if __name__ == "__main__":
    sys.exit(main())
