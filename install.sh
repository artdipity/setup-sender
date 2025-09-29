#!/bin/bash
set -e

echo "🚀 Установка авторассылки Telegram..."

# === 0. Проверка ОС ===
if [[ "$OSTYPE" != "darwin"* ]]; then
  echo "⚠️ Этот установщик рассчитан на macOS. Для Linux потребуется адаптация."
fi

# === 1. Homebrew ===
if ! command -v brew &> /dev/null; then
  echo "🍺 Устанавливаем Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# === 2. pyenv и git ===
echo "🐍 Устанавливаем pyenv и pyenv-virtualenv..."
brew install pyenv pyenv-virtualenv git nano

# Добавляем pyenv в zshrc
if ! grep -q 'pyenv init' ~/.zshrc; then
  {
    echo ''
    echo '# pyenv init'
    echo 'eval "$(pyenv init -)"'
    echo 'eval "$(pyenv virtualenv-init -)"'
  } >> ~/.zshrc
fi

eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"

# === 3. Python ===
PYTHON_VERSION=3.10.13
if ! pyenv versions | grep -q "$PYTHON_VERSION"; then
  echo "⬇️ Ставим Python $PYTHON_VERSION..."
  pyenv install "$PYTHON_VERSION"
fi

if ! pyenv virtualenvs | grep -q "tg_env_tgsender"; then
  pyenv virtualenv "$PYTHON_VERSION" tg_env_tgsender
fi

# === 4. Папка проекта ===
TARGET_DIR=~/tg_sender
mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

# === 5. requirements.txt ===
cat <<EOF > requirements.txt
telethon==1.41.2
apscheduler==3.11.0
python-dotenv==1.1.1
rsa==4.9.1
pyaes==1.6.1
pyasn1==0.6.1
tzlocal==5.3.1
EOF

pyenv activate tg_env_tgsender
echo "📦 Устанавливаем зависимости..."
pip install --upgrade pip
pip install -r requirements.txt

# === 6. Ввод данных ===
echo "➡️ Введите данные для подключения:"
read -p "API_ID (my.telegram.org): " API_ID
read -p "API_HASH: " API_HASH
read -p "PHONE (+380...): " PHONE

echo "➡️ Введите текст рассылки (Ctrl+D — завершить ввод):"
MESSAGE=$(</dev/stdin)

# === 7. Создаём .env ===
cat <<EOF > .env
API_ID=$API_ID
API_HASH=$API_HASH
PHONE=$PHONE
EOF

# === 8. message.txt ===
cat <<EOF > message.txt
$MESSAGE
EOF

# === 9. sender_full.py ===
cat <<'EOF' > sender_full.py
import os, re, asyncio
from typing import List, Tuple, Optional
from telethon import TelegramClient
from telethon.errors import FloodWaitError
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from dotenv import load_dotenv

load_dotenv()
API_ID = int(os.getenv("API_ID"))
API_HASH = os.getenv("API_HASH")
PHONE = os.getenv("PHONE")

MESSAGE_FILE = "message.txt"
GROUPS_DIR = "groups"
LOGS_DIR = "logs"
GROUP_FILES = {
    "hourly": os.path.join(GROUPS_DIR, "hourly.txt"),
    "daily": os.path.join(GROUPS_DIR, "daily.txt"),
    "3days": os.path.join(GROUPS_DIR, "3days.txt"),
}
os.makedirs(GROUPS_DIR, exist_ok=True)
os.makedirs(LOGS_DIR, exist_ok=True)

def load_message():
    if os.path.exists(MESSAGE_FILE):
        return open(MESSAGE_FILE, "r", encoding="utf-8").read().strip()
    return "⚡️ Тестовое сообщение"

def load_groups(path: str) -> List[str]:
    if not os.path.exists(path): return []
    lines = [ln.strip() for ln in open(path, "r", encoding="utf-8") if ln.strip()]
    seen, result = set(), []
    for g in lines:
        if g not in seen:
            seen.add(g); result.append(g)
    return result

def parse_topic_link(link: str) -> Tuple[str, Optional[int]]:
    m = re.match(r'^(https?://t\.me/[^/\s]+)/(\d+)$', link)
    return (m.group(1), int(m.group(2))) if m else (link, None)

async def send_one(client, link, msg, label):
    base, topic_id = parse_topic_link(link)
    try:
        if topic_id: await client.send_message(base, msg, reply_to=topic_id)
        else: await client.send_message(base, msg)
        print(f"[{label}] -> {link} ✅")
    except FloodWaitError as fw:
        print(f"[{label}] FloodWait {fw.seconds}s")
    except Exception as e:
        print(f"[{label}] {link} ❌ {e}")

async def blast_list(client, label):
    groups, msg = load_groups(GROUP_FILES[label]), load_message()
    if not groups: return
    print(f"=== Автостарт {label} ({len(groups)}) ===")
    for g in groups: await send_one(client, g, msg, label); await asyncio.sleep(3)

async def send_list(client, label):
    groups, msg = load_groups(GROUP_FILES[label]), load_message()
    if not groups: return
    print(f"=== Рассылка {label} ===")
    for g in groups: await send_one(client, g, msg, label); await asyncio.sleep(3)

async def main():
    client = TelegramClient("tg_session", API_ID, API_HASH)
    await client.start(phone=PHONE)
    print("✅ Авторизация успешна")

    for lb in ("hourly","daily","3days"): await blast_list(client, lb)

    scheduler = AsyncIOScheduler()
    scheduler.add_job(lambda: asyncio.create_task(send_list(client,"hourly")),"interval",hours=1)
    scheduler.add_job(lambda: asyncio.create_task(send_list(client,"daily")),"interval",hours=24)
    scheduler.add_job(lambda: asyncio.create_task(send_list(client,"3days")),"interval",hours=72)
    scheduler.start()
    print("⏳ Расписание запущено...")
    await asyncio.Event().wait()

if __name__ == "__main__": asyncio.run(main())
EOF

# === 10. Группы (готовые списки) ===
mkdir -p groups
cat <<'EOF' > groups/hourly.txt
https://t.me/Sugar_Desk
https://t.me/devil_desk
EOF

cat <<'EOF' > groups/daily.txt
https://t.me/adult_18_board
https://t.me/onlyfanspromoroom
EOF

cat <<'EOF' > groups/3days.txt
https://t.me/CardoCrewDesk
https://t.me/adszavety
EOF

# === 11. Сервисные скрипты ===
cat <<'EOF' > start.sh
#!/bin/bash
cd ~/tg_sender
eval "$(pyenv init -)"; eval "$(pyenv virtualenv-init -)"
pyenv activate tg_env_tgsender
python sender_full.py
EOF
chmod +x start.sh

cat <<'EOF' > stop.sh
#!/bin/bash
pkill -f "python sender_full.py" || true
echo "⛔️ Остановлено."
EOF
chmod +x stop.sh

cat <<'EOF' > status.sh
#!/bin/bash
ps aux | grep sender_full.py | grep -v grep || echo "Не запущено"
EOF
chmod +x status.sh

cat <<'EOF' > setmsg.sh
#!/bin/bash
cd ~/tg_sender
echo "📝 Введите новый текст (Ctrl+D — завершить):"
cat > message.txt
echo "✅ Сообщение обновлено."
EOF
chmod +x setmsg.sh

cat <<'EOF' > setgroups.sh
#!/bin/bash
cd ~/tg_sender/groups
nano hourly.txt daily.txt 3days.txt
EOF
chmod +x setgroups.sh

cat <<'EOF' > setenv.sh
#!/bin/bash
cd ~/tg_sender
read -p "API_ID: " API_ID
read -p "API_HASH: " API_HASH
read -p "PHONE: " PHONE
cat <<ENV > .env
API_ID=$API_ID
API_HASH=$API_HASH
PHONE=$PHONE
ENV
echo "✅ Данные сохранены."
EOF
chmod +x setenv.sh

cat <<'EOF' > relogin.sh
#!/bin/bash
cd ~/tg_sender
echo "⛔️ Удаляем старую сессию..."
rm -f tg_session.session
./setenv.sh
echo "Теперь запустите ./start.sh для входа с новым номером."
EOF
chmod +x relogin.sh

echo "✅ Установка завершена!"
echo "Запустите: cd ~/tg_sender && ./start.sh"
