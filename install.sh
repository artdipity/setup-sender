#!/bin/bash
set -euo pipefail

# -------- базовые пути --------
HOME_DIR="$HOME"
PROJECT="$HOME_DIR/tg_sender"
VENV="$HOME_DIR/tg_env_tgsender"

say() { printf "\n\033[1m%s\033[0m\n" "$*"; }

say "1) Создаю структуру проекта: $PROJECT"
mkdir -p "$PROJECT"/{groups,logs}

say "2) Проверяю Python и создаю виртуальное окружение"
if ! command -v python3 >/dev/null 2>&1; then
  echo "Не найден python3. Установите Xcode Command Line Tools: xcode-select --install"
  exit 1
fi
python3 -m venv "$VENV"

say "3) Устанавливаю зависимости (telethon, apscheduler, python-dotenv)"
source "$VENV/bin/activate"
pip install --upgrade pip setuptools wheel >/dev/null
pip install telethon apscheduler python-dotenv >/dev/null

cd "$PROJECT"

say "4) Пишу основной скрипт sender_full.py (поддержка /тем в форумах)"
cat > sender_full.py <<'PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, asyncio, random
from datetime import datetime
from typing import Tuple, Optional
from telethon import TelegramClient
from telethon.errors import FloodWaitError, RPCError
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from dotenv import load_dotenv

load_dotenv()

def need(var):
    v = os.getenv(var)
    if not v:
        print(f"ERROR: заполни переменную {var} в .env")
        raise SystemExit(1)
    return v

API_ID    = int(need("API_ID"))
API_HASH  = need("API_HASH")
PHONE     = os.getenv("PHONE")  # можно пустым: Telethon спросит при первом запуске
SESSION   = os.getenv("SESSION_NAME", "tg_broadcaster_session")

DELAY  = float(os.getenv("DELAY_BETWEEN_MESSAGES","60"))
JITTER = float(os.getenv("JITTER_PCT","0.15"))

FILE_HOURLY = "groups/groups_hourly.txt"
FILE_DAILY  = "groups/groups_daily.txt"
FILE_3DAYS  = "groups/groups_3days.txt"
MSG_FILE    = "message.txt"

def load_message():
    if os.path.exists(MSG_FILE):
        return open(MSG_FILE,"r",encoding="utf-8").read().strip()
    return "⚠️ message.txt отсутствует или пуст."

def load_groups(path):
    if not os.path.exists(path): return []
    with open(path,"r",encoding="utf-8") as f:
        return [ln.strip() for ln in f if ln.strip() and not ln.startswith("#")]

def parse_target(s: str) -> Tuple[str, Optional[int]]:
    # https://t.me/group/123 -> (https://t.me/group, 123)
    if s.startswith("http") and s.count("/")>=3:
        p = s.rstrip("/").split("/")
        if p[-1].isdigit():
            return "/".join(p[:-1]), int(p[-1])
    return s, None

async def jitter_sleep():
    await asyncio.sleep(max(0.0, DELAY * (1.0 + random.uniform(-JITTER, JITTER))))

async def send_list(client, path, label):
    msg = load_message()
    targets = load_groups(path)
    if not targets:
        print(f"[{label}] список пуст — пропускаем ({path})"); return
    print(f"=== [{label}] старт {datetime.now().isoformat()} / {len(targets)} групп ===")
    for i, raw in enumerate(targets, 1):
        target, topic = parse_target(raw)
        try:
            entity = await client.get_entity(target)
            if topic is not None:
                await client.send_message(entity, msg, reply_to=topic)  # пост в тему
                print(f"[{label}] {i}/{len(targets)} {raw} -> тема {topic}")
            else:
                await client.send_message(entity, msg)
                print(f"[{label}] {i}/{len(targets)} {raw} -> чат")
        except FloodWaitError as e:
            print(f"[{label}] {raw} -> FloodWait {e.seconds}s (пропускаем)")
        except RPCError as e:
            print(f"[{label}] {raw} -> RPCError: {e}")
        except Exception as e:
            print(f"[{label}] {raw} -> Ошибка: {e}")
        await jitter_sleep()
    print(f"=== [{label}] финиш {datetime.now().isoformat()} ===")

async def main():
    client = TelegramClient(SESSION, API_ID, API_HASH)
    await client.start(phone=PHONE)
    me = await client.get_me()
    print(f"✅ Авторизация: {getattr(me,'first_name','')} (@{getattr(me,'username','')})")

    sched = AsyncIOScheduler()
    # Запускаем сразу и далее по расписанию
    sched.add_job(send_list, 'interval', hours=1,  args=[client, FILE_HOURLY, "hourly"], next_run_time=datetime.now())
    sched.add_job(send_list, 'interval', hours=24, args=[client, FILE_DAILY,  "daily"],  next_run_time=datetime.now())
    sched.add_job(send_list, 'interval', hours=72, args=[client, FILE_3DAYS,  "3days"],  next_run_time=datetime.now())
    sched.start()
    print("⏳ Планировщик запущен: hourly=1ч, daily=24ч, 3days=72ч.\nМеняй message.txt и groups/* — перезапуск не нужен.")

    await asyncio.Event().wait()

if __name__ == "__main__":
    asyncio.run(main())
PY

say "5) Предзаполняю .env (пустые поля сейчас запросим)"
cat > .env <<'ENV'
SESSION_NAME=tg_broadcaster_session
API_ID=
API_HASH=
PHONE=
DELAY_BETWEEN_MESSAGES=60
JITTER_PCT=0.15
ENV

say "6) Предзаполняю списки групп (hourly / daily / 3days)"
# hourly
cat > groups/groups_hourly.txt <<'EOF'
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

# daily
cat > groups/groups_daily.txt <<'EOF'
https://t.me/adult_18_board
https://t.me/onlyfanspromoroom
https://t.me/Adult_platform
https://t.me/OnlyBulletin
https://t.me/adult_desk
EOF

# 3days
cat > groups/groups_3days.txt <<'EOF'
https://t.me/CardoCrewDesk
https://t.me/CardoCrewDeskTraffic
https://t.me/adszavety
EOF

say "7) Запрашиваю API_ID / API_HASH / PHONE и пишу .env"
read -p "API_ID (my.telegram.org): " API_ID
read -p "API_HASH: " API_HASH
read -p "PHONE (с +): " PHONE
cat > .env <<ENV
SESSION_NAME=tg_broadcaster_session
API_ID=${API_ID}
API_HASH=${API_HASH}
PHONE=${PHONE}
DELAY_BETWEEN_MESSAGES=60
JITTER_PCT=0.15
ENV

say "8) Вставьте текст сообщения. Окончание ввода: Ctrl+D"
cat > message.txt

say "9) Создаю сервисные скрипты start/stop/status"
cat > start.sh <<'ST'
#!/bin/bash
set -e
source "$HOME/tg_env_tgsender/bin/activate"
cd "$HOME/tg_sender"
nohup python sender_full.py >> logs/run.log 2>&1 &
echo $! > logs/sender.pid
echo "Started PID=$(cat logs/sender.pid). Логи: $HOME/tg_sender/logs/run.log"
ST
chmod +x start.sh

cat > stop.sh <<'SP'
#!/bin/bash
set -e
PIDFILE="$HOME/tg_sender/logs/sender.pid"
if [ -f "$PIDFILE" ]; then
  PID=$(cat "$PIDFILE"); kill "$PID" 2>/dev/null || true; rm -f "$PIDFILE"
  echo "Stopped PID $PID"
else
  pkill -f "python sender_full.py" || true
  echo "Stopped by pkill"
fi
SP
chmod +x stop.sh

cat > status.sh <<'SS'
#!/bin/bash
echo "PID:"; cat "$HOME/tg_sender/logs/sender.pid" 2>/dev/null || echo "no pid"
echo "---- last 50 lines of log ----"
tail -n 50 "$HOME/tg_sender/logs/run.log" 2>/dev/null || echo "no logs yet"
SS
chmod +x status.sh

say "10) Запустить рассылку сейчас? (y/n)"
read -r GO
if [[ "$GO" == "y" || "$GO" == "Y" ]]; then
  ./start.sh
fi

say "11) Автостарт при входе в macOS (launchd)? (y/n)"
read -r AUT
if [[ "$AUT" == "y" || "$AUT" == "Y" ]]; then
  PLIST="$HOME/Library/LaunchAgents/com.tgsender.autostart.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.tgsender.autostart</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>source $HOME/tg_env_tgsender/bin/activate && cd $HOME/tg_sender && python sender_full.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/tg_sender/logs/launchd_out.log</string>
  <key>StandardErrorPath</key><string>$HOME/tg_sender/logs/launchd_err.log</string>
</dict></plist>
PL
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
  launchctl start com.tgsender.autostart
  say "Автостарт включён. Перезагрузка — и сервис поднимется сам."
fi

say "Готово. Команды:
  cd ~/tg_sender
  ./start.sh    # запуск в фоне
  ./status.sh   # статус+логи
  ./stop.sh     # остановка
"
