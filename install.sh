#!/bin/bash
set -e

echo "🚀 Установка авторассылки Telegram..."

# 1. Установка Homebrew (если нет)
if ! command -v brew &>/dev/null; then
  echo "📦 Устанавливаю Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# 2. Установка pyenv и Python
if ! command -v pyenv &>/dev/null; then
  echo "📦 Устанавливаю pyenv..."
  brew install pyenv
fi

PYTHON_VERSION=3.10.13
eval "$(pyenv init -)"
pyenv install -s $PYTHON_VERSION
pyenv virtualenv -f $PYTHON_VERSION tg_env_tgsender || true
pyenv local tg_env_tgsender

# 3. Установка зависимостей
pip install --upgrade pip
pip install telethon apscheduler python-dotenv

# 4. Создаём структуру папок
mkdir -p ~/tg_sender/groups ~/tg_sender/logs
cd ~/tg_sender

# 5. Создаём .env (данные пользователь введёт сам)
cat <<'EOF' > .env
API_ID=
API_HASH=
PHONE=
EOF

# 6. Список групп — каждый час
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
https://t.me/disneydesk
https://t.me/Workers_Desk
https://t.me/camweboard
https://t.me/goatsof
https://t.me/OTC_ADULT
https://t.me/apreeteam_desk
https://t.me/adulthubdoska
EOF

# 7. Список групп — раз в сутки
cat <<'EOF' > groups/daily.txt
https://t.me/adult_18_board
https://t.me/onlyfanspromoroom
https://t.me/Adult_platform
https://t.me/OnlyBulletin
https://t.me/adult_desk
EOF

# 8. Список групп — раз в 72 часа
cat <<'EOF' > groups/3days.txt
https://t.me/CardoCrewDesk
https://t.me/CardoCrewDeskTraffic
https://t.me/adszavety
EOF

# 9. Создаём message.txt (дефолтный текст)
cat <<'EOF' > message.txt
🎯 Авторассылка для MacBook — «Запустил и забыл!»
EOF

# 10. Скачиваем основной скрипт
curl -s -o sender_full.py https://raw.githubusercontent.com/artdipity/setup-sender/main/sender_full.py

# 11. Скрипты управления
cat <<'EOF' > start.sh
#!/bin/bash
cd ~/tg_sender
source $(pyenv root)/versions/tg_env_tgsender/bin/activate
python sender_full.py
EOF

cat <<'EOF' > stop.sh
#!/bin/bash
pkill -f sender_full.py || true
EOF

cat <<'EOF' > status.sh
#!/bin/bash
ps aux | grep sender_full.py | grep -v grep
EOF

chmod +x start.sh stop.sh status.sh

echo "✅ Установка завершена!"
echo "➡️ Теперь:"
echo "1) Открой файл .env и впиши API_ID, API_HASH, PHONE"
echo "2) Запусти ./start.sh"
echo "3) Введи код из Telegram (и пароль 2FA, если есть)"
