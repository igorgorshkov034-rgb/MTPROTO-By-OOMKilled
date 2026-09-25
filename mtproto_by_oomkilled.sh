#!/usr/bin/env bash
# ==============================================================================
# Script Name : MTPROTO_By_OOMKilled
# Description : Standalone Subscription & Config Portal By OOMKilled
# Author      : OOMKilled
# Version     : 2.0
# ==============================================================================

set -euo pipefail

SCRIPT_VERSION="2.0"
INSTALL_DIR="/opt/mtproto_by_oomkilled"
WEB_SERVICE="/etc/systemd/system/mtproto-web.service"
GUARDIAN_SERVICE="/etc/systemd/system/mtproto-guardian.service"
USER_DATA_FILE="$INSTALL_DIR/users_meta.json"
BRANDING_FILE="$INSTALL_DIR/branding.json"
VPN_STORAGE_DIR="$INSTALL_DIR/vpn_configs"
META_FILE="/etc/mtproto_oomkilled.conf"
BACKUP_DIR="/var/backups/mtproto_oomkilled"
GITHUB_REPO_URL="https://raw.githubusercontent.com/igorgorshkov034-rgb/MTPROTO-By-OOMKilled/refs/heads/main/mtproto_by_oomkilled.sh"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "\e[31m[ERROR] Скрипт должен запускаться с правами root (sudo)!\e[0m"
        exit 1
    fi
}

write_app_modules() {
    mkdir -p "$INSTALL_DIR" "$VPN_STORAGE_DIR"

    if [[ ! -f "$BRANDING_FILE" ]]; then
        cat <<'EOF' > "$BRANDING_FILE"
{
  "service_name": "OOMKilled Portal",
  "support_link": "https://t.me/telegram",
  "guide_ios": "1. Нажмите «Подключить в Telegram» или скопируйте ключ/файл.\n2. Импортируйте параметры в ваше приложение.",
  "guide_android": "1. Нажмите кнопку подключения или скачайте VPN-файл ниже.\n2. Добавьте его в установленный VPN-клиент.",
  "guide_desktop": "1. Скопируйте ключ или скачайте файл конфигурации.\n2. Импортируйте его в настольный клиент."
}
EOF
    fi

    # Демон контроля сроков действия подписок
    cat <<'EOF' > "$INSTALL_DIR/guardian.py"
import json, os, time

DATA_PATH = "/opt/mtproto_by_oomkilled/users_meta.json"

def check_expired_users():
    if not os.path.exists(DATA_PATH):
        return
    try:
        with open(DATA_PATH, "r") as f:
            meta = json.load(f)
    except Exception:
        return

    now = int(time.time())
    changed = False

    for user, info in meta.items():
        exp = info.get("expires_at", 0)
        status = info.get("status", "active")

        if status == "paused":
            continue

        if exp > 0 and now > exp:
            if status != "expired":
                info["status"] = "expired"
                changed = True

    if changed:
        try:
            with open(DATA_PATH, "w") as f:
                json.dump(meta, f, indent=2)
        except Exception:
            pass

if __name__ == "__main__":
    while True:
        check_expired_users()
        time.sleep(30)
EOF

    # Веб-панель управления и страница клиента с ZIP-выгрузкой
    cat <<'EOF' > "$INSTALL_DIR/web_panel.py"
import os, re, secrets, psutil, json, time, io, tarfile, shutil, zipfile
from fastapi import FastAPI, Depends, HTTPException, status, Form, UploadFile, File
from fastapi.responses import HTMLResponse, RedirectResponse, StreamingResponse, FileResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials

app = FastAPI(title="OOMKilled Portal v2.0")
security = HTTPBasic()

DATA_PATH = "/opt/mtproto_by_oomkilled/users_meta.json"
BRANDING_PATH = "/opt/mtproto_by_oomkilled/branding.json"
VPN_DIR = "/opt/mtproto_by_oomkilled/vpn_configs"
META_PATH = "/etc/mtproto_oomkilled.conf"

os.makedirs(VPN_DIR, exist_ok=True)

def get_meta():
    meta = {}
    if os.path.exists(META_PATH):
        with open(META_PATH) as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    meta[k] = v
    return meta

def get_users_meta():
    if os.path.exists(DATA_PATH):
        try:
            with open(DATA_PATH, "r") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}

def save_users_meta(data):
    with open(DATA_PATH, "w") as f:
        json.dump(data, f, indent=2)

def get_branding():
    default_b = {
        "service_name": "OOMKilled Portal",
        "support_link": "https://t.me/telegram",
        "guide_ios": "1. Нажмите «Подключить в Telegram» или скопируйте ключ/файл.",
        "guide_android": "1. Нажмите кнопку подключения или скачайте VPN-файл ниже.",
        "guide_desktop": "1. Скопируйте ключ или скачайте файл конфигурации."
    }
    if os.path.exists(BRANDING_PATH):
        try:
            with open(BRANDING_PATH) as f:
                b = json.load(f)
                default_b.update(b)
        except Exception:
            pass
    return default_b

def save_branding(data):
    with open(BRANDING_PATH, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

def auth_user(credentials: HTTPBasicCredentials = Depends(security)):
    meta = get_meta()
    admin_user = meta.get("WEB_USER", "admin")
    admin_pass = meta.get("WEB_PASS", "oomkilled")
    if not (secrets.compare_digest(credentials.username, admin_user) and secrets.compare_digest(credentials.password, admin_pass)):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Неверный логин или пароль",
            headers={"WWW-Authenticate": "Basic"},
        )
    return credentials.username

def list_user_vpn_files(username: str):
    u_dir = os.path.join(VPN_DIR, username)
    if os.path.exists(u_dir):
        return sorted(os.listdir(u_dir))
    return []

@app.get("/logout")
def logout():
    return HTMLResponse(
        content="""<!DOCTYPE html>
<html lang="ru"><head><meta charset="UTF-8"><title>Выход</title></head>
<body style="background:#0f172a; color:#f8fafc; font-family:sans-serif; text-align:center; padding-top:60px;">
    <h2>Вы успешно вышли из панели</h2>
    <p><a href="/" style="color:#38bdf8; text-decoration:none; font-weight:bold;">Войти снова</a></p>
</body></html>""",
        status_code=401,
        headers={"WWW-Authenticate": "Basic"}
    )

@app.get("/backup")
def download_backup(user: str = Depends(auth_user)):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for p in [DATA_PATH, META_PATH, BRANDING_PATH, VPN_DIR]:
            if os.path.exists(p):
                tar.add(p, arcname=os.path.basename(p))
    buf.seek(0)
    filename = f"portal_backup_{int(time.time())}.tar.gz"
    return StreamingResponse(
        buf,
        media_type="application/gzip",
        headers={"Content-Disposition": f"attachment; filename={filename}"}
    )

@app.get("/sub/{token}/download/{filename}")
def download_client_vpn(token: str, filename: str):
    users = get_users_meta()
    target_name = None
    for u_name, u_info in users.items():
        if u_info.get("sub_token") == token:
            target_name = u_name
            break
    if not target_name:
        raise HTTPException(status_code=404, detail="Подписка не найдена")

    safe_name = os.path.basename(filename)
    file_path = os.path.join(VPN_DIR, target_name, safe_name)
    if not os.path.exists(file_path):
        raise HTTPException(status_code=404, detail="Файл не найден")

    return FileResponse(file_path, filename=safe_name)

@app.get("/sub/{token}/download-all-zip")
def download_all_vpn_zip(token: str):
    users = get_users_meta()
    target_name = None
    for u_name, u_info in users.items():
        if u_info.get("sub_token") == token:
            target_name = u_name
            break
    if not target_name:
        raise HTTPException(status_code=404, detail="Подписка не найдена")

    user_dir = os.path.join(VPN_DIR, target_name)
    files = list_user_vpn_files(target_name)
    if not files:
        raise HTTPException(status_code=404, detail="Файлы конфигураций отсутствуют")

    zip_buffer = io.BytesIO()
    with zipfile.ZipFile(zip_buffer, "w", zipfile.ZIP_DEFLATED) as zip_file:
        for f in files:
            full_path = os.path.join(user_dir, f)
            if os.path.isfile(full_path):
                zip_file.write(full_path, arcname=f)

    zip_buffer.seek(0)
    zip_filename = f"{target_name}_configs.zip"
    return StreamingResponse(
        zip_buffer,
        media_type="application/zip",
        headers={"Content-Disposition": f"attachment; filename={zip_filename}"}
    )

@app.get("/sub/{token}", response_class=HTMLResponse)
def subscription_page(token: str):
    branding = get_branding()
    users = get_users_meta()
    target_user = None
    target_name = ""

    for u_name, u_info in users.items():
        if u_info.get("sub_token") == token:
            target_user = u_info
            target_name = u_name
            break

    if not target_user:
        raise HTTPException(status_code=404, detail="Подписка не найдена")

    now = int(time.time())
    exp = target_user.get("expires_at", 0)
    u_status = target_user.get("status", "active")
    proxy_url = target_user.get("proxy_url", "").strip()
    custom_key = target_user.get("custom_key", "").strip()

    if u_status == "paused":
        status_text = "Приостановлена"
        status_color = "#f59e0b"
        days_str = "На паузе"
    elif exp > 0 and now > exp:
        status_text = "Срок действия истёк"
        status_color = "#ef4444"
        days_str = "Истекла"
    elif exp == 0:
        status_text = "Активна"
        status_color = "#10b981"
        days_str = "Бессрочно"
    else:
        status_text = "Активна"
        status_color = "#10b981"
        days_left = max(1, int((exp - now) / 86400))
        days_str = f"{days_left} дн."

    proxy_block = ""
    if proxy_url:
        proxy_block = f"""
        <div style="margin-top: 15px;">
            <a href="{proxy_url}" class="btn">Подключить в Telegram</a>
            <div class="code">{proxy_url}</div>
        </div>
        """

    key_block = ""
    if custom_key:
        key_block = f"""
        <div class="custom-key-card">
            <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:8px;">
                <span style="font-weight:600; font-size:14px; color:#38bdf8;">🔑 Ключ конфигурации:</span>
                <button type="button" class="btn-copy" onclick="copyKey()">📋 Скопировать ключ</button>
            </div>
            <textarea id="key-text" class="key-area" readonly>{custom_key}</textarea>
        </div>
        """

    vpn_files = list_user_vpn_files(target_name)
    vpn_files_html = ""
    if vpn_files:
        zip_btn_html = ""
        if len(vpn_files) > 1:
            zip_btn_html = f"""
            <a href="/sub/{token}/download-all-zip" class="btn-zip-all" download>📦 Скачать все (ZIP)</a>
            """

        vpn_files_html += f"""
        <div class='vpn-box'>
            <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:10px;">
                <h3 style='margin:0; font-size:15px; color:#38bdf8;'>📁 Файлы конфигураций</h3>
                {zip_btn_html}
            </div>
        """
        for f_name in vpn_files:
            dl_url = f"/sub/{token}/download/{f_name}"
            vpn_files_html += f"""
            <div class='vpn-item'>
                <span style='font-family:monospace; font-size:13px; color:#cbd5e1;'>📄 {f_name}</span>
                <a href='{dl_url}' class='btn-download' download>Скачать</a>
            </div>
            """
        vpn_files_html += "</div>"

    ios_text = branding.get("guide_ios", "").replace("\n", "<br>")
    android_text = branding.get("guide_android", "").replace("\n", "<br>")
    desktop_text = branding.get("guide_desktop", "").replace("\n", "<br>")
    support_url = branding.get("support_link", "")

    return f"""<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{branding.get('service_name', 'Portal')} | {target_name}</title>
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0b0f19; color: #f8fafc; margin: 0; padding: 20px; }}
        .wrap {{ max-width: 520px; margin: 0 auto; background: #1e293b; border-radius: 16px; padding: 25px; border: 1px solid #334155; box-shadow: 0 10px 25px rgba(0,0,0,0.5); }}
        h2 {{ color: #38bdf8; margin: 0 0 15px 0; text-align: center; }}
        .header-badge {{ text-align: center; margin-bottom: 20px; }}
        .info-pill {{ display: inline-block; background: #0f172a; padding: 6px 14px; border-radius: 20px; font-size: 13px; border: 1px solid #334155; }}
        .btn {{ display: block; width: 100%; box-sizing: border-box; background: #10b981; color: #fff; text-decoration: none; padding: 12px; border-radius: 8px; font-weight: bold; font-size: 16px; text-align: center; margin-top: 10px; }}
        .btn:hover {{ background: #059669; }}
        .btn-support {{ display: block; width: 100%; box-sizing: border-box; background: #3b82f6; color: #fff; text-decoration: none; padding: 10px; border-radius: 8px; font-weight: bold; font-size: 14px; text-align: center; margin-top: 10px; }}
        .btn-support:hover {{ background: #2563eb; }}
        .code {{ background: #020617; padding: 10px; border-radius: 6px; font-family: monospace; font-size: 11px; word-break: break-all; color: #94a3b8; margin-top: 10px; border: 1px solid #334155; }}
        
        .custom-key-card {{ background: #0f172a; border: 1px solid #334155; border-radius: 10px; padding: 14px; margin-top: 18px; text-align: left; }}
        .key-area {{ width: 100%; box-sizing: border-box; background: #020617; color: #38bdf8; font-family: monospace; font-size: 12px; padding: 8px; border-radius: 6px; border: 1px solid #1e293b; resize: none; height: 65px; }}
        .btn-copy {{ background: #38bdf8; color: #0f172a; border: none; padding: 5px 12px; border-radius: 5px; font-weight: bold; font-size: 12px; cursor: pointer; }}
        .btn-copy:hover {{ background: #0ea5e9; }}

        .vpn-box {{ background: #0f172a; border: 1px solid #334155; border-radius: 10px; padding: 14px; margin-top: 20px; text-align: left; }}
        .vpn-item {{ display: flex; justify-content: space-between; align-items: center; padding: 8px 0; border-bottom: 1px solid #1e293b; }}
        .vpn-item:last-child {{ border-bottom: none; }}
        .btn-download {{ background: #6366f1; color: #fff; text-decoration: none; padding: 5px 12px; border-radius: 5px; font-size: 12px; font-weight: bold; }}
        .btn-download:hover {{ background: #4f46e5; }}
        .btn-zip-all {{ background: #0284c7; color: #fff; text-decoration: none; padding: 4px 10px; border-radius: 5px; font-size: 11px; font-weight: bold; }}
        .btn-zip-all:hover {{ background: #0369a1; }}

        .tabs {{ display: flex; gap: 6px; margin-top: 25px; border-bottom: 1px solid #334155; padding-bottom: 8px; }}
        .tab-btn {{ background: none; border: none; color: #94a3b8; font-weight: bold; cursor: pointer; padding: 6px 12px; border-radius: 6px; font-size: 14px; }}
        .tab-btn.active {{ background: #334155; color: #38bdf8; }}
        .tab-content {{ display: none; padding: 14px 0 0 0; font-size: 13px; line-height: 1.6; color: #cbd5e1; text-align: left; }}
        .tab-content.active {{ display: block; }}
    </style>
</head>
<body>
    <div class="wrap">
        <h2>{branding.get('service_name', 'Portal')}</h2>
        <div class="header-badge">
            <div class="info-pill">Пользователь: <strong>{target_name}</strong></div>
            <div style="margin-top: 8px;">Статус: <strong style="color:{status_color};">{status_text}</strong> | Срок: <strong>{days_str}</strong></div>
        </div>

        {proxy_block}
        {key_block}
        {vpn_files_html}

        {f'<a href="{support_url}" target="_blank" class="btn-support">Связаться с техподдержкой</a>' if support_url else ''}

        <div class="tabs">
            <button class="tab-btn active" onclick="showTab('ios', this)">iOS</button>
            <button class="tab-btn" onclick="showTab('android', this)">Android</button>
            <button class="tab-btn" onclick="showTab('desktop', this)">ПК</button>
        </div>
        <div id="tab-ios" class="tab-content active">{ios_text}</div>
        <div id="tab-android" class="tab-content">{android_text}</div>
        <div id="tab-desktop" class="tab-content">{desktop_text}</div>
    </div>

    <script>
        function showTab(platform, btn) {{
            document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
            document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));
            btn.classList.add('active');
            document.getElementById('tab-' + platform).classList.add('active');
        }}

        function copyKey() {{
            const key = document.getElementById('key-text');
            if (key) {{
                key.select();
                navigator.clipboard.writeText(key.value).then(() => {{
                    alert('Ключ скопирован в буфер обмена!');
                }});
            }}
        }}
    </script>
</body>
</html>"""

@app.get("/", response_class=HTMLResponse)
def dashboard(user: str = Depends(auth_user)):
    meta = get_meta()
    branding = get_branding()
    web_port = int(meta.get("WEB_PORT", 8080))
    ip = meta.get("IP", "127.0.0.1")

    cpu_usage = psutil.cpu_percent(interval=0.1)
    ram_usage = psutil.virtual_memory().percent

    users = get_users_meta()
    now = int(time.time())

    user_cards = ""
    for u_name, u_info in users.items():
        proxy_url = u_info.get("proxy_url", "")
        custom_key = u_info.get("custom_key", "")
        sub_token = u_info.get("sub_token", "")
        sub_url = f"http://{ip}:{web_port}/sub/{sub_token}"

        exp = u_info.get("expires_at", 0)
        u_status = u_info.get("status", "active")

        if u_status == "paused":
            exp_str = "<span style='color:#f59e0b;'>На паузе</span>"
            badge_color = "#f59e0b"
            pause_btn_text = "Включить"
            pause_btn_color = "#10b981"
        elif exp == 0:
            exp_str = "<span style='color:#10b981;'>Бессрочно</span>"
            badge_color = "#10b981"
            pause_btn_text = "Пауза"
            pause_btn_color = "#f59e0b"
        elif now > exp:
            exp_str = "<span style='color:#ef4444;'>Истёк</span>"
            badge_color = "#ef4444"
            pause_btn_text = "Пауза"
            pause_btn_color = "#f59e0b"
        else:
            days_left = max(1, int((exp - now) / 86400))
            exp_str = f"<span style='color:#38bdf8;'>Осталось {days_left} дн.</span>"
            badge_color = "#10b981"
            pause_btn_text = "Пауза"
            pause_btn_color = "#f59e0b"

        attached_files = list_user_vpn_files(u_name)
        files_chips = ""
        for af in attached_files:
            files_chips += f"""
            <span class="file-chip">
                <span>📄 {af}</span>
                <form action="/delete-vpn-file" method="post" style="margin:0;">
                    <input type="hidden" name="username" value="{u_name}">
                    <input type="hidden" name="filename" value="{af}">
                    <button type="submit" class="file-chip-del" title="Удалить файл">✕</button>
                </form>
            </span>
            """

        user_cards += f"""
        <div class="card">
            <div class="user-header">
                <div>
                    <span style="display:inline-block; width:10px; height:10px; border-radius:50%; background:{badge_color}; margin-right:6px;"></span>
                    <strong style="font-size:15px;">{u_name}</strong>
                    <span style="font-size:12px; color:#94a3b8; margin-left:10px;">Срок: {exp_str}</span>
                </div>
                <div style="display:flex; gap:6px;">
                    <form action="/renew-user" method="post" style="margin:0;">
                        <input type="hidden" name="username" value="{u_name}">
                        <button type="submit" class="btn-action" style="background:#10b981;">+30 дней</button>
                    </form>
                    <form action="/toggle-pause" method="post" style="margin:0;">
                        <input type="hidden" name="username" value="{u_name}">
                        <button type="submit" class="btn-action" style="background:{pause_btn_color};">{pause_btn_text}</button>
                    </form>
                    <form action="/delete-user" method="post" style="margin:0;">
                        <input type="hidden" name="username" value="{u_name}">
                        <button type="submit" class="btn-action btn-del">Удалить</button>
                    </form>
                </div>
            </div>

            <div style="font-size:12px; margin-bottom:12px; display:flex; justify-content:space-between; align-items:center;">
                <div>
                    <span style="color:#94a3b8;">Ссылка клиента:</span> 
                    <a href="{sub_url}" target="_blank" style="color:#38bdf8; word-break:break-all;">{sub_url}</a>
                </div>
                <a href="{sub_url}" target="_blank" class="btn-sub">Открыть страницу</a>
            </div>

            <form action="/update-proxy-url" method="post" style="margin-bottom:8px;">
                <input type="hidden" name="username" value="{u_name}">
                <div style="display:flex; gap:8px;">
                    <input type="text" name="proxy_url" value="{proxy_url}" placeholder="Ссылка Telegram-прокси (tg://proxy?server=...)" style="flex:1; padding:6px 10px; font-size:12px;">
                    <button type="submit" style="padding:6px 12px; font-size:12px; background:#0284c7;">Сохранить прокси</button>
                </div>
            </form>

            <form action="/update-key" method="post" style="margin-bottom:10px;">
                <input type="hidden" name="username" value="{u_name}">
                <div style="display:flex; gap:8px;">
                    <input type="text" name="custom_key" value="{custom_key}" placeholder="Ключ VPN / подписка (VLESS, Shadowsocks и др.)" style="flex:1; padding:6px 10px; font-size:12px; font-family:monospace;">
                    <button type="submit" style="padding:6px 12px; font-size:12px; background:#6366f1;">Сохранить ключ</button>
                </div>
            </form>

            <div class="vpn-attach-zone">
                <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:6px;">
                    <span style="color:#94a3b8; font-weight:600;">VPN-файлы клиента:</span>
                    <form action="/upload-vpn-file" method="post" enctype="multipart/form-data" style="margin:0;">
                        <input type="hidden" name="username" value="{u_name}">
                        <label class="custom-file-upload">
                            <input type="file" name="file" onchange="this.form.submit()" required>
                            📎 Прикрепить файл
                        </label>
                    </form>
                </div>
                <div class="chips-container">
                    {files_chips if files_chips else '<span style="color:#64748b; font-size:11px;">Нет прикрепленных файлов</span>'}
                </div>
            </div>
        </div>
        """

    html = f"""<!DOCTYPE html>
    <html lang="ru">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>OOMKilled Portal v2.0</title>
        <style>
            body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #f8fafc; margin: 0; padding: 20px; }}
            .container {{ max-width: 940px; margin: 0 auto; }}
            .header-bar {{ display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; }}
            .actions {{ display: flex; gap: 10px; align-items: center; }}
            .btn-backup {{ background: #0284c7; color: #fff; text-decoration: none; padding: 8px 14px; border-radius: 6px; font-weight: bold; font-size: 13px; }}
            .btn-backup:hover {{ background: #0369a1; }}
            .btn-logout {{ background: #ef4444; color: #fff; text-decoration: none; padding: 8px 14px; border-radius: 6px; font-weight: bold; font-size: 13px; }}
            .btn-logout:hover {{ background: #dc2626; }}
            
            .main-nav {{ display: flex; gap: 8px; margin-bottom: 20px; border-bottom: 2px solid #334155; padding-bottom: 4px; }}
            .nav-tab {{ background: transparent; border: none; color: #94a3b8; font-size: 15px; font-weight: bold; padding: 10px 18px; border-radius: 8px 8px 0 0; cursor: pointer; transition: 0.2s; }}
            .nav-tab:hover {{ color: #f8fafc; background: #1e293b; }}
            .nav-tab.active {{ color: #38bdf8; background: #1e293b; border-bottom: 3px solid #38bdf8; }}
            .menu-section {{ display: none; }}
            .menu-section.active {{ display: block; }}

            .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; margin-bottom: 25px; }}
            .stat-box {{ background: #1e293b; padding: 18px; border-radius: 12px; border: 1px solid #334155; text-align: center; }}
            .stat-val {{ font-size: 24px; font-weight: bold; color: #38bdf8; margin-top: 5px; }}
            .panel {{ background: #1e293b; padding: 20px; border-radius: 12px; border: 1px solid #334155; margin-bottom: 25px; }}
            .form-grid {{ display: grid; grid-template-columns: 2fr 1fr 1fr auto; gap: 10px; margin-top: 15px; }}
            input, select, textarea {{ padding: 10px; border-radius: 6px; border: 1px solid #475569; background: #0f172a; color: #fff; box-sizing: border-box; font-family: inherit; }}
            button {{ background: #0284c7; color: #fff; border: none; padding: 10px 18px; border-radius: 6px; cursor: pointer; font-weight: bold; }}
            button:hover {{ background: #0369a1; }}
            .card {{ background: #0f172a; border: 1px solid #334155; border-radius: 8px; padding: 14px; margin-bottom: 12px; }}
            .user-header {{ display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }}
            .btn-action {{ padding: 5px 9px; font-size: 11px; border-radius: 4px; }}
            .btn-del {{ background: #ef4444; }}
            .btn-del:hover {{ background: #dc2626; }}
            .btn-sub {{ display: inline-block; background: #6366f1; color: #fff; text-decoration: none; padding: 5px 12px; border-radius: 4px; font-size: 12px; font-weight: bold; }}
            .brand-field {{ margin-bottom: 15px; }}
            .brand-field label {{ display: block; font-size: 13px; color: #94a3b8; margin-bottom: 6px; font-weight: 600; }}
            
            .vpn-attach-zone {{ background: #080d1a; border: 1px dashed #334155; border-radius: 8px; padding: 10px 14px; margin-top: 10px; }}
            .custom-file-upload {{ display: inline-flex; align-items: center; background: #3b82f6; color: #fff; padding: 5px 12px; border-radius: 5px; font-size: 11px; font-weight: bold; cursor: pointer; transition: 0.2s; }}
            .custom-file-upload:hover {{ background: #2563eb; }}
            .custom-file-upload input[type="file"] {{ display: none; }}
            .chips-container {{ display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }}
            .file-chip {{ background: #1e293b; border: 1px solid #475569; padding: 4px 10px; border-radius: 6px; font-size: 12px; display: inline-flex; align-items: center; gap: 6px; color: #e2e8f0; }}
            .file-chip-del {{ background: none; border: none; color: #ef4444; font-weight: bold; cursor: pointer; padding: 0 2px; font-size: 12px; line-height: 1; }}
            .file-chip-del:hover {{ color: #f87171; }}
        </style>
    </head>
    <body>
        <div class="container">
            <div class="header-bar">
                <h1 style="margin:0; color:#38bdf8;">⚡ OOMKilled Portal <span style="font-size:16px; color:#a855f7;">v2.0</span></h1>
                <div class="actions">
                    <a href="/backup" class="btn-backup">Скачать Бэкап</a>
                    <a href="/logout" class="btn-logout">Выйти</a>
                </div>
            </div>

            <div class="main-nav">
                <button class="nav-tab active" onclick="switchNav('users', this)">👥 Пользователи</button>
                <button class="nav-tab" onclick="switchNav('branding', this)">⚙️ Настройки страницы подписки</button>
            </div>

            <div id="section-users" class="menu-section active">
                <div class="grid">
                    <div class="stat-box"><div>Всего пользователей</div><div class="stat-val">{len(users)}</div></div>
                    <div class="stat-box"><div>Нагрузка CPU</div><div class="stat-val">{cpu_usage}%</div></div>
                    <div class="stat-box"><div>Использование ОЗУ</div><div class="stat-val">{ram_usage}%</div></div>
                </div>

                <div class="panel">
                    <h3 style="margin-top:0;">Создать пользователя </h3>
                    <form action="/add-user" method="post" class="form-grid">
                        <input type="text" name="username" placeholder="Имя пользователя" required>
                        <select name="days">
                            <option value="0">Бессрочно</option>
                            <option value="7">7 дней</option>
                            <option value="30" selected>30 дней</option>
                            <option value="90">90 дней</option>
                            <option value="365">1 год</option>
                        </select>
                        <input type="text" name="proxy_url" placeholder="Ссылка прокси (необязательно)">
                        <button type="submit">+ Добавить</button>
                    </form>
                </div>

                <div class="panel">
                    <h3 style="margin-top:0;">Список пользователей, ссылки и файлы</h3>
                    {user_cards if user_cards else '<p style="color:#64748b;">Пользователи отсутствуют</p>'}
                </div>
            </div>

            <div id="section-branding" class="menu-section">
                <div class="panel">
                    <h3 style="margin-top:0; color:#38bdf8;">Кастомизация страницы подписки</h3>
                    <p style="color:#94a3b8; font-size:13px; margin-top:-5px; margin-bottom:20px;">
                        Здесь настраивается персональная страница <code>/sub/token</code>, которую видят клиенты.
                    </p>
                    <form action="/save-branding" method="post">
                        <div style="display:grid; grid-template-columns: 1fr 1fr; gap:16px;">
                            <div class="brand-field">
                                <label>Название сервиса:</label>
                                <input type="text" name="service_name" value="{branding.get('service_name', '')}" style="width:100%;" required>
                            </div>
                            <div class="brand-field">
                                <label>Ссылка на техподдержку (Telegram):</label>
                                <input type="text" name="support_link" value="{branding.get('support_link', '')}" style="width:100%;" placeholder="https://t.me/your_support">
                            </div>
                        </div>
                        <div class="brand-field">
                            <label>Инструкция подключения для iOS:</label>
                            <textarea name="guide_ios" rows="3" style="width:100%;">{branding.get('guide_ios', '')}</textarea>
                        </div>
                        <div class="brand-field">
                            <label>Инструкция подключения для Android:</label>
                            <textarea name="guide_android" rows="3" style="width:100%;">{branding.get('guide_android', '')}</textarea>
                        </div>
                        <div class="brand-field">
                            <label>Инструкция подключения для ПК (Desktop):</label>
                            <textarea name="guide_desktop" rows="3" style="width:100%;">{branding.get('guide_desktop', '')}</textarea>
                        </div>
                        <button type="submit" style="background:#10b981; margin-top:5px;">Сохранить параметры подписки</button>
                    </form>
                </div>
            </div>
        </div>

        <script>
            function switchNav(sec, btn) {{
                document.querySelectorAll('.nav-tab').forEach(t => t.classList.remove('active'));
                document.querySelectorAll('.menu-section').forEach(s => s.classList.remove('active'));
                btn.classList.add('active');
                document.getElementById('section-' + sec).classList.add('active');
            }}
        </script>
    </body>
    </html>
    """
    return html

@app.post("/update-proxy-url")
def update_proxy_url(username: str = Form(...), proxy_url: str = Form(""), user: str = Depends(auth_user)):
    users = get_users_meta()
    if username in users:
        users[username]["proxy_url"] = proxy_url.strip()
        save_users_meta(users)
    return RedirectResponse("/", status_code=status.HTTP_303_SEE_OTHER)

@app.post("/update-key")
def update_key(username: str = Form(...), custom_key: str = Form(""), user: str = Depends(auth_user)):
    users = get_users_meta()
    if username in users:
        users[username]["custom_key"] = custom_key.strip()
        save_users_meta(users)
    return RedirectResponse("/", status_code=status.HTTP_303_SEE_OTHER)

@app.post("/renew-user")
def renew_user(username: str = Form(...), user: str = Depends(auth_user)):
    users = get_users_meta()
    if username in users:
        now = int(time.time())
        current_exp = users[username].get("expires_at", 0)
        base_time = max(now, current_exp) if current_exp > 0 else now
        users[username]["expires_at"] = base_time + (30 * 86400)
        users[username]["status"] = "active"
        save_users_meta(users)
    return RedirectResponse("/", status_code=status.HTTP_303_SEE_OTHER)

@app.post("/toggle-pause")
def toggle_pause(username: str = Form(...), user: str = Depends(auth_user)):
    users = get_users_meta()
    if username in users:
        current_st = users[username].get("status", "active")
        users[username]["status"] = "paused" if current_st != "paused" else "active"
        save_users_meta(users)
    return RedirectResponse("/", status_code=status.HTTP_303_SEE_OTHER)

@app.post("/upload-vpn-file")
async def upload_vpn_file(username: str = Form(...), file: UploadFile = File(...), user: str = Depends(auth_user)):
    users = get_users_meta()
    if username in users and file.filename:
        safe_filename = os.path.basename(file.filename)
        u_dir = os.path.join(VPN_DIR, username)
        os.makedirs(u_dir, exist_ok=True)
        dest = os.path.join(u_dir, safe_filename)
        with open(dest, "wb") as f:
            shutil.copyfileobj(file.file, f)
    return RedirectResponse("/", status_code=status.HTTP_303_SEE_OTHER)

@app.post("/delete-vpn-file")
def delete_vpn_file(username: str = Form(...), filename: str = Form(...), user: str = Depends(auth_user)):
    safe_name = os.path.basename(filename)
    target = os.path.join(VPN_DIR, username, safe_name)
    if os.path.exists(target):
        os.remove(target)
    return RedirectResponse("/", status_code=status.HTTP_303_SEE_OTHER)

@app.post("/save-branding")
def update_branding(
    service_name: str = Form(...),
    support_link: str = Form(""),
    guide_ios: str = Form(""),
    guide_android: str = Form(""),
    guide_desktop: str = Form(""),
    user: str = Depends(auth_user)
):
    save_branding({
        "service_name": service_name.strip(),
        "support_link": support_link.strip(),
        "guide_ios": guide_ios.strip(),
        "guide_android": guide_android.strip(),
        "guide_desktop": guide_desktop.strip()
    })
    return RedirectResponse("/", status_code=status.HTTP_303_SEE_OTHER)

@app.post("/add-user")
def add_user(username: str = Form(...), days: int = Form(0), proxy_url: str = Form(""), user: str = Depends(auth_user)):
    username = re.sub(r'[^a-zA-Z0-9_-]', '', username)
    if username:
        users = get_users_meta()
        now = int(time.time())
        exp = (now + (days * 86400)) if days > 0 else 0
        users[username] = {
            "proxy_url": proxy_url.strip(),
            "sub_token": secrets.token_urlsafe(16),
            "custom_key": "",
            "created_at": now,
            "expires_at": exp,
            "status": "active"
        }
        save_users_meta(users)
    return RedirectResponse("/", status_code=status.HTTP_303_SEE_OTHER)

@app.post("/delete-user")
def delete_user(username: str = Form(...), user: str = Depends(auth_user)):
    users = get_users_meta()
    if username in users and len(users) > 1:
        del users[username]
        save_users_meta(users)
        u_dir = os.path.join(VPN_DIR, username)
        if os.path.exists(u_dir):
            shutil.rmtree(u_dir, ignore_errors=True)
    return RedirectResponse("/", status_code=status.HTTP_303_SEE_OTHER)
EOF
}

if [[ "${1:-}" == "--upgrade-modules" ]]; then
    systemctl stop mtproto-proxy.service 2>/dev/null || true
    systemctl disable mtproto-proxy.service 2>/dev/null || true
    rm -f /etc/systemd/system/mtproto-proxy.service /usr/local/bin/oom-rotate-tls 2>/dev/null || true

    write_app_modules
    python3 -c "
import json, os, secrets
p = '$USER_DATA_FILE'
if os.path.exists(p):
    with open(p) as f: d = json.load(f)
    ch = False
    for k, v in d.items():
        if 'proxy_url' not in v:
            v['proxy_url'] = ''
            ch = True
        if 'sub_token' not in v:
            v['sub_token'] = secrets.token_urlsafe(16)
            ch = True
        if 'status' not in v:
            v['status'] = 'active'
            ch = True
        if 'custom_key' not in v:
            v['custom_key'] = ''
            ch = True
    if ch:
        with open(p, 'w') as f: json.dump(d, f, indent=2)
" 2>/dev/null || true

    systemctl daemon-reload
    systemctl restart mtproto-web.service mtproto-guardian.service
    exit 0
fi

create_backup() {
    echo -e "\n\e[34m=== Резервное копирование конфигурации ===\e[0m"
    mkdir -p "$BACKUP_DIR"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local archive_name="portal_backup_${timestamp}.tar.gz"
    local archive_path="${BACKUP_DIR}/${archive_name}"

    tar -czf "$archive_path" -C / opt/mtproto_by_oomkilled/users_meta.json opt/mtproto_by_oomkilled/branding.json opt/mtproto_by_oomkilled/vpn_configs etc/mtproto_oomkilled.conf 2>/dev/null || true

    if [[ -f "$archive_path" ]]; then
        echo -e "\e[32m✔ Бэкап успешно создан:\e[0m \e[33m$archive_path\e[0m"
    else
        echo -e "\e[31m✖ Ошибка создания бэкапа.\e[0m"
    fi
}

restore_backup() {
    echo -e "\n\e[34m=== Восстановление из резервной копии ===\e[0m"
    read -rp "Укажите полный путь к архиву (.tar.gz): " BACKUP_FILE

    if [[ ! -f "$BACKUP_FILE" ]]; then
        echo -e "\e[31m✖ Файл не найден: $BACKUP_FILE\e[0m"
        return 1
    fi

    echo "Восстановление файлов..."
    tar -xzf "$BACKUP_FILE" -C /
    systemctl daemon-reload
    systemctl restart mtproto-web.service mtproto-guardian.service
    echo -e "\e[32m✔ Конфигурация восстановлена, службы перезапущены!\e[0m"
    show_info
}

install_all() {
    echo -e "\n\e[34m=== Установка OOMKilled Portal v${SCRIPT_VERSION} ===\e[0m"

    echo "Установка системных пакетов..."
    apt-get update -qq
    apt-get install -y -qq python3 python3-venv python3-pip curl psmisc tar zip unzip > /dev/null

    read -rp "Введите порт для Веб-панели [по умолчанию 8080]: " WEB_PORT
    WEB_PORT=${WEB_PORT:-8080}

    read -rp "Логин администратора веб-панели [по умолчанию admin]: " WEB_USER
    WEB_USER=${WEB_USER:-admin}

    read -rp "Пароль администратора веб-панели [по умолчанию oomkilled]: " WEB_PASS
    WEB_PASS=${WEB_PASS:-oomkilled}

    if [[ -d "$INSTALL_DIR" ]]; then
        systemctl stop mtproto-proxy.service mtproto-web.service mtproto-guardian.service 2>/dev/null || true
        rm -rf "$INSTALL_DIR"
    fi

    mkdir -p "$INSTALL_DIR"
    echo "Сборка изолированного Python-окружения..."
    python3 -m venv "$INSTALL_DIR/venv"
    "$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
    "$INSTALL_DIR/venv/bin/pip" install --quiet fastapi uvicorn psutil python-multipart

    SUB_TOKEN=$(openssl rand -hex 12 2>/dev/null || tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 24)
    IP=$(curl -s -4 ifconfig.me || curl -s -4 api.ipify.org)

    cat <<EOF > "$USER_DATA_FILE"
{
  "oom_default": {
    "proxy_url": "",
    "sub_token": "$SUB_TOKEN",
    "custom_key": "",
    "created_at": $(date +%s),
    "expires_at": 0,
    "status": "active"
  }
}
EOF

    write_app_modules

    cat <<EOF > "$WEB_SERVICE"
[Unit]
Description=OOMKilled Web Portal
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/uvicorn web_panel:app --host 0.0.0.0 --port $WEB_PORT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF > "$GUARDIAN_SERVICE"
[Unit]
Description=OOMKilled Portal Guardian
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python3 $INSTALL_DIR/guardian.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF > "$META_FILE"
IP=$IP
WEB_PORT=$WEB_PORT
WEB_USER=$WEB_USER
WEB_PASS=$WEB_PASS
EOF

    if command -v ufw &>/dev/null && ufw status | grep -qw active; then
        ufw allow "$WEB_PORT"/tcp >/dev/null 2>&1 || true
    fi

    systemctl stop mtproto-proxy.service 2>/dev/null || true
    systemctl disable mtproto-proxy.service 2>/dev/null || true
    rm -f /etc/systemd/system/mtproto-proxy.service /usr/local/bin/oom-rotate-tls 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable --now mtproto-web.service mtproto-guardian.service

    echo -e "\e[32m✔ Установка версии ${SCRIPT_VERSION} успешно завершена!\e[0m"
    show_info
}

show_info() {
    if [[ ! -f "$META_FILE" ]]; then
        echo -e "\e[31m[!] Панель еще не установлена.\e[0m"
        return
    fi

    # shellcheck source=/dev/null
    source "$META_FILE"

    IP=$(curl -s -4 ifconfig.me || curl -s -4 api.ipify.org)

    echo -e "\n\e[36m================ OOMKilled Portal (v${SCRIPT_VERSION}) ================\e[0m"
    echo -e "Веб-панель:   \e[36mhttp://${IP}:${WEB_PORT}\e[0m"
    echo -e "Логин:        \e[33m$WEB_USER\e[0m"
    echo -e "Пароль:       \e[33m$WEB_PASS\e[0m"
    echo -e "======================================================\n"

    echo -e "\e[1;34m--- СПИСОК КЛИЕНТСКИХ ССЫЛОК ---\e[0m\n"

    "$INSTALL_DIR/venv/bin/python3" -c "
import json
try:
    with open('$USER_DATA_FILE') as f:
        data = json.load(f)
    for name, info in data.items():
        sub = info.get('sub_token', '')
        sub_url = f'http://$IP:$WEB_PORT/sub/{sub}'
        p_url = info.get('proxy_url', 'не задан')
        print(f'USER_BLOCK::{name}::{sub_url}::{p_url}')
except Exception:
    pass
" | while IFS= read -r line; do
        if [[ "$line" =~ ^USER_BLOCK::(.*)::(.*)::(.*) ]]; then
            u_name="${BASH_REMATCH[1]}"
            u_sub="${BASH_REMATCH[2]}"
            u_prx="${BASH_REMATCH[3]}"

            echo -e "👤 \e[1mПользователь:\e[0m \e[32m$u_name\e[0m"
            echo -e "Ссылка клиента: \e[35m$u_sub\e[0m"
            echo -e "Прокси TG:      \e[90m$u_prx\e[0m"
            echo -e "------------------------------------------------------\n"
        fi
    done
}

fix_and_restart() {
    echo -e "\n\e[33m[Fixer] Перезапуск веб-портала...\e[0m"

    if [[ -f "$META_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$META_FILE"
        fuser -k "${WEB_PORT}/tcp" 2>/dev/null || true
    fi

    chmod -R 755 "$INSTALL_DIR" 2>/dev/null || true
    systemctl daemon-reload
    systemctl restart mtproto-web.service mtproto-guardian.service
    sleep 2

    if systemctl is-active --quiet mtproto-web.service; then
        echo -e "\e[32m✔ Веб-портал работает в штатном режиме!\e[0m"
    else
        echo -e "\e[31m✖ Ошибка запуска веб-портала:\e[0m"
        journalctl -u mtproto-web.service -u mtproto-guardian.service -n 15 --no-pager
    fi
}

self_update() {
    echo -e "\n\e[34m[Update] Проверка обновлений на GitHub...\e[0m"
    echo -e "Текущая версия скрипта: \e[33mv${SCRIPT_VERSION}\e[0m"

    local target_script="/usr/local/bin/oom"
    local current_script
    current_script=$(readlink -f "$0")

    local tmp_file
    tmp_file=$(mktemp)

    local nocache_url="${GITHUB_REPO_URL}?nocache=$(date +%s)"
    if ! curl -fsSL -H "Cache-Control: no-cache, no-store, must-revalidate" -H "Pragma: no-cache" "$nocache_url" -o "$tmp_file"; then
        echo -e "\e[31m✖ Ошибка: Не удалось скачать файл с GitHub.\e[0m"
        rm -f "$tmp_file"
        return 1
    fi

    sed -i 's/\r$//' "$tmp_file" 2>/dev/null || true

    if [[ ! -s "$tmp_file" ]] || ! bash -n "$tmp_file"; then
        echo -e "\e[31m✖ Ошибка: Файл с GitHub пуст или поврежден.\e[0m"
        rm -f "$tmp_file"
        return 1
    fi

    local remote_version
    remote_version=$(grep -m1 '^SCRIPT_VERSION=' "$tmp_file" | cut -d'"' -f2 || echo "неизвестно")
    echo -e "Версия на GitHub:      \e[36mv${remote_version}\e[0m"

    if [[ "$SCRIPT_VERSION" == "$remote_version" ]] && cmp -s "$target_script" "$tmp_file" 2>/dev/null; then
        echo -e "\e[32m✔ У вас уже установлена актуальная версия (v${SCRIPT_VERSION}).\e[0m"
        rm -f "$tmp_file"
        return 0
    fi

    echo -e "\e[33mОбновление компонентов: v${SCRIPT_VERSION} -> v${remote_version}...\e[0m"

    chmod +x "$tmp_file"
    cp -f "$tmp_file" "$target_script"
    if [[ "$current_script" != "$target_script" && -f "$current_script" ]]; then
        cp -f "$tmp_file" "$current_script" 2>/dev/null || true
    fi
    rm -f "$tmp_file"

    if [[ -d "$INSTALL_DIR" ]]; then
        echo "Синхронизация модулей..."
        bash "$target_script" --upgrade-modules || true
    fi

    echo -e "\e[32m✔ Скрипт успешно обновлен до v${remote_version}!\e[0m"
    sleep 1
    exec "$target_script"
}

uninstall_all() {
    read -rp "Удалить портал и все настройки? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        systemctl stop mtproto-web.service mtproto-guardian.service 2>/dev/null || true
        systemctl disable mtproto-web.service mtproto-guardian.service 2>/dev/null || true
        rm -f "$WEB_SERVICE" "$GUARDIAN_SERVICE" "$META_FILE"
        rm -rf "$INSTALL_DIR" "$BACKUP_DIR"
        systemctl daemon-reload
        echo -e "\e[32m✔ Все компоненты полностью удалены с сервера.\e[0m"
    else
        echo "Отмена."
    fi
}

# --- Главное меню ---
check_root

while true; do
    echo -e "\e[1m========================================\e[0m"
    echo -e "\e[1;35m    OOMKilled Portal Manager v${SCRIPT_VERSION}  \e[0m"
    echo -e "\e[1m========================================\e[0m"
    echo "1) Полная установка Портала"
    echo "2) Показать ссылки клиентов"
    echo "3) Перезапустить службу / Fixer"
    echo "4) Посмотреть логи панели"
    echo "5) Обновить скрипт с GitHub"
    echo "6) Резервное копирование и восстановление"
    echo "7) Полностью удалить портал"
    echo "0) Выход"
    read -rp "Выберите действие [0-7]: " OPTION

    case "$OPTION" in
        1) install_all ;;
        2) show_info ;;
        3) fix_and_restart ;;
        4) journalctl -u mtproto-web.service -f ;;
        5) self_update ;;
        6)
            echo -e "\n1) Создать резервную копию\n2) Восстановить из резервной копии"
            read -rp "Ваш выбор [1-2]: " B_OPT
            [[ "$B_OPT" == "1" ]] && create_backup
            [[ "$B_OPT" == "2" ]] && restore_backup
            ;;
        7) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "\e[31mНеверный выбор.\e[0m\n" ;;
    esac
done