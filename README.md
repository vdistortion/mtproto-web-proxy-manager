# MTProto Web Proxy Manager

Bash-скрипт для управления прокси Telegram на [telego](https://github.com/Scratch-net/telego). Один Docker-контейнер обслуживает всех пользователей; Caddy завершает TLS для WEB-прокси.

Скрипт настраивает прокси, управляет секретами пользователей, выводит ссылки и QR-коды, экспортирует и восстанавливает конфигурацию.

## Схема подключения

```
Интернет
  │
  ├─ :443 ──► Caddy (caddy-docker-proxy, сеть caddy)
  │             └─ https://<домен> ──► telego:8080 (WEB-прокси, websocket)
  │                   418/419 ──► сайт-заглушка
  │
  └─ :8443 ──► telego (MTProxy: ee / dd, внутри контейнера :4433)
                  ├─ клиенты ──► Telegram (Middle-End → дата-центры)
                  └─ пробы  ──► Caddy ──► сайт-заглушка
```

- [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy) слушает порты 80/443, выпускает сертификат и настраивает маршруты по лейблам контейнеров.
- telego принимает HTTP от Caddy на порту `8080` в Docker-сети `caddy`. Этот порт не публикуется на хосте. Публичный порт WEB-прокси фиксирован протоколом: `443`.
- Для MTProxy используется отдельный публичный порт, по умолчанию `8443`. FakeTLS (`ee`) воспроизводит TLS-профиль сайта на заданном домене; нераспознанные подключения перенаправляются на Caddy.
- При открытии домена в браузере Caddy отдаёт заглушку или настроенный статический сайт.

## Требования

- Linux, Bash 4 или новее, права `root`/`sudo`
- Docker Engine на этом сервере и Docker Compose v2 или новее
- `curl`, `ss` (`iproute2`), `flock` (`util-linux`), GNU coreutils и `tar`
- Домен с A-записью, указывающей на IP сервера
- Свободный TCP-порт для MTProxy (не 80/443 — они заняты Caddy)
- Caddy с caddy-docker-proxy во внешней сети `caddy`

Если Caddy ещё не настроен, минимальный комплект:

```bash
docker network create caddy --ipv6
```

`compose.yaml` Caddy:

```yaml
services:
  caddy:
    image: lucaslorentz/caddy-docker-proxy:2.13.1-alpine
    container_name: caddy
    restart: unless-stopped
    ports:
      - '80:80'
      - '443:443/tcp'
      - '443:443/udp'
    environment:
      CADDY_INGRESS_NETWORKS: caddy
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - caddy_data:/data
    networks:
      - caddy

volumes:
  caddy_data:

networks:
  caddy:
    external: true
```

```bash
docker compose up -d
```

Пример общей инфраструктуры с Caddy — в [vps-infra](https://github.com/vdistortion/vps-infra).

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/vdistortion/mtproto-web-proxy-manager/main/mtproto-manager.sh | sudo bash -s install
```

Установщик проверяет Docker и сеть `caddy`, создаёт `/etc/mtproto-manager` и предлагает выполнить настройку. Caddy устанавливается отдельно. `qrencode` — необязательная зависимость для QR-кодов.

Для проверки ветки `telego` устанавливайте скрипт из файла:

```bash
curl -fsSL https://raw.githubusercontent.com/vdistortion/mtproto-web-proxy-manager/telego/mtproto-manager.sh \
  -o mtproto-manager-telego.sh
sudo bash ./mtproto-manager-telego.sh install
```

Запуск из файла устанавливает именно скачанную версию. При `curl | bash` самоустановка загружает `main`, независимо от ветки исходного URL. Если прокси уже настроен, повторную настройку можно пропустить.

## Настройка

Первый `setup` создаёт пользователя `user1` и выводит его ссылки:

```bash
sudo mtproto-manager setup proxy.example.com 8443
sudo mtproto-manager add-user alice
sudo mtproto-manager show-user alice
```

Повторный `setup` сохраняет пользователей, `carrier`, остальные ручные настройки и дополнительные переменные `.env`. Он обновляет домен, адреса прослушивания и доверенные подсети Caddy. При ошибке записи или запуска прежние файлы и состояние контейнера восстанавливаются.

Управляющие команды используют общую блокировку: вторая команда завершается с сообщением, если первая ещё работает.

## Команды

| Команда                                | Описание                                      |
| -------------------------------------- | --------------------------------------------- |
| `mtproto-manager install`               | Установить скрипт и подготовить окружение      |
| `mtproto-manager setup [домен] [порт]`   | Настроить домен и публичный MTProxy-порт        |
| `mtproto-manager add-user <имя>`        | Создать пользователя                          |
| `mtproto-manager remove-user <имя>`     | Удалить пользователя                          |
| `mtproto-manager list-users`            | Список всех пользователей                     |
| `mtproto-manager show-user <имя>`       | Ссылки пользователя и QR-код                   |
| `mtproto-manager block-user <имя>`      | Заблокировать, сохранив секрет                 |
| `mtproto-manager unblock-user <имя>`    | Разблокировать                                |
| `mtproto-manager start`                 | Запустить прокси                              |
| `mtproto-manager stop`                  | Остановить прокси                             |
| `mtproto-manager restart`               | Перезапустить прокси                          |
| `mtproto-manager status`                | Статус контейнера и пользователей             |
| `mtproto-manager show-traffic`          | Трафик контейнера (`docker stats`)             |
| `mtproto-manager update`                | Обновить образ telego и пересоздать контейнер  |
| `mtproto-manager export`                | Экспорт конфигурации (tar.gz)                  |
| `mtproto-manager import <файл>`         | Импорт конфигурации                           |
| `mtproto-manager help`                  | Полный список команд                          |
| `mtproto-manager uninstall`             | Полностью удалить скрипт и данные              |

Без аргументов — интерактивное меню.

## Пользователи и ссылки

Имя пользователя может содержать латинские буквы, цифры, `_` и `-`. Пользователь хранится как строка `имя = "секрет"` в секции `[secrets]`. telego читает секреты при запуске: добавление, удаление и изменение блокировки перезапускают общий контейнер и прерывают соединения всех пользователей.

`add-user` и `show-user` выводят четыре ссылки с одним базовым секретом:

| Вариант      | Публичный порт       | Транспорт                         | Секрет в ссылке              |
| ------------ | -------------------- | --------------------------------- | ---------------------------- |
| WEB          | `443`                | HTTPS/WSS                         | Базовый секрет               |
| WEB (dd)     | `443`                | HTTPS/WSS, padding внутри MTProxy | `dd` + базовый секрет        |
| MTProxy (ee) | MTProxy-порт сервера | FakeTLS                           | `ee` + секрет + домен в hex  |
| MTProxy (dd) | MTProxy-порт сервера | MTProxy с padding, без FakeTLS     | `dd` + базовый секрет        |

WEB требует поддержки WEB-прокси в клиенте Telegram. По умолчанию используется WebSocket (`carrier = "websocket"`). Если WEB не поддерживается или не подключается, используйте MTProxy (`ee` или `dd`). FakeTLS имитирует TLS, в отличие от HTTPS у WEB. Padding добавляет случайные байты к MTProxy-пакетам, но не заменяет TLS-маскировку.

QR-код ведёт на обычный WEB-вариант и выводится при наличии `qrencode`. В `list-users` эта ссылка показана только у активных пользователей.

Подробнее: [WEB-прокси](https://github.com/Scratch-net/telego/blob/main/docs/web-proxy.md), [ee/dd в telego](https://github.com/Scratch-net/telego#protocol-modes) и [padding в MTProxy](https://github.com/TelegramMessenger/MTProxy#random-padding).

### Блокировка и удаление

`block-user` комментирует строку секрета, `unblock-user` снимает комментарий. При удалении или блокировке перестают работать все четыре ссылки пользователя.

Удалить или заблокировать последнего активного пользователя нельзя: telego требует хотя бы один секрет.

## Конфигурация

| Файл                                | Назначение                                         |
| ----------------------------------- | -------------------------------------------------- |
| `/etc/mtproto-manager/config.toml`   | Конфиг telego, включая секцию `[secrets]`           |
| `/etc/mtproto-manager/compose.yaml`  | Контейнер telego, лейблы Caddy и лимит Docker-логов  |
| `/etc/mtproto-manager/.env`          | `DOMAIN` и `MTPROXY_PORT`                          |

Пример секции пользователей:

```toml
[secrets]
alice = "0123456789abcdef0123456789abcdef"
# bob = "fedcba9876543210fedcba9876543210"   # заблокирован
```

Команды управления пользователями проверяют запуск telego после правки и откатывают изменение при ошибке. Для ручных изменений `config.toml` выполните `mtproto-manager restart`. Параметры описаны в [примере конфигурации telego](https://github.com/Scratch-net/telego/blob/main/config.example.toml).

Скрипт доверяет `X-Forwarded-For` из всех подсетей сети `caddy`. Подключённые к ней контейнеры должны быть доверенными: они могут обращаться к приватному WEB-порту и передавать адрес клиента.

### Экспорт и импорт

`export` создаёт архив в текущем каталоге, не перезаписывая существующие файлы. Архив содержит секреты пользователей и имеет права `600`; каталог конфигурации — `700`.

`import` восстанавливает конфигурацию и запускает прокси. Архив только с `config.toml` допустим на уже настроенном сервере. Символические и жёсткие ссылки, посторонние пути и повторяющиеся файлы отклоняются. При ошибке возвращаются прежние файлы и состояние контейнера.

Импортируйте только доверенные резервные копии: `compose.yaml` определяет запускаемые контейнеры, подключения каталогов и права.

## Сайт-заглушка

При открытии `https://<домен>` в браузере Caddy отдаёт HTML-заглушку из лейбла в `compose.yaml`:

```yaml
caddy.reverse_proxy.handle_response.respond: '"<!doctype html>…" 200'
```

Чтобы поменять текст, отредактируйте лейбл и пересоздайте контейнер: `docker compose up -d --force-recreate telego` из `/etc/mtproto-manager`.

### Статический сайт

Для сайта с `GET`/`HEAD` без тела, работающего в контейнере в сети `caddy`, замените блок `labels` на следующий. Обычные запросы (`418`) уходят на сайт. Запросы WEB-прокси с неверными данными доступа (`419`) получают статический ответ без обращения к сайту.

Этот рецепт не подходит для форм, загрузки файлов и API сайта: `request_buffers` в Caddy не сохраняет тело для второго `reverse_proxy` в `handle_response`. HTTP/1.1-запросы с `Transfer-Encoding: chunked` telego тоже не принимает. Запросы самого WEB-прокси обрабатывает telego, они не отправляются на сайт.

```yaml
    labels:
      caddy: "${DOMAIN}"
      caddy.reverse_proxy: "{{upstreams 8080}}"
      caddy.reverse_proxy.request_buffers: "16MB"
      # 418 — на сайт только GET/HEAD без тела
      caddy.reverse_proxy.@site.status: "418"
      caddy.reverse_proxy.handle_response_0: "@site"
      caddy.reverse_proxy.handle_response_0.@read_only.method: "GET HEAD"
      caddy.reverse_proxy.handle_response_0.@read_only.expression: "{http.request.header.Content-Length} in ['', '0']"
      caddy.reverse_proxy.handle_response_0.handle_0: "@read_only"
      caddy.reverse_proxy.handle_response_0.handle_0.reverse_proxy: "site:80"
      caddy.reverse_proxy.handle_response_0.handle_1.respond: '"Method Not Allowed" 405'
      # 419 — неверные данные доступа к WEB-прокси: ответ без обращения к сайту
      caddy.reverse_proxy.@sanitized.status: "419"
      caddy.reverse_proxy.handle_response_1: "@sanitized"
      caddy.reverse_proxy.handle_response_1.respond: '"Not Found" 404'
```

`site:80` — имя и порт контейнера сайта в сети `caddy`. После правки выполните `docker compose up -d --force-recreate telego` из `/etc/mtproto-manager`. Все запросы к домену должны сначала проходить через telego: маршруты напрямую на сайт могут раскрыть ему данные доступа к WEB-прокси.

## Обновление и удаление

```bash
sudo mtproto-manager update      # docker compose pull + пересоздание контейнера
sudo mtproto-manager uninstall   # контейнер, конфигурация и скрипт
```

По умолчанию используется `scratchnet/telego:v0.6`. Для другой версии измените `image:` сервиса `telego` в `compose.yaml` и выполните `update`. Генерация секретов также использует образ из Compose.

Сам скрипт обновляется повторным `install`. `uninstall` не удаляет Caddy и сеть `caddy`.

## Проверка

- `./tests/run.sh` — локальные тесты секретов, настройки и отката, импорта/экспорта, ссылок, QR, установки через stdin, блокировки команд и меню. Docker-демон не нужен; при наличии Compose проверяется сгенерированный YAML.
- `./tests/docker.sh` — запуск telego, пользователи, обновление образа, bind-mount конфигурации и восстановление после неудачного импорта. Использует временные контейнер и сеть; MTProxy-порт открыт только на `127.0.0.1`.
- `./tests/caddy.sh` — заглушка, рецепт статического сайта из README, ответы `418`/`419`, WEB-сессии и WebSocket с обычными и `dd`-секретами. Использует отдельный префикс лейблов и локальный HTTP-порт.

Docker-тесты могут скачивать образы. Они удаляют свои ресурсы после завершения и не меняют рабочий Caddy. Выпуск публичного сертификата и подключение клиента Telegram не проверяются.
