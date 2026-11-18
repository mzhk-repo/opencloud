# План реалізації: OpenCloud (PosixFS), Фаза 1 — Сховище

*Основа: `SPEC.md` · 15.11.2026 · Без коду імплементації*

## 0. Припущення та відхилення від SPEC

План враховує правки з рев'ю SPEC. Кожну можна відхилити; зачеплені задачі вказані в дужках.

- **Образ і версія:** Production-гілка, образ `opencloudeu/opencloud`, тег 7.2.5 (наявність підтверджена власником проєкту на Docker Hub); документація гілки 7.2, rolling-образ не використовується (1.1).
- **PosixFS у non-collaborative режимі:** прямі зміни FS і restore виконуються лише при зупиненому сервісі (1.3, 6.2, 6.3).
- **Розкладка на хості:** `/srv/opencloud/data` → `/var/lib/opencloud`; конфіг `opencloud.yaml` — один версіонований Swarm Secret у `/etc/opencloud/opencloud.yaml` (1.3, 4.1).
- **Entra ID, MS 365 Education A1:** ізольований PoC перевірив мапінг GUID Security groups із клейму `groups` на ролі admin/user; користувач без відповідної групи не ввійшов, але його профіль міг створитися до відмови. Остаточне масове призначення співробітників і безпекові умови залишаються відкритими (2.2).
- **Групи з OIDC:** власник обрав офіційний образ без власного патча і прийняв штатну синхронізацію при JIT: GUID-групи можуть створюватися локально, а членства, відсутні в клеймі, видаляються. Ручне членство видалено під час PoC; відсутній клейм може означати порожній список. Самостійне вимкнення синхронізації запитано в [upstream issue #4058](https://github.com/opencloud-eu/opencloud/issues/4058); запропонований там перемикач у 7.2.5 не існує.
- **Секрети:** SOPS → один Swarm Secret; `reconcile-sops-secrets.sh` з хешованими іменами лишається за стандартом (4.1). `IDM_ADMIN_PASSWORD` для входу не використовується; break-glass — другий admin-акаунт в Entra.
- **Ресурси:** без жорсткого ліміту 2560M і без CPU-ліміту; 70% RAM хоста — орієнтир для production (5.1). Для dev власник проєкту обрав мінімальний ліміт; конкретне значення потрібно визначити та перевірити на практиці.
- **Бекап:** сервіс зупиняється на час `borg create` (`trap EXIT` повертає його), без прапорців `--xattrs` / `--acls`; restore — процедура в runbook без скрипта, невдалий restore лишає сервіс зупиненим (6.2, 6.3).
- **Скрипти:** п'ять замість десяти — `preflight-host`, `init-volumes`, `reconcile-sops-secrets`, `deploy-orchestrator-swarm`, `backup`.
- **Поза Фазою 1:** CSP/`frame-ancestors` і AC-5 для Drupal (переходять у Фазу 2), desktop/mobile-клієнти, міграція з Google Drive. Штатне використання груп із токена входить до поточного PoC.
- **Немає коду застосунку і production Dockerfile:** використовується офіційний образ (`build_and_push_docker: false`).
- **`[перевірити]`** — гіпотеза, яку підтверджує PoC; не вважати фактом.

## 1. Стратегія імплементації та Definition of Done (DoD)

**Стратегія.** Спочатку один контейнер `opencloud` локально (вбудований IdP): перевіряємо PosixFS і фіксуємо розкладку стану. Одразу після цього — PoC Entra ID з ролями, бо це найбільший невідомий ризик; Spaces, публічні посилання й TUS перевіряються вже на реальних Entra-профілях. Далі SOPS-секрети, Swarm-стек на dev-ноді через оркестратор, а наприкінці — бекапи, runbook і підключення до shared CI/CD.

**Глобальний DoD** (для кожної задачі):

- bash-скрипти: `set -euo pipefail`, `shellcheck` без попереджень, ідемпотентність (2-й запуск поспіль → `exit 0`), негативні сценарії завершуються ненульовим кодом із зрозумілим повідомленням;
- YAML проходить `yamllint`; `docker compose config -q` / `docker stack config` без помилок;
- немає захардкоджених секретів; значення секретів не потрапляють у git, логи та мапінг-файли;
- `.env.example` синхронізовано зі змінними; `docs/AI_CONTEXT.md` оновлюється лише після суттєвих архітектурних змін;
- кожен скрипт має шапку-коментар: призначення, категорія (1а / 1б / 2), приклад запуску. З цих шапок у задачі 6.5 збирається `docs/scripts_runbook.md`.

## Фаза 1: Ініціалізація та локальне середовище

### Задача 1.1: Скелет репозиторію та початковий AI\_CONTEXT

- **Ціль:** Репозиторій має узгоджену структуру, лінтери та початковий `docs/AI_CONTEXT.md`.
- **Залежності:** Немає
- **Кроки реалізації:**
  1. Створити `scripts/`, `config/`, `docs/`, `.github/workflows/` (workflow додається в 6.6).
  2. Додати `.gitignore` (plaintext env, `.local/`), `.editorconfig`, `.yamllint.yml`, `.shellcheckrc`.
  3. Зафіксувати образ і версію: репозиторій `opencloudeu/opencloud` (Production), тег 7.2.5 як `OPENCLOUD_IMAGE` і `OPENCLOUD_IMAGE_TAG` у `.env.example`. Rolling-образ `opencloudeu/opencloud-rolling` не використовувати; усі змінні звіряти з документацією гілки 7.2, а не з `/docs/next/`.
  4. Написати `README.md` (призначення, структура, локальний запуск) і `docs/AI_CONTEXT.md` (до одного екрана): архітектура (1 контейнер, без БД), розкладка хоста `/srv/opencloud/data`, non-collaborative PosixFS, категорії скриптів 1а / 1б / 2, правило «секрети лише через SOPS», команди перевірки.
- **Файли / Директорії:** `.gitignore`, `.editorconfig`, `.yamllint.yml`, `.shellcheckrc`, `.env.example`, `README.md`, `docs/AI_CONTEXT.md`
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] Структура каталогів створена, лінтери налаштовані
  - [ ] Образ Production і тег зафіксовані, `latest` і rolling-образ ніде не використовуються
  - [ ] `AI_CONTEXT.md` ≤ \~60 рядків і містить правила категорій скриптів
- **Перевірка (Validation):**

  ```bash
  yamllint .
  grep -n 'OPENCLOUD_IMAGE' .env.example
  ! grep -rn ':latest' . --include='*.yml' --include='*.example'
  ! grep -rn 'opencloud-rolling' . --include='*.yml' --include='*.example'
  wc -l docs/AI_CONTEXT.md
  ```

### Задача 1.2: Preflight хоста (Категорія 1а)

- **Ціль:** Скрипт перевіряє локальну готовність файлової системи ноди до PosixFS без доступу до секретів.
- **Залежності:** 1.1
- **Кроки реалізації:**
  1. Створити `scripts/preflight-host.sh <data-path>` (типово `/srv/opencloud/data`): каталог існує; ФС — XFS або ext4; запис дозволений; щонайменше 10 GiB вільного місця для тестового файлу (для робочих даних потрібен додатковий запас); `user.*` xattr працює (тимчасовий файл у каталозі, який видаляється через `trap`). Окрім цього тимчасового файлу, скрипт нічого не змінює.
  2. Вивести рекомендоване значення `OPENCLOUD_MEM_LIMIT` = 70% від `MemTotal` (інформаційно, для `env.<env>.enc`).
  3. Не читати env-файли та SOPS і не звертатися до Docker. Мітку Swarm-ноди `storage=primary` перевіряє оркестратор (5.3): `docker node inspect` працює лише на manager, а storage-нода може бути worker.
- **Файли / Директорії:** `scripts/preflight-host.sh`
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] На ФС з `user_xattr` скрипт завершується з кодом 0 і друкує рекомендацію пам'яті
  - [ ] Неіснуючий шлях або ФС без xattr → ненульовий код і зрозуміле повідомлення
  - [ ] Повторний запуск не залишає тимчасових файлів
- **Перевірка (Validation):**

  ```bash
  shellcheck scripts/preflight-host.sh
  ./scripts/preflight-host.sh /srv/opencloud/data; echo $?
  ./scripts/preflight-host.sh /nonexistent; echo $?   # очікуємо != 0
  ```

### Задача 1.3: Локальний стенд і фіксація розкладки стану

- **Ціль:** Один контейнер `opencloud` піднімається локально з PosixFS, а розкладка стану зафіксована (раніше окрема задача 2.1).
- **Залежності:** 1.1
- **Кроки реалізації:**
  1. `docker-compose.yml`: один сервіс (образ з 1.1); bind mount `./.local/opencloud/data` → `/var/lib/opencloud` (дзеркало `/srv/opencloud/data`); `STORAGE_USERS_DRIVER=posix`; `STORAGE_USERS_ID_CACHE_STORE=nats-js-kv`; без `STORAGE_USERS_POSIX_WATCH_FS` (non-collaborative).
  2. Одноразово виконати `opencloud init` у тимчасовому контейнері → `opencloud.yaml`. Локально файл лежить у `.local/` (поза git) і монтується в `/etc/opencloud/opencloud.yaml` лише для читання. Для dev і prod `init` виконується один раз на середовище й ніколи не повторюється над наявними даними (4.1).
  3. У README зазначити: Docker Desktop (macOS/Windows) не підходить для xattr на bind mount — потрібен Linux-хост або dev-нода.
  4. Після старту й завантаження тестового файлу записати в `docs/AI_CONTEXT.md` розділ «State layout» (≈5 рядків): де файли користувачів, де idm, де NATS KV, чи перебудовується індекс, де конфіг і як відновлюються секрети. Звірити з фактичними каталогами `/var/lib/opencloud` `[перевірити]`; якщо під час роботи нічого не пишеться в `/etc/opencloud`, окремий host-каталог `/srv/opencloud/config` не потрібен — конфіг відновлюється деплоєм зі SOPS.
- **Файли / Директорії:** `docker-compose.yml`, `.env.example`, `README.md`, `docs/AI_CONTEXT.md`
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] Контейнер запущений, UI відкривається, вхід через вбудований IdP працює
  - [ ] Завантажений через UI файл видно на хості, `getfattr` показує `user.oc.id`
  - [ ] «State layout» покриває шість категорій: конфіг, файли користувачів, idm, NATS KV, пошукові індекси, секрети
  - [ ] Жодних секретів у git
- **Перевірка (Validation):**

  ```bash
  docker compose config -q && docker compose up -d && docker compose ps
  curl -ksS https://localhost:9200/.well-known/openid-configuration | head -c 200
  getfattr -d -m 'user.oc.*' <шлях-до-завантаженого-файлу>
  docker compose exec opencloud ls -la /var/lib/opencloud /etc/opencloud
  grep -n 'State layout' docs/AI_CONTEXT.md
  ```

**Quality Gate фази 1:**

- `preflight-host.sh` проходить на цільовій ноді й падає на некоректному шляху
- Локальний контейнер стартує, `user.oc.id` видно на хості, розкладка стану зафіксована
- `AI_CONTEXT.md`, образ Production і тег 7.2.x зафіксовані

## Фаза 2: Автентифікація Entra ID (PoC)

Найбільший невідомий ризик перевіряється першим: усе подальше тестування йде на реальних Entra-профілях. Запит адміну Entra на App Registration і тестові акаунти слід подати в перший день, паралельно з Фазою 1.

### Задача 2.1: PoC Entra ID напряму, без Keycloak (AC-1)

- **Ціль:** Користувач тенанту входить через Entra й автоматично отримує профіль; клейм ідентифікації обрано.
- **Залежності:** 1.3
- **Кроки реалізації:**
  1. Створити App Registration (single tenant): платформа SPA, redirect URI `https://<domain>/`, `/oidc-callback.html`, `/oidc-silent-redirect.html`; експонувати власний API scope і задати v2-токени `[перевірити: потрібно для валідації access-токена як JWT]`.
  2. Попросити в адміна Entra тестові акаунти: `staff-manager`, `staff-editor`, `staff-viewer`, `staff-outsider`, `admin`, `admin-2` (break-glass) і `student`.
  3. Вимкнути вбудований IdP (`OC_EXCLUDE_RUN_SERVICES=idp`) і задати `OC_OIDC_ISSUER`, `PROXY_OIDC_ACCESS_TOKEN_VERIFY_METHOD`, `PROXY_AUTOPROVISION_ACCOUNTS=true`, `GRAPH_USERNAME_MATCH=none`, `PROXY_USER_OIDC_CLAIM` / `PROXY_USER_CS3_CLAIM`. Додати власний API scope до `WEBFINGER_WEB_OIDC_CLIENT_SCOPES`, щоб клейм ролі потрапляв в access token `[перевірити]`.
  4. Обрати стабільний клейм ідентифікації (кандидати: `oid`, `preferred_username`, `email`); не будувати вимог на назві каталогу `spaces/personal/<id>` `[перевірити]`.
  5. **Gate:** якщо без Keycloak валідація токена неможлива — зупинитися й ескалювати рішення (Keycloak виходить за KISS-межі Фази 1).
- **Файли / Директорії:** `docker-compose.yml`, `.env.example`, `docs/AI_CONTEXT.md`
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] Новий staff-акаунт входить без ручного створення профілю (AC-1)
  - [ ] Повторний вхід не створює дубль профілю (за логами)
  - [ ] Обраний клейм і перелік змінних занесені в `AI_CONTEXT.md`
- **Перевірка (Validation):**

  ```bash
  curl -sS https://login.microsoftonline.com/<tenant-id>/v2.0/.well-known/openid-configuration | head -c 200
  docker compose up -d && docker compose logs --since 5m opencloud | grep -iE 'oidc|autoprovision|error'
  ```

### Задача 2.2: Ролі admin / staff і фільтр студентів (Education A1)

- **Ціль:** Увійти може лише співробітник або адміністратор; студент отримує відмову.
- **Залежності:** 2.1
- **Поточне рішення:** використовувати `groups` з GUID Entra Security groups для мапінгу ролей і штатну синхронізацію членств у 7.2.5; сценарій App Roles нижче збережено як попередній PoC. Відсутній клейм груп не вимикає синхронізацію. Поведінку при понад 200 групах, перевірку `aud`, незмінний ідентифікатор і вплив на доступ потрібно перевірити до виходу за межі локального PoC.
- **Кроки реалізації:**
  1. В App Registration створити App Roles зі значеннями `opencloudAdmin` (admin) і `opencloudUser` (staff). Це стандартні значення мапінгу OpenCloud, тож власний `proxy.yaml` може не знадобитися `[перевірити]`.
  2. Увімкнути `PROXY_ROLE_ASSIGNMENT_DRIVER=oidc` і `GRAPH_ASSIGN_DEFAULT_USER_ROLE=false`. Користувач без відповідного значення клейму ролі входити не повинен (за документацією — помилка в логах і відмова). Нестандартний мапінг, якщо знадобиться, — статичний `config/proxy.yaml` у репозиторії.
  3. Призначення ролей: на ліцензії Education A1 призначення App Role групам і динамічні групи за `companyName` можуть бути недоступні (потрібен Entra ID P1) `[перевірити ліцензію]`. Тоді адмін Entra призначає роль `staff` пакетно скриптом за списком співробітників, а `admin` — двом особам.
  4. **Fallback:** якщо фільтр за ролями не працює (клейм не в токені або пакетне призначення неможливе), переходимо на авторизацію лише для користувачів, створених в OpenCloud вручну: `PROXY_AUTOPROVISION_ACCOUNTS=false`, акаунти створює адміністратор, зіставлення за клеймом з 2.1 `[перевірити]`. Обраний режим і причину записати в `AI_CONTEXT.md`.
  5. Break-glass — другий акаунт Entra з роллю admin. `IDM_ADMIN_PASSWORD` для входу не використовується: при зовнішньому IdP форми локального логіну немає.
- **Файли / Директорії:** `config/proxy.yaml` (за потреби), `docker-compose.yml`, `.env.example`, `docs/AI_CONTEXT.md`
- **Критерії прийняття (Acceptance Criteria):**
  - [x] Акаунт `admin` створює Space і призначає Manager (підтверджено користувачем на ізольованому PoC)
  - [x] Акаунт `staff-*` входить і має базову роль user (підтверджено користувачем на ізольованому PoC)
  - [x] Акаунт `student` не входить (підтверджено користувачем на ізольованому PoC)
  - [ ] Обраний режим (ролі чи ручна реєстрація) задокументований
- **Перевірка (Validation):**

  ```bash
  yamllint config/proxy.yaml   # якщо файл існує
  docker compose logs --since 10m opencloud | grep -iE 'role|forbidden|error'
  # вручну: вхід admin, staff-manager, student; admin створює Space і додає staff-користувача
  ```

**Quality Gate фази 2:**

- AC-1 пройдено на реальному Entra-тенанті без Keycloak (або ескалацію прийнято)
- Студентський акаунт не входить; режим фільтрації (ролі чи ручна реєстрація) зафіксований
- Адмін-шлях і break-glass акаунт працюють

## Фаза 3: Ядро MVP (Spaces, файли, публічні посилання, TUS)

Усе перевіряється на реальних Entra-профілях із Фази 2 (тестові акаунти `staff-manager`, `staff-editor`, `staff-viewer`, `staff-outsider`).

### Задача 3.1: Spaces і ролі (Сценарій 1, без Entra)

- **Ціль:** Проєктний Space з ролями Manager / Editor / Viewer працює, чужі Spaces недоступні за замовчуванням.
- **Залежності:** 2.2
- **Кроки реалізації:**
  1. Акаунт `admin` створює проєктний Space із квотою.
  2. Призначити ролі Manager / Editor / Viewer акаунтам `staff-manager`, `staff-editor`, `staff-viewer`; перевірити, що Manager додає й видаляє учасників та бачить журнал дій `[перевірити, що журнал доступний у 7.2]`.
  3. Перевірити ізоляцію: `staff-outsider` не бачить Space.
  4. Занести ручний чекліст у `docs/AI_CONTEXT.md` (пізніше переїде в runbook).
- **Файли / Директорії:** `docs/AI_CONTEXT.md`
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] Manager керує складом Space
  - [ ] Viewer не може писати чи видаляти; Editor може
  - [ ] Користувач без ролі в Space його не бачить
- **Перевірка (Validation):**

  ```bash
  # вручну в UI під кожним тестовим акаунтом (Basic auth із зовнішнім IdP недоступний)
  docker compose logs --since 10m opencloud | grep -iE '403|forbidden'   # відмови очікуються лише для viewer / outsider
  ```

### Задача 3.2: Завантаження, публічне посилання, оновлення файлу (Сценарій 2)

- **Ціль:** Публічне посилання `/s/<token>` після перезапису файлу віддає нову версію, `user.oc.id` не змінюється.
- **Залежності:** 3.1
- **Кроки реалізації:**
  1. Editor завантажує `.pdf` і `.docx` у Space.
  2. Створити публічне посилання (лише перегляд/завантаження).
  3. Завантажити нову редакцію поверх; перевірити, що посилання віддає нову версію, а стара видна в історії версій.
  4. Перевірити перегляд PDF і редагування `.md` у браузері.
  5. Перевірка AC-4 без окремого скрипта: прочитати `user.oc.id` до перейменування, після перейменування в UI і після перезапису; значення має збігатися.
- **Файли / Директорії:** `docs/AI_CONTEXT.md` (чекліст)
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] Те саме посилання віддає оновлений вміст (порівняння checksum)
  - [ ] Історія версій містить попередню редакцію
  - [ ] `user.oc.id` не змінився після rename і overwrite
- **Перевірка (Validation):**

  ```bash
  getfattr --only-values -n user.oc.id <шлях> > /tmp/id.before   # до змін
  # перейменувати файл у UI, потім завантажити нову редакцію поверх
  getfattr --only-values -n user.oc.id <новий-шлях> | cmp - /tmp/id.before && echo SAME
  curl -ksI https://<domain>/s/<token>
  curl -ks https://<domain>/s/<token>/download -o /tmp/dl.bin
  sha256sum /tmp/dl.bin <нова-редакція-файлу>
  ```

### Задача 3.3: TUS-завантаження ≥ 10 ГБ із відновленням (AC-3)

- **Ціль:** Файл 10 ГБ завантажується чанками й відновлюється з місця розриву.
- **Залежності:** 3.2
- **Кроки реалізації:**
  1. Підготувати тестовий файл 10 ГБ і порахувати його checksum.
  2. Завантажити через UI; посеред передачі перервати мережу клієнта (DevTools → Offline) і відновити.
  3. Завантажити файл назад і порівняти checksum.
  4. Зафіксувати `docker stats` під час передачі як baseline ресурсів (для вибору ліміту 70% RAM хоста). Проходження через Traefik перевіряється окремо в 5.5.
- **Файли / Директорії:** `docs/AI_CONTEXT.md` (baseline)
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] Завантаження відновлюється після розриву без повторної передачі всього файлу
  - [ ] Checksum оригіналу й завантаженої копії збігаються
  - [ ] UI лишається чутливим під час передачі
- **Перевірка (Validation):**

  ```bash
  head -c 10G /dev/urandom > /tmp/test10g.bin && sha256sum /tmp/test10g.bin
  docker stats --no-stream opencloud
  sha256sum /tmp/test10g.downloaded.bin
  df -h .local/data
  ```

### Задача 3.4: Кошик 30 днів і відновлення (Сценарій 3, частина 1)

- **Ціль:** Видалений файл відновлюється з кошика; відомий механізм очищення через 30 днів.
- **Залежності:** 3.2
- **Кроки реалізації:**
  1. Видалити файл у UI й відновити як Manager та як Editor.
  2. За документацією вибраної версії з'ясувати, чи очищення кошика автоматичне, чи потрібен CLI-запуск `purge-expired` за cron `[перевірити]`; визначити змінні терміну 30 днів.
  3. Занести рішення в `docs/AI_CONTEXT.md`; якщо потрібен CLI-запуск — він виконується через docker exec на початку backup.sh (6.2).
- **Файли / Директорії:** `docker-compose.yml`, `.env.example`, `docs/AI_CONTEXT.md`
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] Відновлення з кошика працює для Manager і Editor
  - [ ] Механізм очищення й параметр 30 днів визначені та задокументовані
- **Перевірка (Validation):**

  ```bash
  docker compose exec opencloud opencloud storage-users --help | head -30
  grep -n -i 'trash' docs/AI_CONTEXT.md
  ```

**Quality Gate фази 3:**

- AC-3 і AC-4 пройдені на реальних Entra-профілях; публічне посилання переживає перезапис файлу
- Ролі й ізоляція Spaces працюють за чеклістом
- Механізм кошика визначений (авто чи cron)

## Фаза 4: Секрети та безпека

Автентифікація й ролі перевірені у Фазі 2; тут — зберігання секретів і їх доставка в Swarm.

### Задача 4.1: Підготовка секретів OpenCloud (SOPS → один Swarm Secret)

- **Ціль:** Згенерований `opencloud.yaml` зберігається в SOPS і потрапляє в контейнер як один версіонований Swarm Secret у `/etc/opencloud/opencloud.yaml`.
- **Залежності:** 2.2
- **Кроки реалізації:**
  1. Налаштувати `.sops.yaml` з окремими age-ключами для dev і prod. Створити `env.dev.enc` та `env.prod.enc` (prod — із плейсхолдерами `REPLACE_WITH_*` до реальної ротації): параметри (`DEPLOY_ENVIRONMENT`, домен, `OPENCLOUD_IMAGE_TAG`, Tenant ID, Client ID, `OPENCLOUD_MEM_LIMIT`, passphrase Borg) і ключ `OPENCLOUD_YAML_B64` — base64 від `opencloud.yaml`. Альтернатива — окремий SOPS-YAML-файл `[рішення при реалізації]`.
  2. `opencloud init` виконується один раз на середовище; dev і prod мають різні файли. Ніколи не повторювати `init` над наявними даними: паролі в конфігу мають збігатися зі станом idm.
  3. Спайк: переконатися, що файл, змонтований як Swarm Secret, читається non-root процесом (`uid` і `mode` секрету) і що сервіс стартує без кастомного entrypoint `[перевірити]`.
  4. Реалізувати `scripts/reconcile-sops-secrets.sh` (Категорія 1б) за стандартом: параметри `-env-file`, `-environment`, `-mapping-file`, `-apply`, `-approval-context` (обов'язковий для `production` з `-apply`). Скрипт перевіряє збіг `DEPLOY_ENVIRONMENT` з `-environment` та `SERVER_ENV`, відхиляє порожні значення й `REPLACE_WITH_*`, вимагає права plaintext-файлу `mode & 077 == 0`, витягає значення у `/dev/shm` (каталог `700`, файли `400`, `trap ... EXIT`) і ніколи не використовує `source`. Для ключа `OPENCLOUD_YAML_B64` значення декодується з base64 перед створенням секрету.
  5. Ім'я секрету — `<project>_opencloud_yaml_v<hash16>` (SHA-256 від декодованого вмісту); `docker secret create` лише якщо `docker secret inspect` такого імені не знаходить. Мапінг (`OPENCLOUD_YAML_SECRET_NAME=...`) записується через `mktemp` + `mv` і не містить значень.
  6. Валідація SOPS-файлів без окремого скрипта: функція всередині reconcile виконує `sops --decrypt <файл> > /dev/null` і перевіряє наявність ключа `sops:` (якщо спільний стандарт уже має `validate_sops_encrypted.py` — використати його). Старі версії секрету видаляються вручну за runbook після перевірки нового деплою.
  7. Внутрішні ключі `opencloud.yaml` не ротуються рутинно: це потребує нового `init` і узгодження з даними idm `[перевірити]`. Записати у відомі обмеження (6.5).
- **Файли / Директорії:** `.sops.yaml`, `env.dev.enc`, `env.prod.enc`, `scripts/reconcile-sops-secrets.sh`, `.env.example`
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] Другий запуск `reconcile` → `exit 0`, нових секретів не створено
  - [ ] Негативні сценарії дають ненульовий код і зрозуміле повідомлення: немає env-файлу, плейсхолдер, невідповідність `SERVER_ENV`, права plaintext-файлу ширші за `600`, незашифрований файл
  - [ ] У мапінгу, виводі та `docker service inspect` немає значень секретів
  - [ ] Prod age-ключ не лежить у репозиторії, а його копія доступна без prod-ноди (потрібно для DR, 6.4)
- **Перевірка (Validation):**

  ```bash
  shellcheck scripts/reconcile-sops-secrets.sh
  sops --decrypt env.dev.enc > /dev/null && echo OK
  ./scripts/reconcile-sops-secrets.sh -env-file env.dev.enc -environment development -mapping-file /tmp/map.env   # dry-run
  ./scripts/reconcile-sops-secrets.sh -env-file env.dev.enc -environment development -mapping-file /tmp/map.env -apply
  ./scripts/reconcile-sops-secrets.sh -env-file env.dev.enc -environment development -mapping-file /tmp/map.env -apply; echo $?   # другий запуск: 0
  docker secret ls | grep opencloud_yaml_v
  echo 'KEY=plain' > /tmp/bad.env && chmod 644 /tmp/bad.env
  ./scripts/reconcile-sops-secrets.sh -env-file /tmp/bad.env -environment development -mapping-file /tmp/map.env; echo $?   # очікуємо != 0
  ```

**Quality Gate фази 4:**

- Секрети існують лише в SOPS і в Swarm; у мапінгах, логах і git значень немає
- `reconcile-sops-secrets.sh` ідемпотентний і проходить негативні сценарії
- Сервіс стартує з `opencloud.yaml` лише зі Swarm Secret

## Фаза 5: Пакування та деплой на dev

CI/CD підключається останнім кроком проєкту (задача 6.6). У цій фазі той самий оркестратор запускається вручну на dev-ноді.

### Задача 5.1: `docker-stack.yml`

- **Ціль:** Стек описує сервіс `opencloud` за політиками SPEC.
- **Залежності:** 4.1
- **Кроки реалізації:**
  1. Образ із `OPENCLOUD_IMAGE` і `OPENCLOUD_IMAGE_TAG`; `replicas: 1`; `placement.constraints: [node.labels.storage == primary]`; `update_config` (`parallelism: 1`, `order: stop-first`, `failure_action: rollback`, `delay: 10s`); `restart_policy` (`on-failure`, `delay: 5s`; `max_attempts: 5` залишити лише свідомо, бо після п'яти збоїв сервіс лишиться зупиненим).
  2. Ресурси: без жорсткого ліміту 2560M і без CPU-ліміту; `limits.memory` = `${OPENCLOUD_MEM_LIMIT}` — орієнтир для production 70% RAM хоста (значення дає `preflight-host.sh`), для dev — мінімальний ліміт, який ще потрібно визначити; reservation 512M / 0.5 CPU. Після навантаження з 3.3 підтвердити ліміти `[перевірити]`.
  3. Монтування: `/srv/opencloud/data` → `/var/lib/opencloud`; `opencloud.yaml` як external Swarm Secret (ім'я з мапінгу) у `/etc/opencloud/opencloud.yaml` (`uid` і `mode` з 4.1); за потреби статичний `config/proxy.yaml` у `/etc/opencloud/proxy.yaml` лише для читання. Окремого host-каталогу конфігу немає, якщо це підтвердила задача 1.3.
  4. Non-root: UID процесу в офіційному образі узгодити з `init-volumes.sh` (5.2). Власного Dockerfile немає.
  5. Traefik labels додаються в 5.4, healthcheck — у 6.1.
- **Файли / Директорії:** `docker-stack.yml`, `config/proxy.yaml` (за потреби), `.env.example`
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] Конфіг рендериться без помилок
  - [ ] У відрендереному конфігу немає значень секретів, лише імена
  - [ ] Політики `replicas: 1`, `stop-first`, `placement` присутні; ліміт пам'яті береться зі змінної, значення `2560M` відсутнє
- **Перевірка (Validation):**

  ```bash
  yamllint docker-stack.yml
  docker compose --env-file /tmp/map.env -f docker-stack.yml config -q
  docker compose --env-file /tmp/map.env -f docker-stack.yml config | grep -E 'replicas|order|constraints|memory'
  ! grep -n '2560M' docker-stack.yml
  ```

### Задача 5.2: `init-volumes.sh` (Категорія 1б)

- **Ціль:** Ідемпотентне створення каталогів стану з правильними правами перед деплоєм.
- **Залежності:** 5.1
- **Кроки реалізації:**
  1. `scripts/init-volumes.sh`: `mkdir -p /srv/opencloud/data`, власник UID/GID контейнера, права каталогу; нічого більше не генерує. Змінні (шлях, UID) читаються з `$ORCHESTRATOR_ENV_FILE` лише безпечним парсингом (`grep` / `cut` / `awk`), ніколи `source`.
  2. Конфіги не рендеряться: `config/proxy.yaml` — звичайний статичний файл у репозиторії, а все, що можна задати змінною середовища, лишається змінною.
- **Файли / Директорії:** `scripts/init-volumes.sh`
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] Другий запуск → `exit 0`, без змін
  - [ ] Власник і права каталогу відповідають UID контейнера
  - [ ] Відсутній env-файл → ненульовий код і зрозуміле повідомлення
- **Перевірка (Validation):**

  ```bash
  shellcheck scripts/init-volumes.sh
  ORCHESTRATOR_ENV_FILE=/tmp/plain.env ./scripts/init-volumes.sh && ORCHESTRATOR_ENV_FILE=/tmp/plain.env ./scripts/init-volumes.sh; echo $?
  stat -c '%U:%G %a' /srv/opencloud/data
  ORCHESTRATOR_ENV_FILE=/nonexistent ./scripts/init-volumes.sh; echo $?   # очікуємо != 0
  ```

### Задача 5.3: Оркестратор (деплой, перевірка політик, post-deploy check)

- **Ціль:** Єдина точка деплою за контрактом із суворим порядком кроків.
- **Залежності:** 5.2
- **Кроки реалізації:**
  1. `scripts/deploy-orchestrator-swarm.sh` приймає `ORCHESTRATOR_ENV_FILE`, `ENVIRONMENT_NAME` (`development` | `production`), `ORCHESTRATOR_MODE=swarm`, `STACK_NAME`; інший режим → відмова.
  2. Порядок: 1а `preflight-host.sh` → перевірка мітки `storage=primary` (оркестратор працює на manager) → 1б `init-volumes.sh` → `reconcile-sops-secrets.sh ... -apply` (оновлення мапінгу) → перевірка політик → `docker compose --env-file ... config` → `docker stack deploy` → post-deploy check.
  3. Перевірка політик — кілька `grep -q` у функції оркестратора, без окремого скрипта: `replicas: 1`, `order: stop-first`, `placement`, відсутність опублікованих портів на хості, усі секрети external.
  4. Post-deploy check — функція очікування з таймаутом: `docker inspect --format '{{.State.Health.Status}}'` контейнера = `healthy` і `curl` на головну сторінку `https://<domain>/` повертає 200 (не `.well-known`, див. 6.1). Помилка → ненульовий код, пайплайн падає.
  5. Для `production` вимагати `-approval-context`.
- **Файли / Директорії:** `scripts/deploy-orchestrator-swarm.sh`
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] Крок, що завершився помилкою, зупиняє деплой
  - [ ] Повторний запуск без змін не створює нових секретів
  - [ ] `production` без approval-context відхиляється
  - [ ] Деплой, що не став `healthy` за таймаут, завершується ненульовим кодом
- **Перевірка (Validation):**

  ```bash
  shellcheck scripts/*.sh
  ORCHESTRATOR_MODE=compose ./scripts/deploy-orchestrator-swarm.sh; echo $?   # очікуємо != 0
  grep -c 'grep -q' scripts/deploy-orchestrator-swarm.sh
  ```

### Задача 5.4: Traefik для OpenCloud

- **Ціль:** Роутер OpenCloud пропускає TUS-чанки без буферизації й обривів.
- **Залежності:** 5.1
- **Кроки реалізації:**
  1. Labels на сервісі: Host-правило, TLS, entrypoint, порт 9200, спільна overlay-мережа.
  2. Не додавати buffering middleware (отже, без `maxRequestBodyBytes`).
  3. `respondingTimeouts` задаються на рівні entrypoint, тож змінюють поведінку всіх сервісів спільного Traefik. Узгодити з власником Traefik помірне значення (хвилини, TUS шле невеликі чанки) замість `0`; перевірити `forwardingTimeouts` `[перевірити поточні значення]`.
  4. Задокументувати зміни на боці центрального Traefik в `AI_CONTEXT.md`.
- **Файли / Директорії:** `docker-stack.yml`, `docs/AI_CONTEXT.md`
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] TLS працює, головна сторінка повертає 200
  - [ ] TUS PATCH великого чанка не дає 413/504 (повна перевірка в 5.5)
  - [ ] Інші сервіси спільного Traefik не постраждали від змін таймаутів
- **Перевірка (Validation):**

  ```bash
  docker compose --env-file /tmp/map.env -f docker-stack.yml config | grep -i traefik
  curl -sSI https://<dev-domain>/ | head -1
  ```

### Задача 5.5: Перший деплой на dev і приймання

- **Ціль:** AC-1, AC-3 і AC-4 пройдені на dev-домені.
- **Залежності:** 5.3, 5.4
- **Кроки реалізації:**
  1. На dev-ноді: мітка `storage=primary`, `preflight-host.sh`.
  2. Запустити оркестратор вручну для `development`.
  3. Пройти AC-1 (Entra, студент не входить), AC-3 (10 ГБ через Traefik із розривом), AC-4 (rename / overwrite і порівняння `user.oc.id`, як у 3.2), чеклісти 3.1–3.2.
  4. Зафіксувати використання CPU/RAM у `AI_CONTEXT.md`.
- **Файли / Директорії:** `docs/AI_CONTEXT.md`
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] Сервіс `1/1`, відкат на попередню версію працює
  - [ ] AC-1, AC-3, AC-4 пройдені на dev
  - [ ] Повторний запуск оркестратора ідемпотентний
- **Перевірка (Validation):**

  ```bash
  docker stack services <stack>
  docker service ps <stack>_opencloud --no-trunc
  docker inspect --format '{{.State.Health.Status}}' $(docker ps -q -f name=<stack>_opencloud)
  curl -sSI https://<dev-domain>/ | head -1
  getfattr --only-values -n user.oc.id <новий-шлях> | cmp - /tmp/id.before && echo SAME
  ```

**Quality Gate фази 5:**

- Оркестратор розгортає dev одним запуском і ідемпотентний
- AC-1, AC-3 (через Traefik) і AC-4 пройдені на dev
- У `docker service inspect` і логах немає значень секретів

## Фаза 6: Надійність та експлуатація

### Задача 6.1: Healthcheck

- **Ціль:** Контейнер має працюючий healthcheck, на який спирається post-deploy check оркестратора (5.3).
- **Залежності:** 5.5
- **Кроки реалізації:**
  1. З'ясувати реальний health-ендпоінт і порт: SPEC припускає `/healthz` на 9200, але health сервісів зазвичай віддає debug-порт `[перевірити]`; відкривати його лише у внутрішній мережі.
  2. Додати `healthcheck` у стек (чи є `curl` або `wget` в образі, `[перевірити]`).
  3. Стан Swarm task (`Running`) і Docker health status — різні речі, перевіряються обидва. Smoke-перевірка — головна сторінка `https://<domain>/` (200). `/.well-known/openid-configuration` на домені OpenCloud при зовнішньому IdP не віддається без `PROXY_OIDC_REWRITE_WELLKNOWN=true`; вмикати лише за потреби.
  4. Окремого smoke-скрипта немає: перевірка живе в оркестраторі (5.3).
- **Файли / Директорії:** `docker-stack.yml`, `scripts/deploy-orchestrator-swarm.sh`
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] `docker inspect` показує `healthy` після деплою
  - [ ] Зупинений сервіс не проходить post-deploy check
- **Перевірка (Validation):**

  ```bash
  docker inspect --format '{{.State.Health.Status}}' $(docker ps -q -f name=<stack>_opencloud)
  curl -sSI https://<dev-domain>/ | head -1
  docker service scale <stack>_opencloud=0; curl -sSI https://<dev-domain>/ | head -1   # очікуємо не 200
  docker service scale <stack>_opencloud=1
  ```

### Задача 6.2: `backup.sh` (Категорія 2)

- **Ціль:** Щоденний узгоджений Borg-бекап стану зі зупинкою сервісу на час копіювання.
- **Залежності:** 1.3, 4.1
- **Кроки реалізації:**
  1. `resolve_environment()`: аргумент `$1` → `$SERVER_ENV` → `exit 1`.
  2. Розшифрувати `env.${ENVIRONMENT}.enc` у `mktemp /dev/shm/env-XXXXXX` (`chmod 600`); `source` дозволений лише після цього; `trap '_cleanup_env_tmp' EXIT` зі `shred -u` (fallback `rm -f`).
  3. Поки сервіс працює: очищення кошика та незавершених TUS-сесій через `docker exec` у контейнері `opencloud` `[перевірити точні команди, наприклад storage-users trash-bin purge-expired]`. Помилка очищення не блокує бекап (запис у лог і продовження). Окремий скрипт і SOPS для цього не потрібні.
  4. Зупинка сервісу: спершу зареєструвати `trap` на EXIT, який завжди повертає `docker service scale <stack>_opencloud=1` (бекап нічого не змінює в даних, тож повертати сервіс безпечно); далі `scale=0` → `borg create` для `/srv/opencloud/data` (і `/srv/opencloud/config`, якщо за 1.3 він існує). Прапорців `--xattrs` / `--acls` немає: xattrs і ACL Borg зберігає за замовчуванням.
  5. Після повернення сервісу: `borg prune` (стартово 7 daily / 4 weekly / 6 monthly) і `borg check`. Версію Borg зафіксувати; запускати від root.
  6. Borg-репозиторій розташувати поза цією нодою; ціль визначити до старту задачі.
  7. Пост-перевірка: `borg extract` контрольного файлу в тимчасовий каталог і `getfattr -n user.oc.id`; тимчасові файли видаляються.
  8. Розклад — systemd timer або cron о 03:00; тривалість вікна простою виміряти при першому запуску.
- **Файли / Директорії:** `scripts/backup.sh`
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] Без аргументу й без `SERVER_ENV` → `exit 1`
  - [ ] Сервіс повертається в `1/1` навіть після помилки `borg create` (перевірити штучною помилкою)
  - [ ] Тимчасовий файл у `/dev/shm` знищується навіть при помилці
  - [ ] `user.oc.id` читається з відновленої копії
  - [ ] Вікно простою виміряне й записане в runbook
- **Перевірка (Validation):**

  ```bash
  shellcheck scripts/backup.sh
  env -u SERVER_ENV ./scripts/backup.sh; echo $?   # очікуємо 1
  BORG_REPO=/nonexistent ./scripts/backup.sh development; docker service ls | grep opencloud   # очікуємо 1/1
  ./scripts/backup.sh development && borg list <repo> | tail -3
  ls /dev/shm/env-* 2>/dev/null | wc -l   # очікуємо 0
  ```

### Задача 6.3: Процедура відновлення (без скрипта)

- **Ціль:** Описана й перевірена процедура повного відновлення; окремий файл відновлюється через тимчасовий каталог і UI.
- **Залежності:** 6.2
- **Кроки реалізації:**
  1. Повне відновлення (runbook): `docker service scale <stack>_opencloud=0` → `borg extract` у новий каталог `/srv/opencloud/data.restore` (від root) → перевірка (контрольний файл, `getfattr -n user.oc.id`, кількість файлів) → `mv data data.old && mv data.restore data` → `scale=1` → перевірка health і входу → видалити `data.old` після приймання.
  2. Помилка на будь-якому кроці: **сервіс лишається зупиненим**, адміністратор отримує повідомлення; автоматичного запуску на частково відновлених даних немає. `data.old` дозволяє повернутися до попереднього стану.
  3. Відновлення одного файлу: `borg extract` у тимчасовий каталог і завантаження файлу через UI OpenCloud (штатний шлях). Для видаленого файлу спершу кошик, для старої редакції — історія версій. Пряме відновлення в дерево PosixFS не автоматизується, поки не доведено, що воно потрібне.
  4. Скрипта `restore.sh` та режимів `--path` / `--dry-run` немає.
- **Файли / Директорії:** `docs/RUNBOOK.md` (процедура)
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] Процедура повного відновлення відпрацьована на dev
  - [ ] При штучній помилці `extract` сервіс лишається зупиненим
  - [ ] Файл зі старого бекапу відновлюється через тимчасовий каталог і UI
- **Перевірка (Validation):**

  ```bash
  docker service scale <stack>_opencloud=0
  mkdir -p /srv/opencloud/data.restore && cd /srv/opencloud/data.restore
  borg extract --strip-components 3 <repo>::<archive> srv/opencloud/data   # [перевірити на dev]
  getfattr -n user.oc.id /srv/opencloud/data.restore/<шлях>/<файл>
  cd /srv/opencloud && mv data data.old && mv data.restore data
  docker service scale <stack>_opencloud=1
  ```

### Задача 6.4: Disaster recovery drill

- **Ціль:** Підтверджено, що повний restore на чисту ноду зберігає користувачів, гранти й публічні посилання.
- **Залежності:** 6.3, 5.5
- **Кроки реалізації:**
  1. На dev створити Space, гранти, публічне посилання, файл і кількох користувачів, що входили через Entra.
  2. Зробити бекап → знищити стан (чиста нода або порожні каталоги) → розгорнути оркестратором (секрети зі SOPS) → відновити `data` за процедурою 6.3.
  3. DR «лише з пароль-менеджера»: passphrase Borg і prod age-ключ доступні без мертвої ноди; ключ репозиторію Borg зберігається окремо `[перевірити режим repokey]`.
  4. Перевірити: вхід через Entra, гранти, `/s/<token>`, збіг `user.oc.id`.
  5. Виміряти RTO; RPO = інтервал бекапу (24 год).
  6. Якщо гранти чи посилання зламані — розширити склад бекапу (за 1.3) і повторити.
- **Файли / Директорії:** `docs/RUNBOOK.md` (результати)
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] Користувачі, гранти й публічні посилання збережені після повного restore
  - [ ] SOPS розшифровується на чистій ноді без доступу до старої
  - [ ] RTO та RPO записані
- **Перевірка (Validation):**

  ```bash
  curl -ksI https://<dev-domain>/s/<token> | head -1
  getfattr -n user.oc.id <файл>
  docker stack services <stack>
  ```

### Задача 6.5: Runbook-и

- **Ціль:** Документація експлуатації без зайвих файлів: `docs/scripts_runbook.md` і `docs/RUNBOOK.md`.
- **Залежності:** 6.4
- **Кроки реалізації:**
  1. `docs/scripts_runbook.md`: для кожного з п'яти скриптів (1а / 1б / 2) — призначення й точні команди ручного запуску; для `reconcile-sops-secrets.sh` — dry-run без `-apply` і тест у `/dev/shm`.
  2. `docs/RUNBOOK.md`: деплой і rollback (`docker service rollback`), процедури restore (6.3), ротація секрету `opencloud.yaml` (новий хеш → новий секрет → redeploy → видалення старого вручну), додавання Manager, offboarding.
  3. Секція «Відомі обмеження»: бекап зупиняє сервіс на час `borg create` (вікно виміряне в 6.2); restore = простій; одна нода (SPOF); вхід залежить від доступності Entra, break-glass — другий admin-акаунт; групи й членства синхронізуються з токена при JIT, ручні членства можуть видалятися ([issue #4058](https://github.com/opencloud-eu/opencloud/issues/4058)); масове призначення staff залежить від ліцензії A1 (2.2); внутрішні ключі `opencloud.yaml` не ротуються рутинно; публічні посилання вічні й без пароля; акаунти й персональні простори звільнених лишаються (ручна чистка); немає desktop-клієнта; немає міграції з Google Drive; CSP/AC-5 відкладено до Фази 2.
  4. Прибрати дублювання з `AI_CONTEXT.md`.
- **Файли / Директорії:** `docs/scripts_runbook.md`, `docs/RUNBOOK.md`, `README.md`
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] Кожен скрипт з `scripts/` описаний у runbook
  - [ ] Restore і rollback проходять за runbook без додаткових знань
- **Перевірка (Validation):**

  ```bash
  for f in scripts/*.sh; do grep -q "$(basename "$f")" docs/scripts_runbook.md || echo "MISSING $f"; done
  grep -n 'Відомі обмеження' docs/RUNBOOK.md
  ```

### Задача 6.6: Підключення до shared CI/CD (остання задача проєкту)

- **Ціль:** `.github/workflows/main.yml` підключає централізований reusable workflow, репозиторій не описує логіку деплою з нуля.
- **Залежності:** 6.5
- **Кроки реалізації:**
  1. Викликати `mzhk-repo/shared-workflows/.github/workflows/shared-ci-cd.yml@main`.
  2. Тригери: `push` і `pull_request` у `dev` та `main`; `release` (published); ігнорувати `.md`, `.env.example`, `.gitignore` та інші файли, що не впливають на рантайм.
  3. Джоба `deploy-change-check`: за `git diff` виставляє `deploy_allowed=true`, якщо змінено файли рантайму чи інфраструктури (скрипти бекапів і словники ігнорувати).
  4. `deploy-dev` (`environment_name: development`): `push` у `dev` або зворотний PR `main -> dev`, за `deploy_allowed == 'true'`.
  5. `deploy-prod` (`environment_name: production`): на PR і `push` у `main` лише перевірки (`deploy: false`); деплой тільки при релізі з тегом `v*` та `deploy_allowed == 'true'`.
  6. `with`: `orchestration_script_path: 'scripts/deploy-orchestrator-swarm.sh'`, `docker_image_name`, `build_and_push_docker: false` (офіційний образ), `use_ansible: true`, `infra_repo_path: '/opt/Ansible'`.
  7. `secrets`: `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`, `SERVER_HOST`, `SERVER_USER`, `SERVER_SSH_KEY`, `SERVER_SSH_PORT`, `SSH_HOST_KEY_PUB`, `DEPLOY_PROJECT_DIR`, `SOPS_AGE_KEY` (окремо для кожного середовища).
  8. Перший прод-деплой — релізом `v0.1.0` після успішного dev.
- **Файли / Директорії:** `.github/workflows/main.yml`
- **Критерії прийняття (Acceptance Criteria):**
  - [ ] PR перевіряє, але не деплоїть
  - [ ] Push у `dev` зі зміною рантайм-файлів деплоїть dev; зміна лише `.md` деплой не тригерить
  - [ ] Прод розгортається виключно релізом `v*`
- **Перевірка (Validation):**

  ```bash
  yamllint .github/workflows/main.yml
  gh workflow view main.yml
  gh run list --workflow main.yml --limit 5
  gh run view <run-id> --log | grep -i deploy_allowed
  ```

**Quality Gate фази 6:**

- DR drill пройдено: користувачі, гранти й публічні посилання переживають повний restore, SOPS розшифровується без старої ноди
- `backup.sh` повертає сервіс навіть після помилки, невдалий restore лишає сервіс зупиненим, runbook покриває всі скрипти
- CI/CD не деплоїть з PR і з `.md`-змін, прод лише релізом `v*`
