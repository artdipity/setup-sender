#!/bin/bash
set -e

echo "🚀 Установка авторассылки Telegram..."

# === 0) macOS check ===
if [[ "$OSTYPE" != "darwin"* ]]; then
  echo "⚠️ Скрипт рассчитан на macOS. На Linux нужна адаптация."
fi

# === 1) Homebrew ===
if ! command -v brew &>/dev/null; then
  echo "🍺 Устанавливаем Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# === 2) pyenv, virtualenv, git, nano ===
echo "🐍 Устанавливаем pyenv, pyenv-virtualenv, git, nano..."
brew install pyenv pyenv-virtualenv git nano || true

# Добавим pyenv инициализацию
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
mkdir -p "$TARGET_DIR"/{groups,logs,accounts,sessions}
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
echo "➡️ Введите данные для подключения (аккаунт: default):"
read -p "API_ID (my.telegram.org): " API_ID
read -p "API_HASH: " API_HASH
read -p "PHONE (+380...): " PHONE

echo ""
echo "➡️ Введите текст рассылки (Ctrl+D — завершить ввод):"
MESSAGE=$(</dev/stdin)

# === 8) .env для аккаунта default ===
cat <<EOF > accounts/default.env
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

# === 10) sender_full.py (с логами, историей, FloodWait-менеджером) ===
cat <<'EOF' > sender_full.py
import os, re, asyncio, random, signal, json, time, logging
from logging.handlers import TimedRotatingFileHandler
from typing import List, Tuple, Optional, Dict, Any
from telethon import TelegramClient
from telethon.errors import FloodWaitError, SessionPasswordNeededError
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from dotenv import dotenv_values

BASE_DIR     = os.path.expanduser("~/tg_sender")
ACCOUNTS_DIR = os.path.join(BASE_DIR, "accounts")
GROUPS_DIR   = os.path.join(BASE_DIR, "groups")
LOGS_DIR     = os.path.join(BASE_DIR, "logs")
SESS_DIR     = os.path.join(BASE_DIR, "sessions")
STATE_FILE   = os.path.join(BASE_DIR, "sent_history.json")
MESSAGE_FILE = os.path.join(BASE_DIR, "message.txt")

os.makedirs(GROUPS_DIR, exist_ok=True)
os.makedirs(LOGS_DIR, exist_ok=True)
os.makedirs(SESS_DIR, exist_ok=True)
os.makedirs(ACCOUNTS_DIR, exist_ok=True)

GROUP_FILES = {
    "hourly":  os.path.join(GROUPS_DIR, "hourly.txt"),
    "daily":   os.path.join(GROUPS_DIR, "daily.txt"),
    "3days":   os.path.join(GROUPS_DIR, "3days.txt"),
}

# ---------- logging ----------
logger = logging.getLogger("tgsender")
logger.setLevel(logging.INFO)
fmt = logging.Formatter("%(asctime)s | %(levelname)s | %(message)s")
fh = TimedRotatingFileHandler(os.path.join(LOGS_DIR, "sender.log"), when="midnight", backupCount=14, encoding="utf-8")
fh.setFormatter(fmt)
sh = logging.StreamHandler()
sh.setFormatter(fmt)
logger.addHandler(fh)
logger.addHandler(sh)

def load_state() -> Dict[str, Any]:
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}

def save_state(state: Dict[str, Any]) -> None:
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False)
    os.replace(tmp, STATE_FILE)

STATE = load_state()

def now_ts() -> int:
    return int(time.time())

def set_next_due(group: str, label: str, minutes: int) -> None:
    due = now_ts() + minutes * 60
    s = STATE.get(group, {})
    s["next_due_ts"] = max(due, s.get("next_due_ts", 0))
    STATE[group] = s
    save_state(STATE)

def mark_sent(group: str, label: str, minutes_interval: int) -> None:
    s = STATE.get(group, {})
    s["last_sent_ts"] = now_ts()
    s["next_due_ts"] = s["last_sent_ts"] + minutes_interval * 60
    STATE[group] = s
    save_state(STATE)

def next_due_for(label: str, env: Dict[str,str]) -> int:
    if label == "hourly":  return int(env.get("HOURLY_EVERY_MIN", 60))
    if label == "daily":   return int(env.get("DAILY_EVERY_MIN", 1440))
    if label == "3days":   return int(env.get("THREEDAYS_EVERY_MIN", 4320))
    return 60

def load_message() -> str:
    if os.path.exists(MESSAGE_FILE):
        return open(MESSAGE_FILE, "r", encoding="utf-8").read().strip()
    return "⚡️ Тестовое сообщение"

def load_groups(path: str) -> List[str]:
    if not os.path.exists(path): return []
    raw = [ln.strip() for ln in open(path,"r",encoding="utf-8") if ln.strip() and not ln.strip().startswith("#")]
    seen, out = set(), []
    for g in raw:
        if g not in seen:
            seen.add(g); out.append(g)
    return out

def parse_topic_link(link: str) -> Tuple[str, Optional[int]]:
    m = re.match(r'^(https?://t\.me/[^/\s]+)/(\d+)$', link)
    return (m.group(1), int(m.group(2))) if m else (link, None)

async def smart_sleep(env: Dict[str,str]):
    SEND_DELAY = float(env.get("SEND_DELAY", 3))
    JITTER_PCT = float(env.get("JITTER_PCT", 0.10))
    if SEND_DELAY <= 0: return
    jitter = SEND_DELAY * JITTER_PCT
    delay = max(0.0, random.uniform(SEND_DELAY - jitter, SEND_DELAY + jitter))
    await asyncio.sleep(delay)

async def send_one(client: TelegramClient, link: str, msg: str, label: str, env: Dict[str,str]):
    interval_min = next_due_for(label, env)
    due = STATE.get(link, {}).get("next_due_ts", 0)
    if now_ts() < due:
        logger.info(f"[{label}] -> {link} ⏳ ещё рано (ожидать до {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(due))})")
        return
    base, topic_id = parse_topic_link(link)
    try:
        if topic_id:
            await client.send_message(base, msg, reply_to=topic_id)
        else:
            await client.send_message(base, msg)
        logger.info(f"[{label}] -> {link} ✅ отправлено")
        mark_sent(link, label, interval_min)
    except FloodWaitError as fw:
        logger.warning(f"[{label}] -> {link} ⚠️ FloodWait: {fw.seconds}s")
        # зафиксируем "нельзя до ..."
        s = STATE.get(link, {})
        s["next_due_ts"] = max(now_ts() + fw.seconds, s.get("next_due_ts", 0))
        STATE[link] = s
        save_state(STATE)
    except Exception as e:
        logger.error(f"[{label}] -> {link} ❌ {e}")

async def send_list(client: TelegramClient, label: str, env: Dict[str,str]):
    path = GROUP_FILES[label]
    groups, msg = load_groups(path), load_message()
    if not groups:
        logger.info(f"[{label}] список пуст — пропускаем")
        return
    logger.info(f"=== Рассылка {label} начата ({len(groups)}) ===")
    for g in groups:
        await send_one(client, g, msg, label, env)
        await smart_sleep(env)
    logger.info(f"=== Рассылка {label} завершена ===")

async def ensure_login(client: TelegramClient, env: Dict[str,str], account_name: str):
    await client.connect()
    if await client.is_user_authorized(): return
    phone = env["PHONE"]
    await client.send_code_request(phone)
    code = input(f"➡️ [{account_name}] Код из Telegram: ").strip()
    try:
        await client.sign_in(phone, code)
    except SessionPasswordNeededError:
        pw = input(f"🔐 [{account_name}] Пароль 2FA (если нет — пусто): ").strip()
        await client.sign_in(password=pw)

def load_account_env(name: str) -> Dict[str,str]:
    env_path = os.path.join(ACCOUNTS_DIR, f"{name}.env")
    if not os.path.exists(env_path):
        raise RuntimeError(f"Файл аккаунта не найден: {env_path}")
    env = dotenv_values(env_path)
    req = ("API_ID","API_HASH","PHONE")
    for k in req:
        if not env.get(k):
            raise RuntimeError(f"{env_path}: отсутствует {k}")
    return env

async def run_account(name: str):
    env = load_account_env(name)
    api_id = int(env["API_ID"])
    api_hash = env["API_HASH"]
    session_path = os.path.join(SESS_DIR, f"{name}.session")
    client = TelegramClient(session_path, api_id, api_hash)
    await ensure_login(client, env, name)
    logger.info(f"✅ [{name}] авторизация ОК")

    # автостарт: отправить где уже можно (с учётом next_due_ts)
    for lb in ("hourly","daily","3days"):
        await send_list(client, lb, env)

    # планировщик
    scheduler = AsyncIOScheduler()
    scheduler.add_job(lambda: asyncio.create_task(send_list(client,"hourly",env)),
                      "interval", minutes=next_due_for("hourly", env))
    scheduler.add_job(lambda: asyncio.create_task(send_list(client,"daily",env)),
                      "interval", minutes=next_due_for("daily", env))
    scheduler.add_job(lambda: asyncio.create_task(send_list(client,"3days",env)),
                      "interval", minutes=next_due_for("3days", env))
    scheduler.start()
    logger.info(f"⏳ [{name}] расписание запущено")

    stop_event = asyncio.Event()
    def handle_sig(*_): logger.info(f"⛔️ [{name}] завершение..."); stop_event.set()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            asyncio.get_running_loop().add_signal_handler(sig, handle_sig)
        except NotImplementedError:
            pass
    await stop_event.wait()

async def main():
    # пока запускаем один аккаунт — default
    await run_account("default")

if __name__ == "__main__":
    asyncio.run(main())
EOF

# === 11) Группы (твой готовый список) ===
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

# === 12) сервисные скрипты ===

# запуск
cat <<'EOF' > start.sh
#!/bin/bash
cd ~/tg_sender
eval "$(pyenv init -)"; eval "$(pyenv virtualenv-init -)"
pyenv activate tg_env_tgsender
echo "▶️  Старт рассылки (аккаунт default)..."
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

# обновление .env (API/PHONE) для default
cat <<'EOF' > setenv.sh
#!/bin/bash
cd ~/tg_sender
read -p "API_ID: " API_ID
read -p "API_HASH: " API_HASH
read -p "PHONE (+...): " PHONE
cat <<ENV > accounts/default.env
API_ID=$API_ID
API_HASH=$API_HASH
PHONE=$PHONE
HOURLY_EVERY_MIN=${HOURLY_EVERY_MIN:-60}
DAILY_EVERY_MIN=${DAILY_EVERY_MIN:-1440}
THREEDAYS_EVERY_MIN=${THREEDAYS_EVERY_MIN:-4320}
SEND_DELAY=${SEND_DELAY:-3}
JITTER_PCT=${JITTER_PCT:-0.10}
ENV
echo "✅ Данные сохранены в accounts/default.env"
echo "Перезапустите рассылку: ./stop.sh && ./start.sh"
EOF
chmod +x setenv.sh

# смена интервалов/задержек
cat <<'EOF' > setdelays.sh
#!/bin/bash
cd ~/tg_sender
ENV_FILE="accounts/default.env"
touch "$ENV_FILE"
source "$ENV_FILE" 2>/dev/null || true
read -p "HOURLY_EVERY_MIN (мин, по умолчанию ${HOURLY_EVERY_MIN:-60}): " A
read -p "DAILY_EVERY_MIN (мин, по умолчанию ${DAILY_EVERY_MIN:-1440}): " B
read -p "THREEDAYS_EVERY_MIN (мин, по умолчанию ${THREEDAYS_EVERY_MIN:-4320}): " C
read -p "SEND_DELAY (сек, по умолчанию ${SEND_DELAY:-3}): " D
read -p "JITTER_PCT (доля, по умолчанию ${JITTER_PCT:-0.10}): " E
cat <<ENV > "$ENV_FILE"
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
echo "⛔️ Удаляем старую сессию (default)..."
rm -f sessions/default.session*
./setenv.sh
echo "Теперь запустите ./start.sh и пройдите код/пароль заново."
EOF
chmod +x relogin.sh

# === 13) Автозапуск через launchd (login item) ===
PLIST=~/Library/LaunchAgents/com.tgsender.default.plist
mkdir -p ~/Library/LaunchAgents
cat <<EOF > "$PLIST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.tgsender.default</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>-lc</string>
    <string>cd ~/tg_sender && ./start.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>~/tg_sender/logs/launchd.out.log</string>
  <key>StandardErrorPath</key><string>~/tg_sender/logs/launchd.err.log</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" &>/dev/null || true
launchctl load "$PLIST" || true

echo ""
echo "✅ Установка завершена!"
echo "Запустить вручную сейчас:  cd ~/tg_sender && ./start.sh"
echo "Полезные команды:"
echo "  ./stop.sh         — остановить"
echo "  ./status.sh       — статус"
echo "  ./setmsg.sh       — сменить текст"
echo "  ./setgroups.sh    — править списки"
echo "  ./setenv.sh       — сменить API/номер"
echo "  ./setdelays.sh    — сменить интервалы/задержки"
echo "  ./relogin.sh      — вход с новым номером (удалит сессию)"
echo ""
echo "🧷 Автозапуск включён (launchd). При входе в macOS рассылка поднимется сама."
