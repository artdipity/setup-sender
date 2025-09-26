#!/bin/bash
set -e

echo "🚀 Установка авторассылки Telegram..."

# 1. Устанавливаем зависимости
echo "📦 Установка Homebrew (если нет)..."
if ! command -v brew &>/dev/null; then
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

echo "📦 Установка Python и pyenv..."
brew install pyenv git

pyenv install -s 3.10.13
pyenv global 3.10.13

# 2. Создаём проект
echo "📂 Создаю папку ~/tg_sender"
mkdir -p ~/tg_sender/groups ~/tg_sender/logs
cd ~/tg_sender

echo "🐍 Создаю виртуальное окружение..."
python3 -m venv ~/tg_env_tgsender
source ~/tg_env_tgsender/bin/activate

pip install --upgrade pip
pip install telethon apscheduler python-dotenv

# 3. Запрашиваем данные
echo "Введите API_ID (получите на https://my.telegram.org):"
read API_ID
echo "Введите API_HASH:"
read API_HASH
echo "Введите номер телефона (с +):"
read PHONE

cat <<EOF > .env
API_ID=$API_ID
API_HASH=$API_HASH
PHONE=$PHONE
EOF

echo "✅ Данные сохранены в .env"

# 4. Файл сообщения
cat <<'EOF' > message.txt
🎯 Авторассылка для MacBook — «Запустил и забыл!»

🔥 Готовое решение для рассылки в Telegram без лишних заморочек.

✅ Отправка каждый час / раз в сутки / раз в 3 суток.
✅ Группы предзаполнены, ничего настраивать не нужно.
✅ Работает в фоне на вашем Mac.

Запустил → забыл → сообщения сами уходят ⤵️

📩 @ocherry_manager
EOF

# 5. Списки групп
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

# 6. Сервисные скрипты
cat <<'EOF' > start.sh
#!/bin/bash
cd ~/tg_sender
source ~/tg_env_tgsender/bin/activate
python3 sender_full.py
EOF

cat <<'EOF' > stop.sh
#!/bin/bash
pkill -f sender_full.py || true
echo "⛔️ Остановлено"
EOF

cat <<'EOF' > status.sh
#!/bin/bash
ps aux | grep sender_full.py | grep -v grep
tail -n 20 ~/tg_sender/logs/run.log
EOF

chmod +x start.sh stop.sh status.sh

# 7. Основной скрипт
cat <<'EOF' > sender_full.py
import os, asyncio, random, datetime
from telethon import TelegramClient
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from dotenv import load_dotenv

load_dotenv()
API_ID = int(os.getenv("API_ID"))
API_HASH = os.getenv("API_HASH")
PHONE = os.getenv("PHONE")

async def send_message(client, group, text):
    try:
        await client.send_message(group, text)
        print(f"[{datetime.datetime.now()}] ✅ Sent -> {group}")
    except Exception as e:
        print(f"[{datetime.datetime.now()}] ❌ Error {group}: {e}")

async def job(client, filename, text):
    if not os.path.exists(filename): return
    with open(filename) as f:
        groups = [g.strip() for g in f if g.strip()]
    for g in groups:
        await send_message(client, g, text)
        await asyncio.sleep(random.randint(10, 30))

async def main():
    client = TelegramClient("tg_session", API_ID, API_HASH)
    await client.connect()

    if not await client.is_user_authorized():
        print("➡️ Введите код из Telegram (он придёт в приложение/SMS):")
        await client.send_code_request(PHONE)
        code = input("Код: ")
        try:
            await client.sign_in(PHONE, code)
        except Exception:
            password = input("Пароль 2FA (если включён, иначе Enter): ")
            await client.sign_in(password=password)

    print("✅ Авторизация выполнена.")

    with open("message.txt") as f:
        text = f.read().strip()

    scheduler = AsyncIOScheduler()
    scheduler.add_job(job, "interval", hours=1, args=[client, "groups/hourly.txt", text])
    scheduler.add_job(job, "interval", hours=24, args=[client, "groups/daily.txt", text])
    scheduler.add_job(job, "interval", hours=72, args=[client, "groups/3days.txt", text])
    scheduler.start()

    print("⏳ Рассылка запущена. Работает круглосуточно...")
    await asyncio.Event().wait()

if __name__ == "__main__":
    asyncio.run(main())
EOF

echo "🎉 Установка завершена!"
echo "➡️ Теперь запустите ./start.sh — введите код из Telegram один раз."
echo "После этого рассылка будет работать сама."
