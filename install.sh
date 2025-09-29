#!/bin/bash
set -e

echo "🚀 Установка авторассылки Telegram..."

# === 0. Проверка оболочки на macOS ===
if [[ "$OSTYPE" != "darwin"* ]]; then
  echo "Этот инсталлятор рассчитан на macOS. Для Linux потребуется адаптация."
fi

# === 1. Homebrew (если нет) ===
if ! command -v brew &> /dev/null; then
  echo "🍺 Устанавливаем Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# === 2. pyenv и pyenv-virtualenv ===
echo "🐍 Устанавливаем pyenv и pyenv-virtualenv..."
brew install pyenv pyenv-virtualenv git nano

# Добавляем инициализацию в ~/.zshrc (если нет)
if ! grep -q 'pyenv init' ~/.zshrc; then
  {
    echo ''
    echo '# pyenv init'
    echo 'eval "$(pyenv init -)"'
    echo 'eval "$(pyenv virtualenv-init -)"'
  } >> ~/.zshrc
fi

# Загружаем окружение pyenv в текущую оболочку
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"

# === 3. Python через pyenv ===
PYTHON_VERSION=3.10.13
if ! pyenv versions | grep -q "$PYTHON_VERSION"; then
  echo "⬇️ Ставим Python $PYTHON_VERSION (может занять время)..."
  pyenv install "$PYTHON_VERSION"
fi

# Создаём виртуальное окружение (если нет)
if ! pyenv virtualenvs | grep -q "tg_env_tgsender"; then
  pyenv virtualenv "$PYTHON_VERSION" tg_env_tgsender
fi

# === 4. Создаём папку проекта ===
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

# === 6. Активируем окружение и ставим зависимости ===
pyenv activate tg_env_tgsender
echo "📦 Устанавливаем зависимости..."
pip install --upgrade pip
pip install -r requirements.txt

# === 7. Ввод данных пользователя ===
echo "➡️ Введите данные для подключения:"
read -p "API_ID (с my.telegram.org): " API_ID
read -p "API_HASH: " API_HASH
read -p "PHONE (+380...): " PHONE

echo "➡️ Введите текст рассылки (окончание Ctrl+D):"
MESSAGE=$(</dev/stdin)

# === 8. .env ===
cat <<EOF > .env
API_ID=$API_ID
API_HASH=$API_HASH
PHONE=$PHONE
EOF

# === 9. message.txt ===
cat <<EOF > message.txt
$MESSAGE
EOF

# === 10. sender_full.py ===
cat <<'EOF' > sender_full.py
import os
import re
import asyncio
from typing import List, Tuple, Optional
from telethon import TelegramClient
from telethon.errors import FloodWaitError
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from dotenv import load_dotenv

# --- загрузка конфигураций ---
load_dotenv()
API_ID = int(os.getenv("API_ID"))
API_HASH = os.getenv("API_HASH")
PHONE = os.getenv("PHONE")

MESSAGE_FILE = "message.txt"
GROUPS_DIR = "groups"
LOGS_DIR = "logs"

GROUP_FILES = {
    "hourly": os.path.join(GROUPS_DIR, "hourly.txt"),
    "daily":  os.path.join(GROUPS_DIR, "daily.txt"),
    "3days":  os.path.join(GROUPS_DIR, "3days.txt"),
}

os.makedirs(GROUPS_DIR, exist_ok=True)
os.makedirs(LOGS_DIR, exist_ok=True)

def load_message() -> str:
    if os.path.exists(MESSAGE_FILE):
        with open(MESSAGE_FILE, "r", encoding="utf-8") as f:
            return f.read().strip()
    return "⚡️ Тестовое сообщение"

def load_groups(path: str) -> List[str]:
    if not os.path.exists(path):
        return []
    with open(path, "r", encoding="utf-8") as f:
        lines = [ln.strip() for ln in f if ln.strip() and not ln.strip().startswith("#")]
    # Удаляем дубликаты, сохраняя порядок
    seen = set()
    result = []
    for g in lines:
        if g not in seen:
            seen.add(g)
            result.append(g)
    return result

def parse_topic_link(link: str) -> Tuple[str, Optional[int]]:
    """
    Поддержка форумных тем: https://t.me/<chat>/<topic_id>
    Возвращает (основная_ссылка, topic_id|None).
    """
    m = re.match(r'^(https?://t\.me/[^/\s]+)/(\d+)$', link)
    if m:
        base = m.group(1)
        topic_id = int(m.group(2))
        return base, topic_id
    return link, None

async def send_one(client: TelegramClient, link: str, message: str, label: str):
    base, topic_id = parse_topic_link(link)
    try:
        if topic_id:
            # Пытаемся отправить в конкретную тему форума как reply_to
            await client.send_message(base, message, reply_to=topic_id)
        else:
            await client.send_message(base, message)
        print(f"[{label}] -> {link} ✅ отправлено")
    except FloodWaitError as fw:
        print(f"[{label}] -> {link} ❌ FloodWait: {fw.seconds}s")
    except Exception as e:
        print(f"[{label}] -> {link} ❌ ошибка: {e}")

async def blast_list(client: TelegramClient, label: str):
    """
    Мгновенная рассылка по всему списку (для автостарта).
    """
    path = GROUP_FILES[label]
    groups = load_groups(path)
    msg = load_message()
    if not groups:
        print(f"[{label}] список пуст — пропускаем")
        return
    print(f"=== Автостарт: {label} ({len(groups)}) ===")
    for g in groups:
        await send_one(client, g, msg, label)
        await asyncio.sleep(3)
    print(f"=== Автостарт {label} завершён ===")

async def send_list(client: TelegramClient, label: str):
    """
    Плановая рассылка списка label с динамической подгрузкой текста и групп.
    """
    path = GROUP_FILES[label]
    groups = load_groups(path)
    msg = load_message()
    if not groups:
        print(f"[{label}] список пуст — пропускаем")
        return
    print(f"=== Рассылка {label} начата ===")
    for g in groups:
        await send_one(client, g, msg, label)
        await asyncio.sleep(3)
    print(f"=== Рассылка {label} завершена ===")

async def main():
    client = TelegramClient("tg_session", API_ID, API_HASH)
    await client.start(phone=PHONE)
    print("✅ Авторизация выполнена.")

    # 1) Автостарт: сразу отправить по всем трем спискам
    for lb in ("hourly", "daily", "3days"):
        await blast_list(client, lb)

    # 2) Планировщик: hourly/daily/3days
    scheduler = AsyncIOScheduler()
    scheduler.add_job(lambda: asyncio.create_task(send_list(client, "hourly")),
                      "interval", hours=1)
    scheduler.add_job(lambda: asyncio.create_task(send_list(client, "daily")),
                      "interval", hours=24)
    scheduler.add_job(lambda: asyncio.create_task(send_list(client, "3days")),
                      "interval", hours=72)
    scheduler.start()

    print("⏳ Расписание запущено. Работает круглосуточно...")
    await asyncio.Event().wait()

if __name__ == "__main__":
    asyncio.run(main())
EOF

# === 11. Группы ===
mkdir -p groups

# ---- hourly.txt (твои группы) ----
cat <<'EOF' > groups/hourly.txt
https://t.me/Sugar_Desk
https://t.me/devil_desk
https://t.me/TopDatingForum
https://t.me/brachnie/4
https://t.me/Dating_Forums
https://t.me/adult_news1/1
https://t.me/brachnie/1
https://t.me/datingforumm/1
https://t.me/dating_board/1
https://t.me/board_adult1/1
https://t.me/TvoyaVip/1
https://t.me/OFM_Rich/1
https://t.me/StartDoska/1
https://t.me/onlyfans_board1/1
https://t.me/LookHereDoskaOF/1
https://t.me/JustDoska/1
https://t.me/THE_EDENIC_DESK
https://t.me/only_traff
https://t.me/luxury_adult
https://t.me/adult_team_desk
https://t.me/TeamUnityHub
https://t.me/lixxidesk
https://t.me/PandaDesk
https://t.me/barbie_agency111
https://t.me/onlymiumiu
https://t.me/adult_desk
https://t.me/DinoDesk
https://t.me/easyonlyeo
https://t.me/doska_365
https://t.me/adult_board_ofm
https://t.me/BuddaHubBoard
https://t.me/TopDatingForum
https://t.me/dating_board
https://t.me/mixxidesk
https://t.me/adultbestdesk
https://t.me/desk_shark
https://t.me/OFBchat
https://t.me/OnlyBulletin
https://t.me/Adults_play_Board
https://t.me/desk_lion
https://t.me/ADOboard
https://t.me/Minnieadult
https://t.me/board_adult1
https://t.me/promoperfrection
https://t.me/only_fasly
https://t.me/webcamadultdesk
https://t.me/KarandashDesk
https://t.me/ONLYTRAFCH
https://t.me/IndustryAdult
https://t.me/Onlyfans_Hunters
https://t.me/bigdoskaoficial
https://t.me/bigdoskaof
https://t.me/LookHereDoskaOF
https://t.me/onlyfans_live_board
https://t.me/of_desk
https://t.me/board_onlyfans
https://t.me/onlyfans_desk
https://t.me/rumorsii
https://t.me/ICE_adult
https://t.me/easyonlyeasyeo
https://t.me/onlyfans_chaty
https://t.me/onlyfansboom
https://t.me/Adaltpro
https://t.me/adulters_BF
https://t.me/boardonlyfans
https://t.me/webcamdoska
https://t.me/forumonly/597
https://t.me/onlydeskadult
https://t.me/TeamUnityWow
https://t.me/FunsDesk
https://t.me/onlyfans_legit
https://t.me/ofmboardonlyfans
https://t.me/TeamUnityAdult
https://t.me/theOFMdesk
https://t.me/MonkeyDesk
https://t.me/only_adult_chat
https://t.me/onlyfans_mart
https://t.me/DeskCrew
https://t.me/of_desk_adalt
https://t.me/VampireDesk
https://t.me/OnlyBoardTG
https://t.me/HubDesk
https://t.me/unholy_desk
https://t.me/adult_headhunt
https://t.me/doska1012
https://t.me/Advertising_BF
https://t.me/AdultHarmonyDesk
https://t.me/adult_news1
https://t.me/StartDoska
https://t.me/virgin_grooup
https://t.me/Adult_Board
https://t.me/adultswit_desk
https://t.me/webcam_token
https://t.me/DeskSpark
https://t.me/SoloMoon_community
https://t.me/onlyadating
https://t.me/CrocoDesk
https://t.me/collectordesk
https://t.me/acaagawgfwa
https://t.me/ADULT_DOSKA
https://t.me/only_adult_desk
https://t.me/Meduza_OF_Desk
https://t.me/black_only_desk
https://t.me/coredesk
https://t.me/only_desk
https://t.me/jobadult
https://t.me/nikodesk
https://t.me/onlydesc
https://t.me/wixxidesk
https://t.me/onlyfanspromoroom
https://t.me/adult_markets
https://t.me/OnlyDesk
https://t.me/BIGDesk
https://t.me/Dating_Forums
https://t.me/SugarDesk
https://t.me/disneydesk
https://t.me/Workers_Desk
https://t.me/camweboard
https://t.me/goatsof
https://t.me/OTC_ADULT
https://t.me/apreeteam_desk
https://t.me/adulthubdoska
EOF

# ---- daily.txt ----
cat <<'EOF' > groups/daily.txt
https://t.me/adult_18_board
https://t.me/onlyfanspromoroom
https://t.me/Adult_platform
https://t.me/OnlyBulletin
https://t.me/adult_desk
EOF

# ---- 3days.txt ----
cat <<'EOF' > groups/3days.txt
https://t.me/CardoCrewDesk
https://t.me/CardoCrewDeskTraffic
https://t.me/adszavety
EOF

# === 12. сервисные скрипты ===

# запуск
cat <<'EOF' > start.sh
#!/bin/bash
cd ~/tg_sender
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"
pyenv activate tg_env_tgsender
echo "▶️  Старт рассылки..."
python sender_full.py
EOF
chmod +x start.sh

# стоп
cat <<'EOF' > stop.sh
#!/bin/bash
pkill -f "python sender_full.py" || true
echo "⛔️ Остановлено."
EOF
chmod +x stop.sh

# статус
cat <<'EOF' > status.sh
#!/bin/bash
ps aux | grep sender_full.py | grep -v grep || echo "Не запущено"
EOF
chmod +x status.sh

# смена сообщения
cat <<'EOF' > setmsg.sh
#!/bin/bash
cd ~/tg_sender
echo "📝 Введите новый текст сообщения (Ctrl+D — завершить ввод):"
cat > message.txt
echo "✅ Сообщение сохранено в message.txt"
EOF
chmod +x setmsg.sh

# редактирование списков групп
cat <<'EOF' > setgroups.sh
#!/bin/bash
cd ~/tg_sender/groups
echo "📂 Редактируем группы. Файлы: hourly.txt, daily.txt, 3days.txt"
echo "Откроется nano. Сохранение: Ctrl+O, Enter. Выход: Ctrl+X."
read -p "Открыть hourly.txt? (y/n): " A; [[ "$A" == "y" ]] && nano hourly.txt
read -p "Открыть daily.txt? (y/n): " B; [[ "$B" == "y" ]] && nano daily.txt
read -p "Открыть 3days.txt? (y/n): " C; [[ "$C" == "y" ]] && nano 3days.txt
echo "✅ Группы обновлены."
EOF
chmod +x setgroups.sh

# обновление .env без переустановки
cat <<'EOF' > setenv.sh
#!/bin/bash
cd ~/tg_sender
read -p "API_ID: " API_ID
read -p "API_HASH: " API_HASH
read -p "PHONE (+...): " PHONE
cat <<ENV > .env
API_ID=$API_ID
API_HASH=$API_HASH
PHONE=$PHONE
ENV
echo "✅ Данные сохранены в .env"
EOF
chmod +x setenv.sh

echo "✅ Установка завершена!"
echo "Теперь запустите:"
echo "cd ~/tg_sender && ./start.sh"
