#!/bin/bash
set -e

echo "🚀 Установка авторассылки Telegram..."

# === 1. Homebrew (если нет) ===
if ! command -v brew &> /dev/null; then
  echo "🍺 Устанавливаем Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# === 2. pyenv и pyenv-virtualenv ===
echo "🐍 Устанавливаем pyenv и pyenv-virtualenv..."
brew install pyenv pyenv-virtualenv git

if ! grep -q 'pyenv init' ~/.zshrc; then
  echo 'eval "$(pyenv init -)"' >> ~/.zshrc
  echo 'eval "$(pyenv virtualenv-init -)"' >> ~/.zshrc
fi

# === 3. Python ===
PYTHON_VERSION=3.10.13
if ! pyenv versions | grep -q $PYTHON_VERSION; then
  echo "⬇️ Ставим Python $PYTHON_VERSION..."
  pyenv install $PYTHON_VERSION
fi

if ! pyenv virtualenvs | grep -q tg_env_tgsender; then
  pyenv virtualenv $PYTHON_VERSION tg_env_tgsender
fi

# === 4. Создаём папку проекта ===
TARGET_DIR=~/tg_sender
mkdir -p $TARGET_DIR
cd $TARGET_DIR

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

# === 6. Активируем окружение ===
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"
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

# === 8. Сохраняем данные в .env ===
cat <<EOF > .env
API_ID=$API_ID
API_HASH=$API_HASH
PHONE=$PHONE
EOF

# === 9. Сохраняем сообщение ===
cat <<EOF > message.txt
$MESSAGE
EOF

# === 10. sender_full.py ===
cat <<'EOF' > sender_full.py
import os
import asyncio
from telethon import TelegramClient
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from dotenv import load_dotenv

# Загружаем переменные
load_dotenv()
API_ID = int(os.getenv("API_ID"))
API_HASH = os.getenv("API_HASH")
PHONE = os.getenv("PHONE")

# Пути к файлам
MESSAGE_FILE = "message.txt"
GROUPS_DIR = "groups"

GROUP_FILES = {
    "hourly": os.path.join(GROUPS_DIR, "hourly.txt"),
    "daily": os.path.join(GROUPS_DIR, "daily.txt"),
    "3days": os.path.join(GROUPS_DIR, "3days.txt"),
}

# Загружаем сообщение
def load_message():
    if os.path.exists(MESSAGE_FILE):
        with open(MESSAGE_FILE, "r", encoding="utf-8") as f:
            return f.read().strip()
    return "⚡️ Тестовое сообщение"

# Загружаем список групп
def load_groups(filename):
    if not os.path.exists(filename):
        return []
    with open(filename, "r", encoding="utf-8") as f:
        return [line.strip() for line in f if line.strip()]

# Рассылка сообщений
async def send_to_groups(client, groups, label, message):
    if not groups:
        print(f"[{label}] список пуст — пропускаем")
        return

    print(f"=== Рассылка {label} начата ===")
    for group in groups:
        try:
            await client.send_message(group, message)
            print(f"[{label}] -> {group} ✅ отправлено")
            await asyncio.sleep(3)  # задержка между группами
        except Exception as e:
            print(f"[{label}] -> {group} ❌ ошибка: {e}")
    print(f"=== Рассылка {label} завершена ===")

# Основная логика
async def main():
    message = load_message()
    client = TelegramClient("tg_session", API_ID, API_HASH)

    await client.start(phone=PHONE)

    # Автостарт рассылки сразу по всем спискам
    print("🚀 Автостарт-рассылка по всем группам...")
    for label, path in GROUP_FILES.items():
        groups = load_groups(path)
        await send_to_groups(client, groups, label, message)

    # Планировщик
    scheduler = AsyncIOScheduler()

    # Каждый час
    scheduler.add_job(
        send_to_groups,
        "interval",
        args=[client, load_groups(GROUP_FILES["hourly"]), "hourly", message],
        hours=1,
    )

    # Каждые сутки
    scheduler.add_job(
        send_to_groups,
        "interval",
        args=[client, load_groups(GROUP_FILES["daily"]), "daily", message],
        hours=24,
    )

    # Каждые 3 суток
    scheduler.add_job(
        send_to_groups,
        "interval",
        args=[client, load_groups(GROUP_FILES["3days"]), "3days", message],
        hours=72,
    )

    scheduler.start()
    print("⏳ Расписание запущено. Работает круглосуточно...")
    await asyncio.Event().wait()


if __name__ == "__main__":
    asyncio.run(main())
EOF

# === 11. Группы ===
mkdir -p groups

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

cat <<'EOF' > groups/daily.txt
https://t.me/adult_18_board
https://t.me/onlyfanspromoroom
https://t.me/Adult_platform
https://t.me/OnlyBulletin
https://t.me/adult_desk
EOF

cat <<'EOF' > groups/3days.txt
https://t.me/CardoCrewDesk
https://t.me/CardoCrewDeskTraffic
https://t.me/adszavety
EOF

# === 12. start/stop/status ===
cat <<'EOF' > start.sh
#!/bin/bash
cd ~/tg_sender
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"
pyenv activate tg_env_tgsender
python sender_full.py
EOF
chmod +x start.sh

cat <<'EOF' > stop.sh
#!/bin/bash
pkill -f "python sender_full.py" || true
EOF
chmod +x stop.sh

cat <<'EOF' > status.sh
#!/bin/bash
ps aux | grep sender_full.py | grep -v grep
EOF
chmod +x status.sh

echo "✅ Установка завершена!"
echo "Теперь запустите:"
echo "cd ~/tg_sender && ./start.sh"
