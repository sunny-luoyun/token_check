#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenCode Go 订阅页面更新监控

监控 https://opencode.ai/docs/zh-cn/go/ 对应的仓库源文件
packages/web/src/content/docs/zh-cn/go.mdx 的提交变更，
检测到更新时发送 macOS 通知中心提醒 + QQ 邮箱邮件。

依赖：仅 Python 3 标准库（urllib / smtplib / ssl / osascript）。
由 launchd 定时调用（见 com.langqin.opencode-go-monitor.plist）。
"""

import json
import os
import ssl
import smtplib
import subprocess
import sys
import time
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
FILE_PATH = "packages/web/src/content/docs/zh-cn/go.mdx"
PAGE_URL = "https://opencode.ai/docs/zh-cn/go/"
API_LATEST = f"https://api.github.com/repos/{REPO}/commits?path={FILE_PATH}&per_page=1"
API_COMMIT = f"https://api.github.com/repos/{REPO}/commits/{{sha}}"

# 价格表格中的模型名关键词（用于从 diff 里筛出模型行）
MODEL_KEYWORDS = (
    "DeepSeek", "MiMo", "Qwen", "Kimi", "MiniMax",
    "GPT", "Claude", "Grok", "Gemini", "Hy3", "GLM", "Llama",
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


def http_get_json(url: str, timeout: int = 30) -> dict:
    """GET 请求并解析 JSON，失败抛异常。"""
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "opencode-go-page-monitor",
    })
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
    return load_json(STATE_FILE, {"last_sha": None, "email_pending": None})


def load_config() -> dict:
    return load_json(CONFIG_FILE, {})


def has_cjk(text: str) -> bool:
    """判断文本是否包含中文字符（占位符检测用）。"""
    return any('\u4e00' <= ch <= '\u9fff' for ch in text)


def extract_summary(patch: str) -> list:
    """从 diff patch 中提取价格表格相关的增删行摘要。

    表格行特征：包含竖线分隔符且包含 $ 价格标记，或包含模型关键词。
    不同语言版本的文档会重复出现同一模型行（仅空格差异），
    因此按压缩空白后的内容去重。返回格式化为文本的行列表。
    """
    import re
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
        if not (has_model and has_price and content.startswith("|")):
            continue
        normalized = re.sub(r"\s+", " ", content)  # 压缩空白用于去重
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


# ---------- 主流程 ----------

def check_for_updates() -> int:
    state = load_state()
    config = load_config()

    # 1. 补发上次失败的邮件（配置好授权码后会自动补上）
    pending = state.get("email_pending")
    if pending and pending.get("sha"):
        log(f"补发上次未送达的邮件 ({pending['sha'][:8]})")
        title = f"[OpenCode Go] 页面更新: {pending.get('title', '')[:40]}"
        body = pending.get("body", "")
        if send_email(config, title, body):
            state["email_pending"] = None
            save_json(STATE_FILE, state)

    # 2. 查询文件最新提交
    try:
        commits = http_get_json(API_LATEST)
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        log(f"查询最新提交失败（网络或限流）: {exc}")
        return 0
    if not commits:
        log("查询最新提交失败：返回为空")
        return 0

    latest = commits[0]
    sha = latest["sha"]
    title = (latest.get("commit", {}).get("message", "") or "").splitlines()[0]
    author = (latest.get("commit", {}).get("author", {}) or {}).get("name", "?")
    date = (latest.get("commit", {}).get("committer", {}) or {}).get("date", "")

    last_sha = state.get("last_sha")
    if sha == last_sha:
        log(f"无更新，当前仍为 {sha[:8]} ({title[:40]})")
        return 0

    # 3. 拉取 commit 详情生成摘要
    summary_lines = []
    try:
        detail = http_get_json(API_COMMIT.format(sha=sha))
        # 合并所有语言版本文件的 patch，一次调用完成跨文件去重
        all_patch = "\n".join(
            fi.get("patch", "") for fi in detail.get("files", [])
        )
        summary_lines = extract_summary(all_patch)
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        log(f"获取提交详情失败: {exc}")

    # 4. 组装提醒内容
    short = sha[:8]
    summary_text = "\n".join(summary_lines) if summary_lines else "（本次变更未涉及模型价格表格行）"
    commit_url = f"https://github.com/{REPO}/commit/{sha}"

    notify_body = f"{title[:60]}\n{commit_url}"
    if summary_lines:
        notify_body = f"{title[:60]}\n{summary_text[:200]}"

    email_body = (
        f"OpenCode Go 订阅页面有更新！\n\n"
        f"提交: {title}\n"
        f"作者: {author}    时间: {date}\n"
        f"提交链接: {commit_url}\n\n"
        f"变更摘要:\n{summary_text}\n\n"
        f"页面: {PAGE_URL}\n"
        f"（本邮件由 go-page-monitor 自动发送）\n"
    )

    # 5. 通知 + 邮件（邮件失败则挂起待补发）
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

    # 6. 更新状态与历史记录
    state["last_sha"] = sha
    state["last_checked"] = now_str()
    save_json(STATE_FILE, state)

    with open(HISTORY_FILE, "a", encoding="utf-8") as f:
        f.write(f"{now_str()} | {short} | {title}\n")
        for line in summary_lines:
            f.write(f"    {line}\n")
        f.write("\n")

    log(f"检测到更新 {short}: {title}")
    log(f"通知: {'OK' if notify_ok else 'FAILED'}, 邮件: {'OK' if email_ok else 'PENDING'}")
    return 0


def establish_baseline() -> int:
    """首次运行：查询最新提交并记录为基线，不发送任何提醒。"""
    try:
        commits = http_get_json(API_LATEST)
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        log(f"建立基线失败: {exc}")
        return 1
    if not commits:
        log("建立基线失败：返回为空")
        return 1
    sha = commits[0]["sha"]
    title = (commits[0].get("commit", {}).get("message", "") or "").splitlines()[0]
    state = load_state()
    state["last_sha"] = sha
    state["last_checked"] = now_str()
    save_json(STATE_FILE, state)
    log(f"基线已建立: {sha[:8]} ({title[:40]})，后续有更新将提醒")
    return 0


def main() -> int:
    os.makedirs(os.path.join(BASE_DIR, "logs"), exist_ok=True)
    state = load_state()
    if not state.get("last_sha"):
        return establish_baseline()
    return check_for_updates()


if __name__ == "__main__":
    sys.exit(main())
