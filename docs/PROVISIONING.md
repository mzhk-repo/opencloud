# Концепція моніторингу OpenCloud (Prometheus + Grafana)

## 1. Архітектура збору метрик (KISS)

* **Ендпоінт сервісу OpenCloud:** У режимі єдиного процесу (Single Process Mode) вбудований HTTP-сервер відлагодження сервісу `proxy` віддає метрики Prometheus для всіх внутрішніх компонентів на порту `9205` (шлях `metrics`).
  * Конфігурація OpenCloud: `PROXY_DEBUG_ADDR=0.0.0.0:9205`.
  * Мережева ізоляція: порт `9205` не публікується на хості чи через Traefik. Його можуть досягти учасники спільної overlay-мережі `OPENCLOUD_PROXY_NETWORK` (типово `proxy-net`), зокрема VictoriaMetrics, якщо вона підключена до тієї самої мережі.
  * **Обмеження доступу:** debug-сервер також віддає `/config`, `/healthz` і `/readyz`; у 9.1.1 токен захищає лише `/metrics`. `/config` містить замасковану конфігурацію, але доступний усім учасникам мережі без автентифікації. Перед розгортанням перевірити довіру до всіх учасників і топологію; за потреби забезпечити ізольований доступ до `/metrics` до увімкнення цього налаштування.
* **Метрики хоста та регламентних задач:** Збираються стандартним `node_exporter` із увімкненим колектором `textfile` (директорія `<node_exporter_textfile_dir>`), куди скрипти обслуговування записують результати резервного копіювання та верифікації відновлення.

Для окремого налаштування VictoriaMetrics scrape target за стандартної назви стеку — `opencloud_opencloud:9205`, шлях `/metrics`; потрібна спільна досяжна overlay-мережа. Перевірити DNS і HTTP з мережі scraper після деплою. Якщо VictoriaMetrics працює в іншому Docker Swarm, сама назва `proxy-net` не об'єднує мережі: потрібен окремо узгоджений захищений мережевий шлях. У цьому репозиторії scrape job, дашборди та алерти не розгортаються.

---

## 2. Обов'язкові метрики

### 2.1. Метрики сервісу OpenCloud (`job="opencloud"`, порт `9205`)

Метрики запитів нижче підтримуються в OpenCloud 9.1.1 для зворотної сумісності; перед налаштуванням правил перевірити фактичні назви на endpoint. Назва job задається конфігурацією scraper, яку цей репозиторій не розгортає.

| Метрика | Тип | Призначення |
| :--- | :--- | :--- |
| `up{job="opencloud"}` | Gauge | Стан доступності експортера сервісу (`1` — працює, `0` — недоступний). |
| `opencloud_proxy_build_info` | Gauge | Поточна задеплоєна версія бінарника OpenCloud (лейбл `version`). |
| `opencloud_proxy_requests_total` | Counter | Загальна кількість HTTP-запитів із розбивкою за `method`. |
| `opencloud_proxy_errors_total` | Counter | Кількість запитів, що завершилися серверною помилкою (`HTTP >= 500`), за `method`. |
| `opencloud_proxy_duration_seconds_bucket` | Histogram | Розподіл часу обробки запитів (для оцінки UI/API використовується фільтр `method!~"PUT|PATCH"`, щоб виключити тривалі чанкові завантаження TUS). |
| `process_resident_memory_bytes` | Gauge | Фактичне споживання оперативної пам'яті (RSS) процесом `opencloud`. |
| `process_open_fds` | Gauge | Кількість відкритих файлових дескрипторів і сокетів процесу. |

### 2.2. Метрики хоста (`job="node-exporter"`, `node_exporter`)

| Метрика | Лейбли / Фільтри | Призначення |
| :--- | :--- | :--- |
| `node_filesystem_avail_bytes` | `mountpoint="<opencloud_storage_mountpoint>"` | Вільний дисковий простір на розділі сховища `PosixFS`. |
| `node_filesystem_files_free` | `mountpoint="<opencloud_storage_mountpoint>"` | Кількість вільних inodes (критично для `PosixFS`, де кожен файл і ревізія займають окремий inode). |
| `node_memory_MemAvailable_bytes` | — | Доступна оперативна пам'ять хоста (контроль ризику спрацювання OOM Killer). |
| `node_cpu_seconds_total` | `mode="iowait"` | Час очікування дискових операцій вводу-виводу. |

### 2.3. Контракт Textfile Collector (Бекапи та верифікація відновлення)

Скрипти регламентного обслуговування на хості атомарно (через тимчасовий файл і перейменування) оновлюють `.prom`-файли у `<node_exporter_textfile_dir>`:

1. **Щоденний бекап (`opencloud_backup.prom`):**
   * `opencloud_backup_last_success_timestamp_seconds` (Gauge) — Unix timestamp останнього успішного завершення циклу резервного копіювання.
2. **Тест відновлення бекапу (`opencloud_restore_smoke.prom`):**
   * Запущений оператором або зовнішнім планувальником `scripts/test-restore.sh` розгортає архів в ізольовану директорію, перевіряє структуру стану та наявність `user.oc.id` хоча б у одного файла. Це не перевірка всіх файлів чи запуску сервісу.
   * `opencloud_restore_smoke_last_success_timestamp_seconds` (Gauge) — Unix timestamp останнього успішного тесту відновлення.
   * `opencloud_restore_smoke_last_status` (Gauge) — результат останнього запуску (`1` — успіх, `0` — помилка).

---

## 3. Правила алертингу (Prometheus Alert Rules)

| Назва алерту | Вираз PromQL | `for` | Критичність | Обґрунтування |
| :--- | :--- | :--- | :--- | :--- |
| `OpenCloudDown` | `up{job="opencloud"} == 0` | `5m` | `critical` | Вікно `5m` не усуває алерт, якщо зупинка під час Borg-бекапу триває довше; фактичний простій ще потрібно виміряти. |
| `OpenCloudHigh5xxErrors` | `sum(rate(opencloud_proxy_errors_total[5m])) / sum(rate(opencloud_proxy_requests_total[5m])) > 0.02` | `5m` | `critical` | Частка серверних помилок перевищує 2% (збій валідації токенів IdP, помилки ФС або внутрішнього gRPC). |
| `OpenCloudSlowUI` | `histogram_quantile(0.95, sum(rate(opencloud_proxy_duration_seconds_bucket{method!~"PUT\|PATCH"}[5m])) by (le)) > 2` | `5m` | `warning` | 95-й перцентиль часу відповіді інтерфейсу та API перевищує цільовий SLA у 2 секунди. |
| `OpenCloudDiskSpaceLow` | `node_filesystem_avail_bytes{mountpoint="<opencloud_storage_mountpoint>"} < 53687091200` | `5m` | `warning` | Залишилося менше 50 GiB вільного місця (мінімальний буфер під один максимальний TUS-файл зі специфікації). |
| `OpenCloudHostOOMRisk` | `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.10` | `5m` | `critical` | Менше 10% вільної RAM на ноді; високий ризик аварійного завершення процесу `opencloud` ядром ОС. |
| `OpenCloudBackupMissing` | `(time() - opencloud_backup_last_success_timestamp_seconds) > 93600` | `10m` | `critical` | Відсутній успішний бекап понад 26 годин (пропуск щоденного нічного циклу). |
| `OpenCloudRestoreTestFailed` | `opencloud_restore_smoke_last_status == 0 or (time() - opencloud_restore_smoke_last_success_timestamp_seconds) > <restore_test_max_age_seconds>` | `10m` | `warning` | Останній тест відновлення з бекапу завершився помилкою (втрата даних або `user.oc.id`) або не запускався довше регламентного інтервалу (наприклад, `691200` с для тижневого циклу). |

---

## 4. Рекомендована структура дашбордів у Grafana

Для дотримання принципу KISS моніторинг розділяється на два рівні без дублювання системних графіків:

1. **Рівень хоста (готовий ком'юніті-дашборд):**
   * Імпортувати офіційний дашборд **Node Exporter Full (Grafana ID: `1860`)**, прив'язавши його до інстансу ноди сховища (покриває CPU, RAM, Disk I/O, використання inodes та мережу).
2. **Рівень сервісу OpenCloud (1 компактний кастомний дашборд — 5 панелей):**
   * **Панель 1 (Stat): Стан та версія** — значення `up{job="opencloud"}` та лейбл `version` з `opencloud_proxy_build_info`.
   * **Панель 2 (Time Series): Інтенсивність запитів та помилки 5xx** — `rate(opencloud_proxy_requests_total[5m])` та `rate(opencloud_proxy_errors_total[5m])` за HTTP-методами.
   * **Панель 3 (Time Series): Затримка UI/API (P95)** — 95-й перцентиль `opencloud_proxy_duration_seconds_bucket` з виключенням `PUT|PATCH` та візуальним порогом на рівні `2s`.
   * **Панель 4 (Time Series): Ресурси процесу** — графіки `process_resident_memory_bytes` та `process_open_fds`.
   * **Панель 5 (Stat): Свіжість бекапу та тесту відновлення** — час, що минув від `opencloud_backup_last_success_timestamp_seconds` та `opencloud_restore_smoke_last_success_timestamp_seconds`, разом зі статусом `opencloud_restore_smoke_last_status`.
Метрики textfile мають мітки `env` і `service="opencloud"`. Вони з’являються після запуску відповідних скриптів, а не автоматично при розгортанні стеку; правила відсутності серій і періодичність запуску потрібно налаштувати окремо.
