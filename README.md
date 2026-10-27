# Valheim на VPS через Ansible

Репозиторий автоматизирует установку и настройку выделенного сервера Valheim на Linux VPS. Ansible-роль устанавливает Docker Engine и Compose, импортирует мир `purgatory` с серверными модами, настраивает резервное копирование и ежедневный рестарт. По умолчанию **игра не запускается**: подготовка и запуск выполняются отдельными командами.

## Мир и секреты

В `files/server-bundle.tar.gz.vault` лежат мир, серверные DLL, конфигурации модов и списки доступа для первоначальной установки. Пароль игры хранится отдельно в `group_vars/valheim/vault.yml`. Оба файла зашифрованы Ansible Vault, AES256.

Для расшифровки сохраните пароль Vault в локальном `.vault-pass`, который исключён из Git. Вместо `--vault-password-file .vault-pass` можно использовать `--ask-vault-pass` для интерактивного ввода. Пароль игры и пароль Vault — разные секреты. Локальный inventory и служебные каталоги `.venv` и `.local` также исключены из Git.

Blob используется только при первом импорте. Дальнейший игровой прогресс хранится на целевом сервере; автоматической синхронизации миров между серверами нет.

## Требования

- VPS с **x86_64 / amd64**, Debian 12/13 или Ubuntu 22.04/24.04/26.04, systemd, Python 3, SSH и sudo/root.
- Практический ориентир: 8 ГБ RAM и 20 ГБ свободного диска; лимит контейнера по умолчанию 6 ГБ. ARM VPS роль отклоняет.
- Машина запуска Ansible: Linux, macOS или WSL, Python **3.12+**. Обычный PowerShell не является поддерживаемым контроллером Ansible.

Роль устанавливает Docker Engine и Compose plugin из официального apt-репозитория. Для машины с уже установленным Docker задайте `valheim_install_docker: false`; Compose plugin должен быть не ниже 2.18. Старые конфликтующие пакеты `docker.io` / `containerd` роль автоматически не удаляет.

## Подготовка и запуск

На Linux/WSL, из каталога репозитория:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml -p .local/collections
cp inventory.example.yml inventory.yml
chmod 600 .vault-pass
```

В `inventory.yml` замените `203.0.113.10` на IP VPS, укажите SSH-пользователя и при необходимости ключ. Проверьте SSH и sudo. Если sudo требует пароль, добавляйте `--ask-become-pass` к командам ниже.

Подготовить каталоги, мир, моды, пароль и Compose **без запуска игры**, загрузки образа и установки задания рестарта:

```bash
ansible-playbook -i inventory.yml deploy.yml --vault-password-file .vault-pass
```

Запустить подготовленный сервер и включить ежедневный рестарт контейнера:

```bash
ansible-playbook -i inventory.yml deploy.yml --vault-password-file .vault-pass -e valheim_start=true
```

Первый запуск скачает игру и BepInEx через интернет и может занять несколько минут. Готовность проверяйте по игровому логу и подключением клиента. Ansible проверяет запуск контейнера, но не гарантирует успешную загрузку игры или модов.

Повторный запуск playbook **не импортирует мир заново**: маркер находится в `config/.valheim-bundle.json`. Если каталог уже заполнен, а маркера нет, импорт завершится ошибкой без перезаписи данных. Не удаляйте маркер для обновления работающего мира. `valheim_start=false` пропускает запуск; уже работающий сервер эта настройка не останавливает и установленный cron не отключает.

## Сеть

В сетевом firewall/security group провайдера разрешите входящие **UDP 2456–2457** на VPS. SSH оставьте доступным для администрирования. К VPS с публичным адресом игроки подключаются напрямую.

В Valheim используйте прямое подключение `IP_VPS:2456`. Steam-only, Crossplay отключён. Сервер скрыт из общего списка (`valheim_public: false`). Пароль игры можно посмотреть на контроллере:

```bash
ansible-vault view group_vars/valheim/vault.yml --vault-password-file .vault-pass
```

При публикации Docker-портов не полагайтесь только на UFW: Docker может обходить его правила. Ограничения доступа задавайте в firewall провайдера либо в `DOCKER-USER`; [подробности Docker](https://docs.docker.com/engine/install/ubuntu/#firewall-limitations).

## Что настроено

| Параметр | Значение |
|---|---|
| Мир | `purgatory`, полная папка формата Valheim 1.0 с chunk-файлами |
| Модификаторы мира | Сохранены из сейва, включая ресурсы ×2; роль их не переопределяет |
| Игроки | 10, в перенесённой конфигурации NPS |
| Сохранение | Каждые 10 минут |
| Бэкап | Каждый час в `:05`, ZIP в `/opt/valheim/config/backups`, хранение 7 дней |
| Рестарт | Контейнер ежедневно в 05:00 Europe/Chisinau, только если он уже работает |
| Обновления | Игра и BepInEx проверяются каждые 15 минут, обновление при отсутствии игроков |
| Остановка | Grace period 120 секунд |
| Данные | `/opt/valheim/config` — мир и моды; `/opt/valheim/data` — установка игры |

Рестарт выполняет host cron с проверкой времени Кишинёва, независимо от часового пояса VPS и перехода на летнее время. Встроенный рестарт образа отключён, чтобы не было двух расписаний. Вручную остановленный контейнер cron не запускает.

В blob включены **Plant Everything 1.21.3, Jötunn 2.30.2, NetworkPerformanceSystem 1.18.0 и ValheimCommunityPatch 0.37.0** с серверными настройками. Настройки и список DLL можно проверить после подготовки в `config/bepinex`.

Списки `adminlist.txt`, `permittedlist.txt`, `bannedlist.txt` импортируются из blob. Проверьте их перед запуском и при необходимости укажите нужные SteamID. Персонажи игроков остаются на их ПК.

Образ контейнера закреплён по digest в defaults роли. **Версия игры и BepInEx этим не фиксируется**: их скачивает сам образ. DLL модов закреплены содержимым blob; после обновления игры возможна необходимость обновить моды. [Документация образа](https://github.com/community-valheim-tools/valheim-server-docker).

## Изменение настроек

Добавляйте переменные под `valheim.vars` в `inventory.yml`, например:

```yaml
all:
  children:
    valheim:
      vars:
        valheim_server_name: "Purgatory Server"
        valheim_memory_limit: 6g
        valheim_install_docker: true
      hosts:
        gameserver:
          ansible_host: 203.0.113.10
          ansible_user: ubuntu
```

Пароль игры меняется через `ansible-vault edit group_vars/valheim/vault.yml --vault-password-file .vault-pass`, переменная `valheim_server_password`. Затем повторите запуск с `-e valheim_start=true`: контейнер будет пересоздан с новым паролем. Имя мира должно совпадать с именем внутри blob.

Для смены пароля Vault выполните `ansible-vault rekey` **для обоих** файлов, указав старый и новый password file. Локальный inventory и ключи не коммитьте.

## Управление на VPS

```bash
cd /opt/valheim
sudo docker compose -p valheim ps
sudo docker compose -p valheim logs --tail 150 -f valheim
sudo docker compose -p valheim stop --timeout 120 valheim
sudo docker compose -p valheim start valheim
```

Не удаляйте каталоги `config` и `data`. Локальные бэкапы защищают от ошибки в игре, но их стоит копировать за пределы VPS, чтобы пережить потерю самого диска.

## Обновить исходный blob

Для нового экспорта с Linux-сервера сначала штатно остановите **источник**, чтобы скопировать согласованное сохранение.

```bash
python -m tools.pack_bundle /path/to/stopped-server/config --world purgatory --password-file .vault-pass
```

Инструмент сохраняет полную папку мира, конфиги, активные плагины и списки доступа. Проверяет наличие завершённых поколений сейва, отвергает symlink и опасные пути. Открытый tar на диск не записывается. Серверный пароль хранится в отдельном Vault-файле и при упаковке не меняется.

Обновлённый blob используется только для **новых** установок. Для замены уже импортированного мира требуется отдельная штатная остановка и резервное копирование старого `config`, затем импорт в пустой каталог. Существующий мир роль автоматически не заменяет.

## Проверки

```bash
python -m unittest discover -s tests -v
ansible-playbook -i localhost, deploy.yml --syntax-check
python -m tests.smoke
```

Последняя команда требует отдельной Linux-машины с Docker Compose и sudo без пароля. Она работает в `/tmp/valheim-ansible-smoke` (каталог должен отсутствовать), использует синтетический Vault blob, проверяет повторный импорт, сохранение нового прогресса, отказ при наличии существующего мира и отсутствие запущенного/созданного контейнера. Для неё ключ настоящего мира не нужен. Тесты также настроены в GitHub Actions.

Ansible `--check` на чистом VPS не заменяет реальную подготовку: отсутствующие пакеты и каталоги не создаются, импорт tar.gz в этом режиме пропускается. Реальное подключение игроков проверяется после явного запуска.
