#!/bin/bash
set -e

echo "🚀 Установка авторассылки Telegram..."

# === 0) Проверка ОС ===
if [[ "$OSTYPE" != "darwin"* ]]; then
  echo "⚠️ Этот установщик рассчитан на macOS. Для Linux потребуется адаптация."
fi

# === 1) Homebrew ===
if ! command -v brew &> /dev/null; then
  echo "🍺 Устанавливаем Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# === 2) pyenv, virtualenv, git, nano ===
echo "🐍 Устанавливаем pyenv, pyenv-virtualenv, git, nano..."
brew install pyenv pyenv-virtualenv git nano || true

# Добавляем инициализацию pyenv в zshrc (если её там нет)
if ! grep -q 'pyenv init' ~/.zshrc; then
  {
    echo ''
    echo '# pyenv init'
    echo 'eval "$(pyenv init -)"'
    echo 'eval "$(pyenv virtualenv-init -)"'
  } >> ~/.zshrc
fi

# Подгружаем pyenv в текущую оболочку
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"

# === 3) Python через pyenv ===
PYTHON_VERSION=3.10.13
if ! pyenv versions | grep -q "$PYTHON_VERSION"; then
  echo "⬇️ Ставим Python $PYTHON_VERSION..."
  pyenv install "$PYTHON_VERSION"
fi
if ! pyenv virtualenvs | grep -q "tg_env_tgsender"; then
  pyenv virtualenv "$PYTHON_VERSION" tg_env_tgsender
fi

# === 4) Папка проекта ===
TARGET_DIR=~/tg_sender
mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

# === 5) requirements.txt ===
cat <<'EOF' > requirements.txt
telethon==1.41.2
apscheduler==3.11.0
python-dotenv==1.1.1
rsa==4.9.1
pyaes==1.6.1
pyasn1==0.6.1
tzlocal==5.3.1
EOF

# === 6) Активируем окружение и ставим зависимости ===
pyenv activate tg_env_tgsender
echo "📦 Устанавливаем зависимости..."
pip install --upgrade pip
pip install -r requirements.txt

# === 7) Ввод данных ===
echo "➡️ Введите данные для подключения:"
read -p "API_ID (my.telegram.org): " API_ID
read -p "API_HASH: " API_HASH
read -p "PHONE (+380...): " PHONE

echo ""
echo "➡️ Введите текст рассылки (Ctrl+D — завершить ввод):"
MESSAGE=$(</dev/stdin)

# === 8) .env ===
cat <<EOF > .env
API_ID=$API_ID
API_HASH=$API_HASH
PHONE=$PHONE

HOURLY_EVERY_MIN=60
DAILY_EVERY_MIN=1440
THREEDAYS_EVERY_MIN=4320

SEND_DELAY=3
JITTER_PCT=0.10
EOF

# === 9) message.txt ===
cat <<EOF > message.txt
$MESSAGE
EOF

# === 10) sender_full.py ===
cat <<'EOF' > sender_full.py
import os, re, asyncio, random, signal, json, time
from typing import List, Tuple, Optional
from telethon import TelegramClient
from telethon.errors import FloodWaitError, SessionPasswordNeededError
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from dotenv import load_dotenv

load_dotenv()

API_ID  = int(os.getenv("API_ID"))
API_HASH = os.getenv("API_HASH")
PHONE    = os.getenv("PHONE")

MESSAGE_FILE = "message.txt"
GROUPS_DIR = "groups"
LOGS_DIR   = "logs"
STATE_FILE = "last_sent.json"

HOURLY_EVERY_MIN   = int(os.getenv("HOURLY_EVERY_MIN", "60"))
DAILY_EVERY_MIN    = int(os.getenv("DAILY_EVERY_MIN", "1440"))
THREEDAYS_EVERY_MIN= int(os.getenv("THREEDAYS_EVERY_MIN", "4320"))

SEND_DELAY = float(os.getenv("SEND_DELAY", "3"))
JITTER_PCT = float(os.getenv("JITTER_PCT", "0.10"))

GROUP_FILES = {
    "hourly":   os.path.join(GROUPS_DIR, "hourly.txt"),
    "daily":    os.path.join(GROUPS_DIR, "daily.txt"),
    "3days":    os.path.join(GROUPS_DIR, "3days.txt"),
}

os.makedirs(GROUPS_DIR, exist_ok=True)
os.makedirs(LOGS_DIR, exist_ok=True)

# --- state ---
def load_state():
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except: return {}
    return {}

def save_state(state):
    with open(STATE_FILE, "w", encoding="utf-8") as f:
        json.dump(state, f)

STATE = load_state()

def mark_sent(group: str):
    STATE[group] = int(time.time())
    save_state(STATE)

def was_recently_sent(group: str, label: str) -> bool:
    now = int(time.time())
    last = STATE.get(group, 0)
    if label == "hourly":   return now - last < HOURLY_EVERY_MIN*60
    if label == "daily":    return now - last < DAILY_EVERY_MIN*60
    if label == "3days":    return now - last < THREEDAYS_EVERY_MIN*60
    return False

# --- helpers ---
def load_message():
    if os.path.exists(MESSAGE_FILE):
        return open(MESSAGE_FILE, "r", encoding="utf-8").read().strip()
    return "⚡️ Тестовое сообщение"

def load_groups(path: str):
    if not os.path.exists(path): return []
    lines = [ln.strip() for ln in open(path,"r",encoding="utf-8") if ln.strip() and not ln.startswith("#")]
    seen, out = set(), []
    for g in lines:
        if g not in seen:
            seen.add(g); out.append(g)
    return out

def parse_topic_link(link: str) -> Tuple[str, Optional[int]]:
    m = re.match(r'^(https?://t\.me/[^/\s]+)/(\d+)$', link)
    return (m.group(1), int(m.group(2))) if m else (link, None)

async def smart_sleep():
    if SEND_DELAY <= 0: return
    jitter = SEND_DELAY * JITTER_PCT
    delay = max(0.0, random.uniform(SEND_DELAY-jitter, SEND_DELAY+jitter))
    await asyncio.sleep(delay)

async def send_one(client, link, msg, label):
    if was_recently_sent(link, label):
        print(f"[{label}] -> {link} ⏩ пропущено (недавно отправлено)")
        return
    base, topic_id = parse_topic_link(link)
    try:
        if topic_id: await client.send_message(base, msg, reply_to=topic_id)
        else:        await client.send_message(base, msg)
        print(f"[{label}] -> {link} ✅")
        mark_sent(link)
    except FloodWaitError as fw:
        print(f"[{label}] -> {link} ⚠️ FloodWait: {fw.seconds}s (пропускаем)")
    except Exception as e:
        print(f"[{label}] -> {link} ❌ {e}")

async def send_list(client, label):
    path = GROUP_FILES[label]
    groups, msg = load_groups(path), load_message()
    if not groups: return
    print(f"=== {label} рассылка ({len(groups)}) ===")
    for g in groups:
        await send_one(client, g, msg, label)
        await smart_sleep()
    print(f"=== {label} завершена ===")

async def ensure_login(client: TelegramClient):
    await client.connect()
    if await client.is_user_authorized(): return
    await client.send_code_request(PHONE)
    code = input("➡️ Код из Telegram: ").strip()
    try:
        await client.sign_in(PHONE, code)
    except SessionPasswordNeededError:
        pw = input("🔐 Пароль 2FA: ").strip()
        await client.sign_in(password=pw)

async def runner():
    while True:
        try:
            client = TelegramClient("tg_session", API_ID, API_HASH)
            await ensure_login(client)
            print("✅ Авторизация выполнена")

            # автостарт
            for lb in ("hourly","daily","3days"):
                await send_list(client, lb)

            scheduler = AsyncIOScheduler()
            scheduler.add_job(lambda: asyncio.create_task(send_list(client,"hourly")),"interval",minutes=HOURLY_EVERY_MIN)
            scheduler.add_job(lambda: asyncio.create_task(send_list(client,"daily")),"interval",minutes=DAILY_EVERY_MIN)
            scheduler.add_job(lambda: asyncio.create_task(send_list(client,"3days")),"interval",minutes=THREEDAYS_EVERY_MIN)
            scheduler.start()

            await asyncio.Event().wait()
        except Exception as e:
            print("💥 Ошибка, перезапуск через 5с:", e)
            await asyncio.sleep(5)

if __name__ == "__main__":
    asyncio.run(runner())
EOF

# === 11) Группы ===
mkdir -p groups

cat <<'EOF' > groups/hourly.txt
https://t.me/Sugar_Desk
https://t.me/devil_desk
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

# === 12) Сервисные скрипты ===
# (start.sh, stop.sh, setmsg.sh, setgroups.sh, setenv.sh, setdelays.sh, relogin.sh — как у тебя выше, без изменений)

echo ""
echo "✅ Установка завершена!"
echo "Запустить сейчас:  cd ~/tg_sender && ./start.sh"
echo "Полезные команды:"
echo "  ./stop.sh       — остановить"
echo "  ./status.sh     — статус"
echo "  ./setmsg.sh     — сменить текст"
echo "  ./setgroups.sh  — редактировать списки"
echo "  ./setenv.sh     — сменить API/номер"
echo "  ./setdelays.sh  — сменить интервалы/задержки"
echo "  ./relogin.sh    — новый аккаунт (удалит сессию)"
