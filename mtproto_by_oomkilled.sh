#!/usr/bin/env bash
# ==============================================================================
# Script Name : MTPROTO_By_OOMKilled
# Description : Standalone Subscription & Config Portal By OOMKilled
# Author      : OOMKilled
# Version     : 2.7
# ==============================================================================

set -euo pipefail

SCRIPT_VERSION="2.7"
INSTALL_DIR="/opt/mtproto_by_oomkilled"
WEB_SERVICE="/etc/systemd/system/mtproto-web.service"
GUARDIAN_SERVICE="/etc/systemd/system/mtproto-guardian.service"
USER_DATA_FILE="$INSTALL_DIR/users_meta.json"
BRANDING_FILE="$INSTALL_DIR/branding.json"
VPN_STORAGE_DIR="$INSTALL_DIR/vpn_configs"
META_FILE="/etc/mtproto_oomkilled.conf"
BACKUP_DIR="/var/backups/mtproto_oomkilled"
SELF_SSL_CERT="$INSTALL_DIR/cert.pem"
SELF_SSL_KEY="$INSTALL_DIR/key.pem"
GITHUB_REPO_URL="https://raw.githubusercontent.com/igorgorshkov034-rgb/MTPROTO-By-OOMKilled/refs/heads/main/mtproto_by_oomkilled.sh"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "\e[31m[ERROR] Скрипт должен запускаться с правами root (sudo)!\e[0m"
        exit 1
    fi
}

generate_self_signed_ssl() {
    echo "Генерация самоподписанного SSL-сертификата..."
    mkdir -p "$INSTALL_DIR"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$SELF_SSL_KEY" \
        -out "$SELF_SSL_CERT" \
        -subj "/CN=OOMKilled-Portal/O=OOMKilled/C=NL" >/dev/null 2>&1
    chmod 600 "$SELF_SSL_KEY"
    chmod 644 "$SELF_SSL_CERT"
}

obtain_letsencrypt_ssl() {
    echo -e "\n\e[34m=== Получение официального сертификата Let's Encrypt ===\e[0m"
    echo -e "\e[33mВнимание: Домен должен указывать на IP этого сервера (A-запись)!\e[0m"
    echo -e "\e[33mПорт 80 должен быть свободен на время проверки ACME.\e[0m"
    read -rp "Введите ваше доменное имя (например, sub.domain.com): " DOMAIN_NAME
    DOMAIN_NAME=$(echo "$DOMAIN_NAME" | tr -d ' ' | tr '[:upper:]' '[:lower:]')

    if [[ -z "$DOMAIN_NAME" ]]; then
        echo -e "\e[31mОшибка: Имя домена не может быть пустым.\e[0m"
        return 1
    fi

    echo "Установка certbot..."
    apt-get update -qq
    apt-get install -y -qq certbot >/dev/null

    if fuser 80/tcp &>/dev/null; then
        echo "Временная остановка служб на 80 порту..."
        fuser -k 80/tcp 2>/dev/null || true
    fi

    echo "Запрос сертификата в Let's Encrypt..."
    if certbot certonly --standalone --agree-tos --register-unsafely-without-email -d "$DOMAIN_NAME" --non-interactive; then
        echo -e "\e[32m✔ Сертификат для $DOMAIN_NAME успешно получен!\e[0m"

        sed -i '/^USE_SSL=/d' "$META_FILE" 2>/dev/null || true
        sed -i '/^SSL_TYPE=/d' "$META_FILE" 2>/dev/null || true
        sed -i '/^DOMAIN_NAME=/d' "$META_FILE" 2>/dev/null || true

        echo "USE_SSL=true" >> "$META_FILE"
        echo "SSL_TYPE=letsencrypt" >> "$META_FILE"
        echo "DOMAIN_NAME=$DOMAIN_NAME" >> "$META_FILE"

        mkdir -p /etc/letsencrypt/renewal-hooks/deploy/
        cat <<'EOF' > /etc/letsencrypt/renewal-hooks/deploy/restart-oom-portal.sh
#!/bin/bash
systemctl restart mtproto-web.service
EOF
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-oom-portal.sh

        update_systemd_service
        systemctl restart mtproto-web.service
        show_info
    else
        echo -e "\e[31m✖ Ошибка выпуска сертификата. Проверьте A-запись домена и отсутствие блокировки 80 порта.\e[0m"
        return 1
    fi
}

update_systemd_service() {
    local use_ssl="false"
    local ssl_type="self"
    local domain_name=""
    local web_port="8080"

    if [[ -f "$META_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$META_FILE"
        use_ssl="${USE_SSL:-false}"
        ssl_type="${SSL_TYPE:-self}"
        domain_name="${DOMAIN_NAME:-}"
        web_port="${WEB_PORT:-8080}"
    fi

    local ssl_flags=""
    if [[ "$use_ssl" == "true" ]]; then
        if [[ "$ssl_type" == "letsencrypt" && -n "$domain_name" && -f "/etc/letsencrypt/live/${domain_name}/fullchain.pem" ]]; then
            ssl_flags="--ssl-keyfile /etc/letsencrypt/live/${domain_name}/privkey.pem --ssl-certfile /etc/letsencrypt/live/${domain_name}/fullchain.pem"
        elif [[ -f "$SELF_SSL_CERT" && -f "$SELF_SSL_KEY" ]]; then
            ssl_flags="--ssl-keyfile $SELF_SSL_KEY --ssl-certfile $SELF_SSL_CERT"
        fi
    fi

    cat <<EOF > "$WEB_SERVICE"
[Unit]
Description=OOMKilled Web Portal
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/uvicorn web_panel:app --host 0.0.0.0 --port $web_port $ssl_flags
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
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
  "guide_desktop": "1. Скопируйте ключ или скачайте файл конфигурации.\n2. Импортируйте его в настольный клиент.",
  "app_ios": "",
  "app_android": "",
  "app_windows": "",
  "app_macos": "",
  "app_linux": ""
}
EOF
    fi

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

    cat <<'EOF' > "$INSTALL_DIR/web_panel.py"
import os, re, secrets, psutil, json, time, io, tarfile, shutil, zipfile, subprocess
from fastapi import FastAPI, Depends, HTTPException, status, Form, UploadFile, File
from fastapi.responses import HTMLResponse, RedirectResponse, StreamingResponse, FileResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials

app = FastAPI(title="OOMKilled Portal v2.7")
security = HTTPBasic()

DATA_PATH = "/opt/mtproto_by_oomkilled/users_meta.json"
BRANDING_PATH = "/opt/mtproto_by_oomkilled/branding.json"
VPN_DIR = "/opt/mtproto_by_oomkilled/vpn_configs"
META_PATH = "/etc/mtproto_oomkilled.conf"

FAVICON_DATA_URI = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Cdefs%3E%3ClinearGradient id='g' x1='0%25' y1='0%25' x2='100%25' y2='100%25'%3E%3Cstop offset='0%25' stop-color='%2338bdf8'/%3E%3Cstop offset='100%25' stop-color='%23a855f7'/%3E%3C/linearGradient%3E%3C/defs%3E%3Cpath d='M32 4L10 14v18c0 14.5 9.4 24.3 22 28 12.6-3.7 22-13.5 22-28V14L32 4z' fill='%230f172a' stroke='url(%23g)' stroke-width='4' stroke-linejoin='round'/%3E%3Cpath d='M34 16L22 34h9l-3 14 14-20h-9l4-12z' fill='url(%23g)'/%3E%3C/svg%3E"

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

def save_meta(meta_dict):
    lines = []
    if os.path.exists(META_PATH):
        with open(META_PATH) as f:
            for line in f:
                if "=" in line:
                    k = line.strip().split("=", 1)[0]
                    if k in meta_dict:
                        lines.append(f"{k}={meta_dict[k]}\n")
                        del meta_dict[k]
                    else:
                        lines.append(line)
    for k, v in meta_dict.items():
        lines.append(f"{k}={v}\n")
    with open(META_PATH, "w") as f:
        f.writelines(lines)

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
        "guide_desktop": "1. Скопируйте ключ или скачайте файл конфигурации.",
        "app_ios": "",
        "app_android": "",
        "app_windows": "",
        "app_macos": "",
        "app_linux": ""
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

def get_file_badge(filename: str):
    lower = filename.lower()
    if lower.endswith(".conf") or "wireguard" in lower:
        return ('<span style="background:rgba(56,189,248,0.15); color:#38bdf8; border:1px solid rgba(56,189,248,0.3); '
                'padding:3px 8px; border-radius:6px; font-size:11px; font-weight:700; margin-right:8px;">WG</span>')
    elif lower.endswith(".ovpn"):
        return ('<span style="background:rgba(249,115,22,0.15); color:#fb923c; border:1px solid rgba(249,115,22,0.3); '
                'padding:3px 8px; border-radius:6px; font-size:11px; font-weight:700; margin-right:8px;">OVPN</span>')
    elif lower.endswith(".json"):
        return ('<span style="background:rgba(168,85,247,0.15); color:#c084fc; border:1px solid rgba(168,85,247,0.3); '
                'padding:3px 8px; border-radius:6px; font-size:11px; font-weight:700; margin-right:8px;">JSON</span>')
    elif lower.endswith(".zip") or lower.endswith(".tar.gz") or lower.endswith(".rar"):
        return ('<span style="background:rgba(245,158,11,0.15); color:#fbbf24; border:1px solid rgba(245,158,11,0.3); '
                'padding:3px 8px; border-radius:6px; font-size:11px; font-weight:700; margin-right:8px;">ZIP</span>')
    else:
        return ('<span style="background:rgba(148,163,184,0.15); color:#cbd5e1; border:1px solid rgba(148,163,184,0.3); '
                'padding:3px 8px; border-radius:6px; font-size:11px; font-weight:700; margin-right:8px;">FILE</span>')

@app.get("/logout")
def logout():
    return HTMLResponse(
        content="""<!DOCTYPE html>
<html lang="ru"><head><meta charset="UTF-8"><title>Выход</title></head>
<body style="background:#090d16; color:#f8fafc; font-family:system-ui, sans-serif; text-align:center; padding-top:80px;">
    <h2 style="font-weight:700;">Вы вышли из сессии</h2>
    <p><a href="/" style="color:#38bdf8; text-decoration:none; font-weight:600; padding:8px 16px; background:rgba(56,189,248,0.1); border-radius:8px; border:1px solid rgba(56,189,248,0.25);">Войти снова</a></p>
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

@app.post("/restore-backup")
async def restore_backup_web(backup_file: UploadFile = File(...), user: str = Depends(auth_user)):
    if not backup_file.filename:
        raise HTTPException(status_code=400, detail="Файл не выбран")

    content = await backup_file.read()
    temp_archive = f"/tmp/restore_{int(time.time())}.tar.gz"
    with open(temp_archive, "wb") as f:
        f.write(content)

    try:
        with tarfile.open(temp_archive, "r:gz") as tar:
            members = tar.getnames()
            valid_names = {"users_meta.json", "mtproto_oomkilled.conf", "branding.json", "vpn_configs"}
            has_valid = any(any(m.startswith(v) for v in valid_names) for m in members)
            if not has_valid:
                raise Exception("Некорректная структура архива бэкапа")

            for member in tar.getmembers():
                clean_name = os.path.normpath(member.name).lstrip("/")
                if clean_name == "mtproto_oomkilled.conf":
                    tar.extract(member, path="/etc")
                elif clean_name in ["users_meta.json", "branding.json"] or clean_name.startswith("vpn_configs"):
                    tar.extract(member, path="/opt/mtproto_by_oomkilled")
    except Exception as e:
        if os.path.exists(temp_archive):
            os.remove(temp_archive)
        raise HTTPException(status_code=400, detail=f"Ошибка распаковки: {str(e)}")

    if os.path.exists(temp_archive):
        os.remove(temp_archive)

    subprocess.Popen(
        "sleep 1 && systemctl restart mtproto-web.service mtproto-guardian.service",
        shell=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )

    return HTMLResponse(
        content="""<!DOCTYPE html>
<html lang="ru"><head><meta charset="UTF-8"><title>Восстановление</title>
<meta http-equiv="refresh" content="3;url=/">
<style>
body { background:#090d16; color:#f8fafc; font-family:system-ui, -apple-system, sans-serif; text-align:center; padding-top:90px; }
.spinner { width: 44px; height: 44px; border: 3px solid rgba(255,255,255,0.08); border-top: 3px solid #38bdf8; border-radius: 50%; margin: 24px auto; animation: spin 0.8s linear infinite; }
@keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
</style>
</head>
<body>
    <h2 style="color:#10b981; font-weight:700;">Резервная копия успешно восстановлена</h2>
    <div class="spinner"></div>
    <p style="color:#94a3b8; font-size:14px;">Перезапуск сервисов... Перенаправление в панель управления через 3 секунды</p>
</body></html>"""
    )

@app.post("/update-admin-credentials")
def update_admin_credentials(
    username: str = Form(...),
    password: str = Form(...),
    user: str = Depends(auth_user)
):
    username = username.strip()
    password = password.strip()

    if not username or not password:
        raise HTTPException(status_code=400, detail="Логин и пароль не могут быть пустыми")

    save_meta({"WEB_USER": username, "WEB_PASS": password})

    return HTMLResponse(
        content="""<!DOCTYPE html>
<html lang="ru"><head><meta charset="UTF-8"><title>Пароль обновлен</title></head>
<body style="background:#090d16; color:#f8fafc; font-family:system-ui, sans-serif; text-align:center; padding-top:80px;">
    <h2 style="color:#10b981;">Данные администратора обновлены!</h2>
    <p style="color:#94a3b8;">Пожалуйста, войдите снова, используя новые учетные данные.</p>
    <p style="margin-top:24px;"><a href="/" style="color:#38bdf8; text-decoration:none; font-weight:600; padding:10px 20px; background:rgba(56,189,248,0.1); border-radius:8px; border:1px solid rgba(56,189,248,0.25);">Войти с новым паролем</a></p>
</body></html>""",
        status_code=200
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
    created = target_user.get("created_at", now)
    exp = target_user.get("expires_at", 0)
    u_status = target_user.get("status", "active")
    proxy_url = target_user.get("proxy_url", "").strip()
    custom_key = target_user.get("custom_key", "").strip()

    progress_percent = 100
    progress_color = "linear-gradient(90deg, #38bdf8, #818cf8)"

    if u_status == "paused":
        status_text = "Приостановлена"
        status_badge_class = "badge-paused"
        days_str = "На паузе"
        progress_percent = 0
    elif exp > 0 and now > exp:
        status_text = "Срок истёк"
        status_badge_class = "badge-expired"
        days_str = "Истекла"
        progress_percent = 100
        progress_color = "linear-gradient(90deg, #ef4444, #f43f5e)"
    elif exp == 0:
        status_text = "Активна"
        status_badge_class = "badge-active"
        days_str = "Бессрочно"
        progress_percent = 100
        progress_color = "linear-gradient(90deg, #10b981, #06b6d4)"
    else:
        status_text = "Активна"
        status_badge_class = "badge-active"
        total_duration = max(1, exp - created)
        remaining = max(0, exp - now)
        progress_percent = min(100, max(5, int((remaining / total_duration) * 100)))
        days_left = max(1, int(remaining / 86400))
        days_str = f"Осталось {days_left} дн."
        if progress_percent < 25:
            progress_color = "linear-gradient(90deg, #f59e0b, #ef4444)"
        elif progress_percent < 50:
            progress_color = "linear-gradient(90deg, #38bdf8, #f59e0b)"

    proxy_block = ""
    if proxy_url:
        proxy_block = f"""
        <div style="margin-top: 14px;">
            <a href="{proxy_url}" class="glass-btn glass-btn-primary">
                <span>Подключить в Telegram</span>
            </a>
            <div class="glass-code-block">{proxy_url}</div>
        </div>
        """

    key_block = ""
    if custom_key:
        key_block = f"""
        <div class="glass-subcard" style="margin-top: 14px;">
            <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:8px;">
                <span style="font-weight:600; font-size:12px; color:#94a3b8; text-transform:uppercase; letter-spacing:0.5px;">Ключ доступа</span>
                <button type="button" class="btn-copy-tag" onclick="copyKey()">Скопировать</button>
            </div>
            <textarea id="key-text" class="glass-textarea" readonly>{custom_key}</textarea>
        </div>
        """

    vpn_files = list_user_vpn_files(target_name)
    vpn_files_html = ""
    if vpn_files:
        zip_btn_html = ""
        if len(vpn_files) > 1:
            zip_btn_html = f"""
            <a href="/sub/{token}/download-all-zip" class="btn-zip-download" download>Архив (.ZIP)</a>
            """

        vpn_files_html += f"""
        <div class='glass-subcard' style="margin-top: 16px;">
            <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:10px;">
                <span style='font-size:13px; font-weight:600; color:#e2e8f0; text-transform:uppercase; letter-spacing:0.5px;'>Файлы конфигураций</span>
                {zip_btn_html}
            </div>
        """
        for f_name in vpn_files:
            dl_url = f"/sub/{token}/download/{f_name}"
            badge_icon = get_file_badge(f_name)
            vpn_files_html += f"""
            <div class='vpn-item-row'>
                <div style="display:flex; align-items:center; overflow:hidden; text-overflow:ellipsis;">
                    {badge_icon}
                    <span style='font-family:ui-monospace, monospace; font-size:13px; color:#f1f5f9; white-space:nowrap;'>{f_name}</span>
                </div>
                <a href='{dl_url}' class='btn-file-dl' download>Скачать</a>
            </div>
            """
        vpn_files_html += "</div>"

    ios_text = branding.get("guide_ios", "").replace("\n", "<br>")
    android_text = branding.get("guide_android", "").replace("\n", "<br>")
    desktop_text = branding.get("guide_desktop", "").replace("\n", "<br>")
    support_url = branding.get("support_link", "")

    app_ios = branding.get("app_ios", "").strip()
    app_android = branding.get("app_android", "").strip()
    app_windows = branding.get("app_windows", "").strip()
    app_macos = branding.get("app_macos", "").strip()
    app_linux = branding.get("app_linux", "").strip()

    btn_app_ios = f'<a href="{app_ios}" target="_blank" class="glass-app-link">Скачать для iOS</a>' if app_ios else ""
    btn_app_android = f'<a href="{app_android}" target="_blank" class="glass-app-link">Скачать для Android</a>' if app_android else ""
    
    desktop_btns = []
    if app_windows:
        desktop_btns.append(f'<a href="{app_windows}" target="_blank" class="glass-app-link" style="margin-top:8px;">Скачать для Windows</a>')
    if app_macos:
        desktop_btns.append(f'<a href="{app_macos}" target="_blank" class="glass-app-link" style="margin-top:8px;">Скачать для macOS</a>')
    if app_linux:
        desktop_btns.append(f'<a href="{app_linux}" target="_blank" class="glass-app-link" style="margin-top:8px;">Скачать для Linux</a>')
    btns_app_desktop = "".join(desktop_btns)

    return f"""<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{branding.get('service_name', 'Portal')} | {target_name}</title>
    <link rel="icon" type="image/svg+xml" href="{FAVICON_DATA_URI}">
    <style>
        * {{ box-sizing: border-box; }}
        body {{
            font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background: #080c14;
            color: #f8fafc;
            margin: 0;
            padding: 24px 16px;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            position: relative;
            overflow-x: hidden;
        }}

        .ambient-orb-1 {{
            position: fixed;
            width: 380px;
            height: 380px;
            background: radial-gradient(circle, rgba(56, 189, 248, 0.22) 0%, rgba(0,0,0,0) 70%);
            top: -60px;
            left: -60px;
            z-index: 0;
            filter: blur(50px);
            pointer-events: none;
            animation: orbFloat 14s ease-in-out infinite alternate;
        }}
        .ambient-orb-2 {{
            position: fixed;
            width: 420px;
            height: 420px;
            background: radial-gradient(circle, rgba(168, 85, 247, 0.18) 0%, rgba(0,0,0,0) 70%);
            bottom: -60px;
            right: -60px;
            z-index: 0;
            filter: blur(60px);
            pointer-events: none;
            animation: orbFloat 18s ease-in-out infinite alternate-reverse;
        }}

        @keyframes orbFloat {{
            0% {{ transform: translate(0, 0); }}
            100% {{ transform: translate(40px, 40px); }}
        }}

        .glass-card {{
            position: relative;
            z-index: 1;
            max-width: 460px;
            width: 100%;
            background: rgba(15, 23, 42, 0.65);
            backdrop-filter: blur(28px);
            -webkit-backdrop-filter: blur(28px);
            border-radius: 24px;
            padding: 28px 24px;
            border: 1px solid rgba(255, 255, 255, 0.1);
            box-shadow: 0 30px 60px -12px rgba(0, 0, 0, 0.7), inset 0 1px 0 rgba(255, 255, 255, 0.12);
        }}

        h2 {{
            color: #f8fafc;
            margin: 0 0 14px 0;
            text-align: center;
            font-size: 22px;
            font-weight: 700;
            letter-spacing: -0.4px;
        }}

        .user-pill {{
            display: inline-flex;
            align-items: center;
            gap: 10px;
            background: rgba(255, 255, 255, 0.04);
            padding: 5px 14px;
            border-radius: 40px;
            font-size: 13px;
            border: 1px solid rgba(255, 255, 255, 0.08);
        }}

        .status-badge {{
            padding: 3px 9px;
            border-radius: 20px;
            font-size: 11px;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.4px;
        }}
        .badge-active {{ background: rgba(16, 185, 129, 0.15); color: #34d399; border: 1px solid rgba(16, 185, 129, 0.3); }}
        .badge-paused {{ background: rgba(245, 158, 11, 0.15); color: #fbbf24; border: 1px solid rgba(245, 158, 11, 0.3); }}
        .badge-expired {{ background: rgba(239, 68, 68, 0.15); color: #f87171; border: 1px solid rgba(239, 68, 68, 0.3); }}

        .progress-box {{
            margin: 18px 0 20px 0;
            background: rgba(255, 255, 255, 0.03);
            border: 1px solid rgba(255, 255, 255, 0.06);
            border-radius: 16px;
            padding: 12px 16px;
        }}
        .progress-meta {{
            display: flex;
            justify-content: space-between;
            font-size: 12px;
            color: #94a3b8;
            margin-bottom: 8px;
        }}
        .progress-track {{
            width: 100%;
            height: 7px;
            background: rgba(255, 255, 255, 0.06);
            border-radius: 10px;
            overflow: hidden;
        }}
        .progress-fill {{
            height: 100%;
            border-radius: 10px;
            transition: width 0.6s cubic-bezier(0.4, 0, 0.2, 1);
        }}

        .glass-btn {{
            display: flex;
            align-items: center;
            justify-content: center;
            width: 100%;
            padding: 12px 18px;
            border-radius: 14px;
            text-decoration: none;
            font-weight: 600;
            font-size: 14px;
            transition: all 0.2s ease;
            cursor: pointer;
            border: none;
        }}
        .glass-btn-primary {{
            background: linear-gradient(135deg, #0ea5e9, #3b82f6);
            color: #fff;
            box-shadow: 0 4px 16px rgba(14, 165, 233, 0.35);
        }}
        .glass-btn-primary:hover {{
            box-shadow: 0 6px 22px rgba(14, 165, 233, 0.5);
            transform: translateY(-1px);
        }}
        .glass-btn-support {{
            margin-top: 14px;
            background: rgba(255, 255, 255, 0.04);
            color: #94a3b8;
            border: 1px solid rgba(255, 255, 255, 0.08);
            font-size: 13px;
        }}
        .glass-btn-support:hover {{
            background: rgba(255, 255, 255, 0.08);
            color: #f8fafc;
            border-color: rgba(255, 255, 255, 0.15);
        }}

        .glass-app-link {{
            display: flex;
            align-items: center;
            justify-content: center;
            width: 100%;
            background: rgba(56, 189, 248, 0.08);
            color: #38bdf8;
            border: 1px solid rgba(56, 189, 248, 0.2);
            border-radius: 12px;
            padding: 10px 14px;
            font-size: 13px;
            font-weight: 600;
            text-decoration: none;
            margin-top: 10px;
            transition: all 0.2s ease;
        }}
        .glass-app-link:hover {{
            background: rgba(56, 189, 248, 0.16);
            border-color: rgba(56, 189, 248, 0.35);
        }}

        .glass-code-block {{
            background: rgba(0, 0, 0, 0.35);
            padding: 8px 12px;
            border-radius: 10px;
            font-family: ui-monospace, monospace;
            font-size: 11px;
            color: #94a3b8;
            margin-top: 8px;
            word-break: break-all;
            border: 1px solid rgba(255, 255, 255, 0.05);
        }}

        .glass-subcard {{
            background: rgba(0, 0, 0, 0.25);
            border: 1px solid rgba(255, 255, 255, 0.06);
            border-radius: 16px;
            padding: 14px;
        }}
        .glass-textarea {{
            width: 100%;
            height: 56px;
            background: rgba(0, 0, 0, 0.4);
            border: 1px solid rgba(255, 255, 255, 0.08);
            border-radius: 10px;
            color: #38bdf8;
            font-family: ui-monospace, monospace;
            font-size: 12px;
            padding: 8px 10px;
            resize: none;
            outline: none;
        }}
        .btn-copy-tag {{
            background: rgba(56, 189, 248, 0.12);
            color: #38bdf8;
            border: 1px solid rgba(56, 189, 248, 0.25);
            border-radius: 8px;
            padding: 3px 10px;
            font-size: 11px;
            font-weight: 600;
            cursor: pointer;
            transition: 0.2s;
        }}
        .btn-copy-tag:hover {{ background: rgba(56, 189, 248, 0.24); }}

        .vpn-item-row {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 8px 0;
            border-bottom: 1px solid rgba(255, 255, 255, 0.04);
        }}
        .vpn-item-row:last-child {{ border-bottom: none; }}
        .btn-file-dl {{
            background: rgba(99, 102, 241, 0.15);
            color: #818cf8;
            border: 1px solid rgba(99, 102, 241, 0.25);
            text-decoration: none;
            padding: 4px 10px;
            border-radius: 8px;
            font-size: 11px;
            font-weight: 600;
            transition: 0.2s;
        }}
        .btn-file-dl:hover {{ background: rgba(99, 102, 241, 0.3); }}
        .btn-zip-download {{
            background: rgba(56, 189, 248, 0.12);
            color: #38bdf8;
            border: 1px solid rgba(56, 189, 248, 0.25);
            text-decoration: none;
            padding: 3px 9px;
            border-radius: 8px;
            font-size: 11px;
            font-weight: 600;
        }}

        .segmented-tabs {{
            display: flex;
            background: rgba(0, 0, 0, 0.3);
            border: 1px solid rgba(255, 255, 255, 0.06);
            border-radius: 12px;
            padding: 3px;
            margin-top: 22px;
        }}
        .tab-btn {{
            flex: 1;
            background: none;
            border: none;
            color: #64748b;
            font-weight: 600;
            cursor: pointer;
            padding: 8px 0;
            border-radius: 9px;
            font-size: 13px;
            transition: all 0.2s ease;
        }}
        .tab-btn.active {{
            background: rgba(255, 255, 255, 0.08);
            color: #f8fafc;
            box-shadow: 0 2px 8px rgba(0, 0, 0, 0.3);
        }}
        .tab-content {{
            display: none;
            padding: 14px 2px 0 2px;
            font-size: 13px;
            line-height: 1.6;
            color: #94a3b8;
        }}
        .tab-content.active {{ display: block; }}

        .toast {{
            position: fixed;
            bottom: 24px;
            left: 50%;
            transform: translateX(-50%) translateY(80px);
            background: rgba(15, 23, 42, 0.95);
            border: 1px solid rgba(56, 189, 248, 0.3);
            backdrop-filter: blur(12px);
            color: #f8fafc;
            padding: 10px 20px;
            border-radius: 30px;
            font-size: 13px;
            font-weight: 600;
            box-shadow: 0 16px 32px rgba(0, 0, 0, 0.6);
            opacity: 0;
            transition: all 0.25s cubic-bezier(0.4, 0, 0.2, 1);
            z-index: 1000;
            pointer-events: none;
        }}
        .toast.show {{
            transform: translateX(-50%) translateY(0);
            opacity: 1;
        }}
    </style>
</head>
<body>
    <div class="ambient-orb-1"></div>
    <div class="ambient-orb-2"></div>

    <div class="glass-card">
        <h2>{branding.get('service_name', 'Portal')}</h2>
        
        <div style="text-align: center; margin-bottom: 14px;">
            <div class="user-pill">
                <span>{target_name}</span>
                <span class="status-badge {status_badge_class}">{status_text}</span>
            </div>
        </div>

        <div class="progress-box">
            <div class="progress-meta">
                <span>Период действия</span>
                <span style="color:#f8fafc; font-weight:600;">{days_str}</span>
            </div>
            <div class="progress-track">
                <div class="progress-fill" style="width: {progress_percent}%; background: {progress_color};"></div>
            </div>
        </div>

        {proxy_block}
        {key_block}
        {vpn_files_html}

        {f'<a href="{support_url}" target="_blank" class="glass-btn glass-btn-support">Техническая поддержка</a>' if support_url else ''}

        <div class="segmented-tabs">
            <button class="tab-btn active" onclick="showTab('ios', this)">iOS</button>
            <button class="tab-btn" onclick="showTab('android', this)">Android</button>
            <button class="tab-btn" onclick="showTab('desktop', this)">ПК</button>
        </div>
        <div id="tab-ios" class="tab-content active">
            <div>{ios_text}</div>
            {btn_app_ios}
        </div>
        <div id="tab-android" class="tab-content">
            <div>{android_text}</div>
            {btn_app_android}
        </div>
        <div id="tab-desktop" class="tab-content">
            <div>{desktop_text}</div>
            {btns_app_desktop}
        </div>
    </div>

    <div id="toast" class="toast">
        <span style="color:#10b981; margin-right:6px;">✓</span> Скопировано в буфер обмена
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
                    showToast();
                }});
            }}
        }}

        function showToast() {{
            const toast = document.getElementById('toast');
            toast.classList.add('show');
            setTimeout(() => {{
                toast.classList.remove('show');
            }}, 2200);
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
    use_ssl = (meta.get("USE_SSL", "false") == "true")
    ssl_type = meta.get("SSL_TYPE", "self")
    domain_name = meta.get("DOMAIN_NAME", "").strip()

    protocol = "https" if use_ssl else "http"
    host_address = domain_name if (use_ssl and ssl_type == "letsencrypt" and domain_name) else ip

    cpu_usage = psutil.cpu_percent(interval=0.1)
    ram_usage = psutil.virtual_memory().percent

    users = get_users_meta()
    now = int(time.time())

    user_cards = ""
    for u_name, u_info in users.items():
        proxy_url = u_info.get("proxy_url", "")
        custom_key = u_info.get("custom_key", "")
        sub_token = u_info.get("sub_token", "")
        sub_url = f"{protocol}://{host_address}:{web_port}/sub/{sub_token}"

        created_at = u_info.get("created_at", now)
        exp = u_info.get("expires_at", 0)
        u_status = u_info.get("status", "active")

        status_type = "active"
        if u_status == "paused":
            status_type = "paused"
            exp_str = "<span style='color:#f59e0b;'>Пауза</span>"
            badge_dot = "#f59e0b"
            pause_btn_text = "Возобновить"
            pause_btn_style = "background:rgba(16,185,129,0.15); color:#34d399; border:1px solid rgba(16,185,129,0.3);"
            days_sort_val = -1
        elif exp > 0 and now > exp:
            status_type = "expired"
            exp_str = "<span style='color:#ef4444;'>Истёк</span>"
            badge_dot = "#ef4444"
            pause_btn_text = "Пауза"
            pause_btn_style = "background:rgba(245,158,11,0.15); color:#fbbf24; border:1px solid rgba(245,158,11,0.3);"
            days_sort_val = 0
        elif exp == 0:
            exp_str = "<span style='color:#10b981;'>Бессрочно</span>"
            badge_dot = "#10b981"
            pause_btn_text = "Пауза"
            pause_btn_style = "background:rgba(245,158,11,0.15); color:#fbbf24; border:1px solid rgba(245,158,11,0.3);"
            days_sort_val = 99999
        else:
            days_left = max(1, int((exp - now) / 86400))
            exp_str = f"<span style='color:#38bdf8;'>Осталось {days_left} дн.</span>"
            badge_dot = "#10b981"
            pause_btn_text = "Пауза"
            pause_btn_style = "background:rgba(245,158,11,0.15); color:#fbbf24; border:1px solid rgba(245,158,11,0.3);"
            days_sort_val = days_left

        attached_files = list_user_vpn_files(u_name)
        files_chips = ""
        for af in attached_files:
            chip_badge = get_file_badge(af)
            files_chips += f"""
            <span class="file-chip">
                {chip_badge}
                <span style="font-family:ui-monospace, monospace; font-size:12px;">{af}</span>
                <form action="/delete-vpn-file" method="post" style="margin:0; display:inline;">
                    <input type="hidden" name="username" value="{u_name}">
                    <input type="hidden" name="filename" value="{af}">
                    <button type="submit" class="file-chip-del" title="Удалить">✕</button>
                </form>
            </span>
            """

        user_cards += f"""
        <div class="user-card" data-username="{u_name.lower()}" data-status="{status_type}" data-days="{days_sort_val}" data-created="{created_at}">
            <div class="user-header">
                <div style="display:flex; align-items:center; gap:8px;">
                    <span style="width:8px; height:8px; border-radius:50%; background:{badge_dot}; display:inline-block;"></span>
                    <strong style="font-size:16px; color:#f8fafc;">{u_name}</strong>
                    <span style="font-size:12px; color:#94a3b8; margin-left:4px;">{exp_str}</span>
                </div>
                <div style="display:flex; gap:6px;">
                    <form action="/renew-user" method="post" style="margin:0;">
                        <input type="hidden" name="username" value="{u_name}">
                        <button type="submit" class="btn-micro" style="background:rgba(16,185,129,0.15); color:#34d399; border:1px solid rgba(16,185,129,0.3);">+30 дн</button>
                    </form>
                    <form action="/toggle-pause" method="post" style="margin:0;">
                        <input type="hidden" name="username" value="{u_name}">
                        <button type="submit" class="btn-micro" style="{pause_btn_style}">{pause_btn_text}</button>
                    </form>
                    <form action="/delete-user" method="post" style="margin:0;">
                        <input type="hidden" name="username" value="{u_name}">
                        <button type="submit" class="btn-micro btn-micro-danger">Удалить</button>
                    </form>
                </div>
            </div>

            <div class="sub-link-row">
                <span class="sub-url-text">{sub_url}</span>
                <a href="{sub_url}" target="_blank" class="btn-open-link">Открыть ↗</a>
            </div>

            <form action="/update-proxy-url" method="post" class="input-action-group">
                <input type="hidden" name="username" value="{u_name}">
                <input type="text" name="proxy_url" value="{proxy_url}" placeholder="TG прокси (tg://proxy?server=...)" class="input-embedded">
                <button type="submit" class="btn-embedded">TG Прокси</button>
            </form>

            <form action="/update-key" method="post" class="input-action-group">
                <input type="hidden" name="username" value="{u_name}">
                <input type="text" name="custom_key" value="{custom_key}" placeholder="Ключ подписки (VLESS, SS, Clash...)" class="input-embedded" style="font-family:ui-monospace, monospace;">
                <button type="submit" class="btn-embedded" style="background:#4f46e5;">Ключ</button>
            </form>

            <div class="vpn-attach-zone">
                <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:8px;">
                    <span style="color:#94a3b8; font-size:12px; font-weight:600; text-transform:uppercase;">Файлы клиента</span>
                    <form action="/upload-vpn-file" method="post" enctype="multipart/form-data" style="margin:0;">
                        <input type="hidden" name="username" value="{u_name}">
                        <label class="btn-upload-label">
                            <input type="file" name="file" onchange="this.form.submit()" required>
                            + Прикрепить файл
                        </label>
                    </form>
                </div>
                <div class="chips-container">
                    {files_chips if files_chips else '<span style="color:#475569; font-size:12px;">Нет загруженных файлов</span>'}
                </div>
            </div>
        </div>
        """

    if use_ssl and ssl_type == "letsencrypt":
        ssl_status_badge = f"<span style='color:#10b981;'>Let's Encrypt ({domain_name})</span>"
    elif use_ssl:
        ssl_status_badge = "<span style='color:#38bdf8;'>Самоподписанный HTTPS</span>"
    else:
        ssl_status_badge = "<span style='color:#f59e0b;'>HTTP</span>"

    admin_login = meta.get("WEB_USER", "admin")

    html = f"""<!DOCTYPE html>
    <html lang="ru">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>OOMKilled Portal v2.7</title>
        <link rel="icon" type="image/svg+xml" href="{FAVICON_DATA_URI}">
        <style>
            * {{ box-sizing: border-box; }}
            body {{
                font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                background: #080c14;
                color: #f8fafc;
                margin: 0;
                padding: 24px 20px;
                min-height: 100vh;
            }}
            .container {{ max-width: 1040px; margin: 0 auto; }}

            .header-bar {{
                display: flex;
                justify-content: space-between;
                align-items: center;
                margin-bottom: 24px;
                background: rgba(15, 23, 42, 0.4);
                border: 1px solid rgba(255, 255, 255, 0.06);
                border-radius: 18px;
                padding: 14px 20px;
                backdrop-filter: blur(12px);
            }}
            .actions {{ display: flex; gap: 8px; align-items: center; }}
            .btn-nav {{
                background: rgba(255, 255, 255, 0.05);
                color: #cbd5e1;
                text-decoration: none;
                padding: 8px 14px;
                border-radius: 10px;
                font-size: 13px;
                font-weight: 600;
                border: 1px solid rgba(255, 255, 255, 0.08);
                transition: 0.2s;
                cursor: pointer;
            }}
            .btn-nav:hover {{ background: rgba(255, 255, 255, 0.1); color: #fff; }}
            .btn-nav input[type="file"] {{ display: none; }}
            .btn-logout {{
                background: rgba(239, 68, 68, 0.15);
                color: #f87171;
                border: 1px solid rgba(239, 68, 68, 0.25);
            }}
            .btn-logout:hover {{ background: rgba(239, 68, 68, 0.25); color: #fff; }}

            .main-nav {{
                display: flex;
                gap: 8px;
                margin-bottom: 24px;
                background: rgba(0, 0, 0, 0.3);
                border: 1px solid rgba(255, 255, 255, 0.06);
                border-radius: 12px;
                padding: 4px;
                width: fit-content;
            }}
            .nav-tab {{
                background: transparent;
                border: none;
                color: #64748b;
                font-size: 14px;
                font-weight: 600;
                padding: 8px 18px;
                border-radius: 9px;
                cursor: pointer;
                transition: all 0.2s;
            }}
            .nav-tab.active {{
                color: #f8fafc;
                background: rgba(255, 255, 255, 0.08);
                box-shadow: 0 2px 8px rgba(0, 0, 0, 0.3);
            }}
            .menu-section {{ display: none; }}
            .menu-section.active {{ display: block; }}

            .grid-stats {{
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
                gap: 14px;
                margin-bottom: 24px;
            }}
            .stat-box {{
                background: rgba(15, 23, 42, 0.45);
                border: 1px solid rgba(255, 255, 255, 0.06);
                padding: 16px 20px;
                border-radius: 16px;
                backdrop-filter: blur(10px);
            }}
            .stat-title {{ font-size: 13px; color: #94a3b8; font-weight: 500; }}
            .stat-val {{ font-size: 24px; font-weight: 700; color: #38bdf8; margin-top: 4px; }}

            .panel {{
                background: rgba(15, 23, 42, 0.45);
                border: 1px solid rgba(255, 255, 255, 0.06);
                padding: 22px;
                border-radius: 18px;
                margin-bottom: 24px;
                backdrop-filter: blur(12px);
            }}
            .panel-title {{
                margin: 0 0 16px 0;
                font-size: 16px;
                font-weight: 700;
                color: #f8fafc;
                display: flex;
                align-items: center;
                gap: 8px;
            }}

            .form-grid {{
                display: grid;
                grid-template-columns: 2fr 1fr 2fr auto;
                gap: 10px;
            }}
            input, select, textarea {{
                background: rgba(0, 0, 0, 0.4);
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #fff;
                padding: 10px 14px;
                border-radius: 10px;
                font-size: 13px;
                font-family: inherit;
                outline: none;
                transition: 0.2s;
            }}
            input:focus, select:focus, textarea:focus {{
                border-color: rgba(56, 189, 248, 0.5);
                box-shadow: 0 0 0 1px rgba(56, 189, 248, 0.2);
            }}
            .btn-submit {{
                background: #0ea5e9;
                color: #fff;
                border: none;
                padding: 10px 20px;
                border-radius: 10px;
                font-weight: 600;
                cursor: pointer;
                transition: 0.2s;
            }}
            .btn-submit:hover {{ background: #0284c7; }}

            .controls-bar {{
                display: flex;
                flex-wrap: wrap;
                gap: 12px;
                align-items: center;
                justify-content: space-between;
                margin-bottom: 18px;
                background: rgba(0, 0, 0, 0.25);
                border: 1px solid rgba(255, 255, 255, 0.06);
                padding: 10px 14px;
                border-radius: 14px;
            }}
            .search-input {{
                flex: 1;
                min-width: 200px;
                padding: 8px 12px;
                font-size: 13px;
                border-radius: 8px;
            }}
            .filters-group {{
                display: flex;
                gap: 6px;
                align-items: center;
            }}
            .filter-btn {{
                background: rgba(255, 255, 255, 0.04);
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #94a3b8;
                padding: 6px 12px;
                border-radius: 8px;
                font-size: 12px;
                font-weight: 600;
                cursor: pointer;
                transition: 0.2s;
            }}
            .filter-btn.active {{
                background: rgba(56, 189, 248, 0.15);
                color: #38bdf8;
                border-color: rgba(56, 189, 248, 0.3);
            }}
            .sort-select {{
                padding: 6px 10px;
                font-size: 12px;
                border-radius: 8px;
            }}

            .users-container-grid {{
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(440px, 1fr));
                gap: 16px;
            }}
            .user-card {{
                background: rgba(11, 17, 32, 0.6);
                border: 1px solid rgba(255, 255, 255, 0.07);
                border-radius: 16px;
                padding: 18px;
                transition: transform 0.2s, opacity 0.2s;
            }}
            .user-header {{
                display: flex;
                justify-content: space-between;
                align-items: center;
                margin-bottom: 12px;
            }}
            .btn-micro {{
                padding: 4px 8px;
                font-size: 11px;
                font-weight: 600;
                border-radius: 6px;
                cursor: pointer;
                border: none;
                transition: 0.2s;
            }}
            .btn-micro-danger {{
                background: rgba(239, 68, 68, 0.15);
                color: #f87171;
                border: 1px solid rgba(239, 68, 68, 0.25);
            }}
            .btn-micro-danger:hover {{ background: rgba(239, 68, 68, 0.25); color: #fff; }}

            .sub-link-row {{
                display: flex;
                justify-content: space-between;
                align-items: center;
                background: rgba(0, 0, 0, 0.3);
                border: 1px solid rgba(255, 255, 255, 0.04);
                border-radius: 10px;
                padding: 6px 12px;
                margin-bottom: 10px;
            }}
            .sub-url-text {{
                font-family: ui-monospace, monospace;
                font-size: 11px;
                color: #38bdf8;
                overflow: hidden;
                text-overflow: ellipsis;
                white-space: nowrap;
                max-width: 310px;
            }}
            .btn-open-link {{
                color: #cbd5e1;
                text-decoration: none;
                font-size: 12px;
                font-weight: 600;
                padding: 2px 8px;
                border-radius: 6px;
                background: rgba(255, 255, 255, 0.06);
            }}
            .btn-open-link:hover {{ background: rgba(255, 255, 255, 0.12); color: #fff; }}

            .input-action-group {{
                display: flex;
                margin-bottom: 8px;
            }}
            .input-embedded {{
                flex: 1;
                border-top-right-radius: 0;
                border-bottom-right-radius: 0;
                border-right: none;
                padding: 6px 10px;
                font-size: 12px;
            }}
            .btn-embedded {{
                background: #0284c7;
                color: #fff;
                border: none;
                border-top-right-radius: 10px;
                border-bottom-right-radius: 10px;
                padding: 0 12px;
                font-size: 12px;
                font-weight: 600;
                cursor: pointer;
            }}

            .vpn-attach-zone {{
                background: rgba(0, 0, 0, 0.2);
                border: 1px dashed rgba(255, 255, 255, 0.08);
                border-radius: 12px;
                padding: 10px 12px;
                margin-top: 10px;
            }}
            .btn-upload-label {{
                background: rgba(255, 255, 255, 0.06);
                color: #cbd5e1;
                border: 1px solid rgba(255, 255, 255, 0.1);
                padding: 3px 8px;
                border-radius: 6px;
                font-size: 11px;
                font-weight: 600;
                cursor: pointer;
            }}
            .btn-upload-label:hover {{ background: rgba(255, 255, 255, 0.12); color: #fff; }}
            .btn-upload-label input[type="file"] {{ display: none; }}

            .chips-container {{
                display: flex;
                flex-wrap: wrap;
                gap: 6px;
                align-items: center;
            }}
            .file-chip {{
                background: rgba(255, 255, 255, 0.04);
                border: 1px solid rgba(255, 255, 255, 0.08);
                padding: 3px 8px;
                border-radius: 8px;
                display: inline-flex;
                align-items: center;
                gap: 4px;
            }}
            .file-chip-del {{
                background: none;
                border: none;
                color: #64748b;
                cursor: pointer;
                padding: 0 2px;
                font-size: 12px;
            }}
            .file-chip-del:hover {{ color: #ef4444; }}

            .brand-field {{ margin-bottom: 16px; }}
            .brand-field label {{
                display: block;
                font-size: 13px;
                color: #94a3b8;
                margin-bottom: 6px;
                font-weight: 600;
            }}
        </style>
    </head>
    <body>
        <div class="container">
            <div class="header-bar">
                <div style="display:flex; align-items:center; gap:10px;">
                    <h2 style="margin:0; font-size:18px; color:#38bdf8; letter-spacing:-0.5px;">OOMKilled Portal <span style="font-size:12px; color:#94a3b8; font-weight:normal;">v2.7</span></h2>
                </div>
                <div class="actions">
                    <a href="/backup" class="btn-nav">📥 Скачать бэкап</a>
                    <form id="restore-form" action="/restore-backup" method="post" enctype="multipart/form-data" style="margin:0;">
                        <label class="btn-nav">
                            <input type="file" name="backup_file" accept=".tar.gz,.gz" onchange="submitRestore(this)">
                            📤 Загрузить бэкап
                        </label>
                    </form>
                    <a href="/logout" class="btn-nav btn-logout">Выйти</a>
                </div>
            </div>

            <div class="main-nav">
                <button class="nav-tab active" onclick="switchNav('users', this)">Пользователи</button>
                <button class="nav-tab" onclick="switchNav('branding', this)">Кастомизация</button>
                <button class="nav-tab" onclick="switchNav('security', this)">Безопасность</button>
            </div>

            <div id="section-users" class="menu-section active">
                <div class="grid-stats">
                    <div class="stat-box">
                        <div class="stat-title">Всего пользователей</div>
                        <div class="stat-val">{len(users)}</div>
                    </div>
                    <div class="stat-box">
                        <div class="stat-title">SSL Протокол</div>
                        <div class="stat-val" style="font-size:15px; margin-top:8px;">{ssl_status_badge}</div>
                    </div>
                    <div class="stat-box">
                        <div class="stat-title">Нагрузка CPU</div>
                        <div class="stat-val">{cpu_usage}%</div>
                    </div>
                    <div class="stat-box">
                        <div class="stat-title">Оперативная память</div>
                        <div class="stat-val">{ram_usage}%</div>
                    </div>
                </div>

                <div class="panel">
                    <div class="panel-title">Добавить нового пользователя</div>
                    <form action="/add-user" method="post" class="form-grid">
                        <input type="text" name="username" placeholder="Имя профиля" required>
                        <select name="days">
                            <option value="0">Бессрочно</option>
                            <option value="7">7 дней</option>
                            <option value="30" selected>30 дней</option>
                            <option value="90">90 дней</option>
                            <option value="365">1 год</option>
                        </select>
                        <input type="text" name="proxy_url" placeholder="Ссылка TG прокси (необязательно)">
                        <button type="submit" class="btn-submit">+ Создать</button>
                    </form>
                </div>

                <div class="controls-bar">
                    <input type="text" id="user-search" class="search-input" placeholder="🔍 Поиск по имени пользователя..." oninput="applyFilters()">
                    
                    <div class="filters-group">
                        <button class="filter-btn active" onclick="setFilter('all', this)">Все</button>
                        <button class="filter-btn" onclick="setFilter('active', this)">Активные</button>
                        <button class="filter-btn" onclick="setFilter('paused', this)">Пауза</button>
                        <button class="filter-btn" onclick="setFilter('expired', this)">Истёкшие</button>
                    </div>

                    <select id="user-sort" class="sort-select" onchange="applyFilters()">
                        <option value="name_asc">По имени (А-Я)</option>
                        <option value="name_desc">По имени (Я-А)</option>
                        <option value="created_desc">Сначала новые</option>
                        <option value="days_asc">Сначала истекающие</option>
                    </select>
                </div>

                <div class="users-container-grid" id="users-grid">
                    {user_cards if user_cards else '<p style="color:#64748b;">Пользователи отсутствуют</p>'}
                </div>
            </div>

            <div id="section-branding" class="menu-section">
                <div class="panel">
                    <div class="panel-title">Параметры страницы подписки (/sub)</div>
                    <form action="/save-branding" method="post">
                        <div style="display:grid; grid-template-columns: 1fr 1fr; gap:16px;">
                            <div class="brand-field">
                                <label>Название сервиса:</label>
                                <input type="text" name="service_name" value="{branding.get('service_name', '')}" style="width:100%;" required>
                            </div>
                            <div class="brand-field">
                                <label>Ссылка на поддержку (Telegram):</label>
                                <input type="text" name="support_link" value="{branding.get('support_link', '')}" style="width:100%;" placeholder="https://t.me/support">
                            </div>
                        </div>

                        <div style="background:rgba(0,0,0,0.25); border:1px solid rgba(255,255,255,0.06); border-radius:14px; padding:16px; margin-bottom:20px;">
                            <div style="font-size:13px; font-weight:700; color:#38bdf8; margin-bottom:12px; text-transform:uppercase;">Кнопки приложений для клиентов</div>
                            <div style="display:grid; grid-template-columns: 1fr 1fr; gap:12px;">
                                <div class="brand-field" style="margin:0;">
                                    <label>iOS (App Store):</label>
                                    <input type="text" name="app_ios" value="{branding.get('app_ios', '')}" placeholder="https://apps.apple.com/app/..." style="width:100%;">
                                </div>
                                <div class="brand-field" style="margin:0;">
                                    <label>Android (Play Market / APK):</label>
                                    <input type="text" name="app_android" value="{branding.get('app_android', '')}" placeholder="https://play.google.com/store/apps/..." style="width:100%;">
                                </div>
                                <div class="brand-field" style="margin:0;">
                                    <label>Windows (EXE / ZIP):</label>
                                    <input type="text" name="app_windows" value="{branding.get('app_windows', '')}" placeholder="https://github.com/.../release.exe" style="width:100%;">
                                </div>
                                <div class="brand-field" style="margin:0;">
                                    <label>macOS (DMG):</label>
                                    <input type="text" name="app_macos" value="{branding.get('app_macos', '')}" placeholder="https://apps.apple.com/app/..." style="width:100%;">
                                </div>
                            </div>
                            <div class="brand-field" style="margin-top:12px; margin-bottom:0;">
                                <label>Linux (AppImage / DEB):</label>
                                <input type="text" name="app_linux" value="{branding.get('app_linux', '')}" placeholder="https://github.com/.../release.AppImage" style="width:100%;">
                            </div>
                        </div>

                        <div class="brand-field">
                            <label>Инструкция для iOS:</label>
                            <textarea name="guide_ios" rows="3" style="width:100%;">{branding.get('guide_ios', '')}</textarea>
                        </div>
                        <div class="brand-field">
                            <label>Инструкция для Android:</label>
                            <textarea name="guide_android" rows="3" style="width:100%;">{branding.get('guide_android', '')}</textarea>
                        </div>
                        <div class="brand-field">
                            <label>Инструкция для Desktop (ПК):</label>
                            <textarea name="guide_desktop" rows="3" style="width:100%;">{branding.get('guide_desktop', '')}</textarea>
                        </div>
                        <button type="submit" class="btn-submit" style="background:#10b981;">Сохранить параметры</button>
                    </form>
                </div>
            </div>

            <div id="section-security" class="menu-section">
                <div class="panel" style="max-width:560px;">
                    <div class="panel-title">Смена данных учетной записи администратора</div>
                    <p style="color:#94a3b8; font-size:13px; margin-top:-5px; margin-bottom:20px;">
                        После смены пароля браузер запросит повторный вход в панель.
                    </p>
                    <form action="/update-admin-credentials" method="post">
                        <div class="brand-field">
                            <label>Логин администратора:</label>
                            <input type="text" name="username" value="{admin_login}" style="width:100%;" required>
                        </div>
                        <div class="brand-field">
                            <label>Новый пароль:</label>
                            <input type="password" name="password" placeholder="Введите новый надежный пароль" style="width:100%;" required>
                        </div>
                        <button type="submit" class="btn-submit" style="background:#0ea5e9; width:100%; margin-top:8px;">Обновить логин и пароль</button>
                    </form>
                </div>
            </div>
        </div>

        <script>
            let currentStatusFilter = 'all';

            function switchNav(sec, btn) {{
                document.querySelectorAll('.nav-tab').forEach(t => t.classList.remove('active'));
                document.querySelectorAll('.menu-section').forEach(s => s.classList.remove('active'));
                btn.classList.add('active');
                document.getElementById('section-' + sec).classList.add('active');
            }}

            function submitRestore(input) {{
                if (input.files && input.files[0]) {{
                    if (confirm("Вы уверены, что хотите восстановить конфигурацию из архива? Текущая база пользователей будет заменена.")) {{
                        document.getElementById('restore-form').submit();
                    }} else {{
                        input.value = "";
                    }}
                }}
            }}

            function setFilter(status, btn) {{
                currentStatusFilter = status;
                document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
                applyFilters();
            }}

            function applyFilters() {{
                const query = document.getElementById('user-search').value.toLowerCase().trim();
                const sortType = document.getElementById('user-sort').value;
                const grid = document.getElementById('users-grid');
                const cards = Array.from(grid.querySelectorAll('.user-card'));

                cards.forEach(card => {{
                    const uName = card.getAttribute('data-username') || '';
                    const uStatus = card.getAttribute('data-status') || '';

                    const matchesSearch = uName.includes(query);
                    const matchesFilter = (currentStatusFilter === 'all') || (uStatus === currentStatusFilter);

                    if (matchesSearch && matchesFilter) {{
                        card.style.display = 'block';
                    }} else {{
                        card.style.display = 'none';
                    }}
                }});

                cards.sort((a, b) => {{
                    const nameA = a.getAttribute('data-username') || '';
                    const nameB = b.getAttribute('data-username') || '';
                    const daysA = parseInt(a.getAttribute('data-days') || '0', 10);
                    const daysB = parseInt(b.getAttribute('data-days') || '0', 10);
                    const createdA = parseInt(a.getAttribute('data-created') || '0', 10);
                    const createdB = parseInt(b.getAttribute('data-created') || '0', 10);

                    if (sortType === 'name_asc') return nameA.localeCompare(nameB);
                    if (sortType === 'name_desc') return nameB.localeCompare(nameA);
                    if (sortType === 'created_desc') return createdB - createdA;
                    if (sortType === 'days_asc') return daysA - daysB;
                    return 0;
                }});

                cards.forEach(card => grid.appendChild(card));
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
    app_ios: str = Form(""),
    app_android: str = Form(""),
    app_windows: str = Form(""),
    app_macos: str = Form(""),
    app_linux: str = Form(""),
    user: str = Depends(auth_user)
):
    save_branding({
        "service_name": service_name.strip(),
        "support_link": support_link.strip(),
        "guide_ios": guide_ios.strip(),
        "guide_android": guide_android.strip(),
        "guide_desktop": guide_desktop.strip(),
        "app_ios": app_ios.strip(),
        "app_android": app_android.strip(),
        "app_windows": app_windows.strip(),
        "app_macos": app_macos.strip(),
        "app_linux": app_linux.strip()
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

toggle_ssl_menu() {
    echo -e "\n\e[34m=== Управление SSL / HTTPS сертификатами ===\e[0m"
    local current_ssl="false"
    local current_type="self"
    local current_domain=""

    if [[ -f "$META_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$META_FILE"
        current_ssl="${USE_SSL:-false}"
        current_type="${SSL_TYPE:-self}"
        current_domain="${DOMAIN_NAME:-}"
    fi

    if [[ "$current_ssl" == "true" && "$current_type" == "letsencrypt" ]]; then
        echo -e "Текущий статус: \e[32mLet's Encrypt (домен: $current_domain)\e[0m"
    elif [[ "$current_ssl" == "true" ]]; then
        echo -e "Текущий статус: \e[36mСамоподписанный SSL (HTTPS)\e[0m"
    else
        echo -e "Текущий статус: \e[33mВЫКЛЮЧЕН (HTTP)\e[0m"
    fi

    echo "1) Выпустить официальный сертификат Let's Encrypt (по домену)"
    echo "2) Включить самоподписанный SSL"
    echo "3) Отключить SSL (вернуться на HTTP)"
    echo "0) Назад"
    read -rp "Выберите действие [0-3]: " SSL_CHOICE

    case "$SSL_CHOICE" in
        1)
            obtain_letsencrypt_ssl
            ;;
        2)
            generate_self_signed_ssl
            sed -i '/^USE_SSL=/d' "$META_FILE" 2>/dev/null || true
            sed -i '/^SSL_TYPE=/d' "$META_FILE" 2>/dev/null || true
            echo "USE_SSL=true" >> "$META_FILE"
            echo "SSL_TYPE=self" >> "$META_FILE"
            update_systemd_service
            systemctl restart mtproto-web.service
            echo -e "\e[32m✔ Самоподписанный SSL успешно включен!\e[0m"
            show_info
            ;;
        3)
            sed -i '/^USE_SSL=/d' "$META_FILE" 2>/dev/null || true
            echo "USE_SSL=false" >> "$META_FILE"
            update_systemd_service
            systemctl restart mtproto-web.service
            echo -e "\e[33m✔ SSL отключен, панель переведена на HTTP.\e[0m"
            show_info
            ;;
        *)
            return
            ;;
    esac
}

if [[ "${1:-}" == "--upgrade-modules" ]]; then
    systemctl stop mtproto-proxy.service 2>/dev/null || true
    systemctl disable mtproto-proxy.service 2>/dev/null || true
    rm -f /etc/systemd/system/mtproto-proxy.service /usr/local/bin/oom-rotate-tls 2>/dev/null || true

    write_app_modules
    python3 -c "
import json, os, secrets, time
p = '$USER_DATA_FILE'
if os.path.exists(p):
    with open(p) as f: d = json.load(f)
    ch = False
    now = int(time.time())
    for k, v in d.items():
        if 'created_at' not in v:
            v['created_at'] = now
            ch = True
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

b_path = '$BRANDING_FILE'
if os.path.exists(b_path):
    with open(b_path) as f: b = json.load(f)
    b_ch = False
    for field in ['app_ios', 'app_android', 'app_windows', 'app_macos', 'app_linux']:
        if field not in b:
            b[field] = ''
            b_ch = True
    if b_ch:
        with open(b_path, 'w') as f: json.dump(b, f, indent=2, ensure_ascii=False)
" 2>/dev/null || true

    update_systemd_service
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
    update_systemd_service
    systemctl restart mtproto-web.service mtproto-guardian.service
    echo -e "\e[32m✔ Конфигурация восстановлена, службы перезапущены!\e[0m"
    show_info
}

install_all() {
    echo -e "\n\e[34m=== Установка OOMKilled Portal v${SCRIPT_VERSION} ===\e[0m"

    echo "Установка системных пакетов..."
    apt-get update -qq
    apt-get install -y -qq python3 python3-venv python3-pip curl psmisc tar zip unzip openssl > /dev/null

    read -rp "Введите порт для Веб-панели [по умолчанию 8080]: " WEB_PORT
    WEB_PORT=${WEB_PORT:-8080}

    read -rp "Логин администратора веб-панели [по умолчанию admin]: " WEB_USER
    WEB_USER=${WEB_USER:-admin}

    read -rp "Пароль администратора веб-панели [по умолчанию oomkilled]: " WEB_PASS
    WEB_PASS=${WEB_PASS:-oomkilled}

    if [[ -d "$INSTALL_DIR" ]]; then
        systemctl stop mtproto-web.service mtproto-guardian.service 2>/dev/null || true
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

    cat <<EOF > "$META_FILE"
IP=$IP
WEB_PORT=$WEB_PORT
WEB_USER=$WEB_USER
WEB_PASS=$WEB_PASS
USE_SSL=false
SSL_TYPE=none
DOMAIN_NAME=
EOF

    write_app_modules
    update_systemd_service

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

    if command -v ufw &>/dev/null && ufw status | grep -qw active; then
        ufw allow "$WEB_PORT"/tcp >/dev/null 2>&1 || true
        ufw allow 80/tcp >/dev/null 2>&1 || true
    fi

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

    local use_ssl="${USE_SSL:-false}"
    local ssl_type="${SSL_TYPE:-self}"
    local domain_name="${DOMAIN_NAME:-}"
    local proto="http"
    [[ "$use_ssl" == "true" ]] && proto="https"

    IP=$(curl -s -4 ifconfig.me || curl -s -4 api.ipify.org)
    local host_addr="$IP"
    if [[ "$use_ssl" == "true" && "$ssl_type" == "letsencrypt" && -n "$domain_name" ]]; then
        host_addr="$domain_name"
    fi

    echo -e "\n\e[36m================ OOMKilled Portal (v${SCRIPT_VERSION}) ================\e[0m"
    echo -e "Веб-панель:   \e[36m${proto}://${host_addr}:${WEB_PORT}\e[0m"
    echo -e "Режим SSL:    \e[33m$([[ "$use_ssl" == "true" ]] && echo "$ssl_type (${proto^^})" || echo "Выключен (HTTP)")\e[0m"
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
        sub_url = f'$proto://$host_addr:$WEB_PORT/sub/{sub}'
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
    update_systemd_service
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
    echo "3) Настроить SSL (Домен Let's Encrypt / Самоподписанный)"
    echo "4) Перезапустить службу / Fixer"
    echo "5) Посмотреть логи панели"
    echo "6) Обновить скрипт с GitHub"
    echo "7) Резервное копирование и восстановление"
    echo "8) Полностью удалить портал"
    echo "0) Выход"
    read -rp "Выберите действие [0-8]: " OPTION

    case "$OPTION" in
        1) install_all ;;
        2) show_info ;;
        3) toggle_ssl_menu ;;
        4) fix_and_restart ;;
        5) journalctl -u mtproto-web.service -f ;;
        6) self_update ;;
        7)
            echo -e "\n1) Создать резервную копию\n2) Восстановить из резервной копии"
            read -rp "Ваш выбор [1-2]: " B_OPT
            [[ "$B_OPT" == "1" ]] && create_backup
            [[ "$B_OPT" == "2" ]] && restore_backup
            ;;
        8) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "\e[31mНеверный выбор.\e[0m\n" ;;
    esac
done