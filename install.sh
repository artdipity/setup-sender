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
  echo "⬇️ Ставим Python $PYTHON_VERSION (может занять время)..."
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

# === 8) .env (включая интервалы/задержки, можно менять командой setdelays.sh) ===
cat <<EOF > .env
API_ID=$API_ID
API_HASH=$API_HASH
PHONE=$PHONE

# интервалы (в минутах)
HOURLY_EVERY_MIN=60
DAILY_EVERY_MIN=1440
THREEDAYS_EVERY_MIN=4320

# задержки между отправками в секундах
SEND_DELAY=3
JITTER_PCT=0.10
EOF

# === 9) message.txt ===
cat <<EOF > message.txt
$MESSAGE
EOF

# === 10) sender_full.py (2FA, автосенд сразу по всем, затем по расписанию; /topic поддержка) ===
cat <<'EOF' > sender_full.py
import os, re, asyncio, random, signal
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

# интервалы в минутах
HOURLY_EVERY_MIN   = int(os.getenv("HOURLY_EVERY_MIN", "60"))
DAILY_EVERY_MIN    = int(os.getenv("DAILY_EVERY_MIN", "1440"))
THREEDAYS_EVERY_MIN= int(os.getenv("THREEDAYS_EVERY_MIN", "4320"))

# задержки
SEND_DELAY = float(os.getenv("SEND_DELAY", "3"))
JITTER_PCT = float(os.getenv("JITTER_PCT", "0.10"))

GROUP_FILES = {
    "hourly":   os.path.join(GROUPS_DIR, "hourly.txt"),
    "daily":    os.path.join(GROUPS_DIR, "daily.txt"),
    "3days":    os.path.join(GROUPS_DIR, "3days.txt"),
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
    lines = []
    with open(path, "r", encoding="utf-8") as f:
        for ln in f:
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            lines.append(ln)
    # удалим дубли, сохраняя порядок
    seen = set()
    out = []
    for g in lines:
        if g not in seen:
            seen.add(g)
            out.append(g)
    return out

def parse_topic_link(link: str) -> Tuple[str, Optional[int]]:
    """
    Поддержка форумных тем: https://t.me/<chat>/<topic_id>
    Возвращает (основная_ссылка, topic_id|None)
    """
    m = re.match(r'^(https?://t\.me/[^/\s]+)/(\d+)$', link)
    if m:
        return m.group(1), int(m.group(2))
    return link, None

async def smart_sleep():
    if SEND_DELAY <= 0:
        return
    jitter = SEND_DELAY * JITTER_PCT
    delay = max(0.0, random.uniform(SEND_DELAY - jitter, SEND_DELAY + jitter))
    await asyncio.sleep(delay)

async def send_one(client: TelegramClient, link: str, msg: str, label: str):
    base, topic_id = parse_topic_link(link)
    try:
        if topic_id:
            await client.send_message(base, msg, reply_to=topic_id)
        else:
            await client.send_message(base, msg)
        print(f"[{label}] -> {link} ✅ отправлено")
    except FloodWaitError as fw:
        print(f"[{label}] -> {link} ❌ FloodWait: {fw.seconds}s")
    except Exception as e:
        print(f"[{label}] -> {link} ❌ ошибка: {e}")

async def blast_list(client: TelegramClient, label: str):
    path = GROUP_FILES[label]
    groups = load_groups(path)
    msg = load_message()
    if not groups:
        print(f"[{label}] список пуст — пропускаем")
        return
    print(f"=== Автостарт {label}: {len(groups)} групп ===")
    for g in groups:
        await send_one(client, g, msg, label)
        await smart_sleep()
    print(f"=== Автостарт {label} завершён ===")

async def send_list(client: TelegramClient, label: str):
    path = GROUP_FILES[label]
    groups = load_groups(path)
    msg = load_message()
    if not groups:
        print(f"[{label}] список пуст — пропускаем")
        return
    print(f"=== Рассылка {label} начата ===")
    for g in groups:
        await send_one(client, g, msg, label)
        await smart_sleep()
    print(f"=== Рассылка {label} завершена ===")

async def ensure_login(client: TelegramClient):
    await client.connect()
    if await client.is_user_authorized():
        return
    # отправим код
    await client.send_code_request(PHONE)
    code = input("➡️ Введите код из Telegram: ").strip()
    try:
        await client.sign_in(PHONE, code)
    except SessionPasswordNeededError:
        pw = input("🔐 Введите 2FA пароль (если не включён — просто Enter): ")
        await client.sign_in(password=pw)

async def main():
    client = TelegramClient("tg_session", API_ID, API_HASH)
    await ensure_login(client)
    print("✅ Авторизация выполнена.")

    # Автостарт: разослать по всем спискам
    for lb in ("hourly","daily","3days"):
        await blast_list(client, lb)

    # Планировщик
    scheduler = AsyncIOScheduler()
    scheduler.add_job(lambda: asyncio.create_task(send_list(client,"hourly")),
                      "interval", minutes=HOURLY_EVERY_MIN)
    scheduler.add_job(lambda: asyncio.create_task(send_list(client,"daily")),
                      "interval", minutes=DAILY_EVERY_MIN)
    scheduler.add_job(lambda: asyncio.create_task(send_list(client,"3days")),
                      "interval", minutes=THREEDAYS_EVERY_MIN)
    scheduler.start()

    print("⏳ Расписание запущено. Работает круглосуточно...")
    stop_event = asyncio.Event()

    def handle_sig(*_):
        print("⛔️ Завершение...")
        stop_event.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            asyncio.get_running_loop().add_signal_handler(sig, handle_sig)
        except NotImplementedError:
            pass

    await stop_event.wait()

if __name__ == "__main__":
    asyncio.run(main())
EOF

# === 11) Группы (твои списки) ===
mkdir -p groups

# hourly.txt — большой список
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

# daily.txt — пример
cat <<'EOF' > groups/daily.txt
https://t.me/adult_18_board
https://t.me/onlyfanspromoroom
https://t.me/Adult_platform
https://t.me/OnlyBulletin
https://t.me/adult_desk
EOF

# 3days.txt — пример
cat <<'EOF' > groups/3days.txt
https://t.me/CardoCrewDesk
https://t.me/CardoCrewDeskTraffic
https://t.me/adszavety
EOF

# === 12) Сервисные скрипты ===

# запуск
cat <<'EOF' > start.sh
#!/bin/bash
cd ~/tg_sender
eval "$(pyenv init -)"; eval "$(pyenv virtualenv-init -)"
pyenv activate tg_env_tgsender
echo "▶️  Старт: авторизация/рассылка..."
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
echo "📝 Введите новый текст (Ctrl+D — завершить):"
cat > message.txt
echo "✅ Сообщение обновлено. Перезапустите: ./stop.sh && ./start.sh"
EOF
chmod +x setmsg.sh

# редактирование списков групп
cat <<'EOF' > setgroups.sh
#!/bin/bash
cd ~/tg_sender/groups
echo "📂 Откроется nano. Сохранение: Ctrl+O, Enter. Выход: Ctrl+X."
read -p "Открыть hourly.txt? (y/n): " A; [[ "$A" == "y" ]] && nano hourly.txt
read -p "Открыть daily.txt?  (y/n): " B; [[ "$B" == "y" ]] && nano daily.txt
read -p "Открыть 3days.txt? (y/n): " C; [[ "$C" == "y" ]] && nano 3days.txt
echo "✅ Группы обновлены. Перезапустите: ~/tg_sender/stop.sh && ~/tg_sender/start.sh"
EOF
chmod +x setgroups.sh

# обновление .env (API/PHONE)
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
# интервалы (мин)
HOURLY_EVERY_MIN=${HOURLY_EVERY_MIN:-60}
DAILY_EVERY_MIN=${DAILY_EVERY_MIN:-1440}
THREEDAYS_EVERY_MIN=${THREEDAYS_EVERY_MIN:-4320}
# задержки
SEND_DELAY=${SEND_DELAY:-3}
JITTER_PCT=${JITTER_PCT:-0.10}
ENV
echo "✅ Данные сохранены в .env"
echo "Перезапустите рассылку: ./stop.sh && ./start.sh"
EOF
chmod +x setenv.sh

# смена интервалов/задержек
cat <<'EOF' > setdelays.sh
#!/bin/bash
cd ~/tg_sender
source .env 2>/dev/null || true
read -p "HOURLY_EVERY_MIN (мин, по умолчанию ${HOURLY_EVERY_MIN:-60}): " A
read -p "DAILY_EVERY_MIN (мин, по умолчанию ${DAILY_EVERY_MIN:-1440}): " B
read -p "THREEDAYS_EVERY_MIN (мин, по умолчанию ${THREEDAYS_EVERY_MIN:-4320}): " C
read -p "SEND_DELAY (сек, по умолчанию ${SEND_DELAY:-3}): " D
read -p "JITTER_PCT (доля, по умолчанию ${JITTER_PCT:-0.10}): " E
cat <<ENV > .env
API_ID=${API_ID}
API_HASH=${API_HASH}
PHONE=${PHONE}
HOURLY_EVERY_MIN=${A:-${HOURLY_EVERY_MIN:-60}}
DAILY_EVERY_MIN=${B:-${DAILY_EVERY_MIN:-1440}}
THREEDAYS_EVERY_MIN=${C:-${THREEDAYS_EVERY_MIN:-4320}}
SEND_DELAY=${D:-${SEND_DELAY:-3}}
JITTER_PCT=${E:-${JITTER_PCT:-0.10}}
ENV
echo "✅ Параметры сохранены. Перезапустите: ./stop.sh && ./start.sh"
EOF
chmod +x setdelays.sh

# полная переавторизация (смена номера)
cat <<'EOF' > relogin.sh
#!/bin/bash
cd ~/tg_sender
echo "⛔️ Удаляем старую сессию..."
rm -f tg_session.session*
./setenv.sh
echo "Теперь запустите ./start.sh и пройдите код/пароль заново."
EOF
chmod +x relogin.sh

echo ""
echo "✅ Установка завершена!"
echo "Запустить сейчас:  cd ~/tg_sender && ./start.sh"
echo "Полезные команды:"
echo "  ./stop.sh           — остановить"
echo "  ./status.sh         — статус"
echo "  ./setmsg.sh         — сменить текст сообщения"
echo "  ./setgroups.sh      — отредактировать списки групп"
echo "  ./setenv.sh         — сменить API/номер"
echo "  ./setdelays.sh      — сменить интервалы/задержки"
echo "  ./relogin.sh        — вход с новым номером (удалит сессию)"
