# Відновлення OpenCloud з Borg-бекапу

## Призначення та межі

Інструкція охоплює повне відновлення стану й конфігурації зі створеного `scripts/backup.sh` архіву. Команди нижче наведено для **dev**, сервісу `opencloud_opencloud` та каталогу `/srv/opencloud/data`. Для prod потрібні окремий дозвіл, продакшн-ключі, перевірені адреси й погоджене вікно простою. `restore.sh` не зупиняє сервіс і не замінює чинні дані: він витягує архів у новий каталог. Перемикання виконує оператор після перевірок.

Для відновлення потрібні Borg 1.2 або новіший серії 1.x, SOPS і приватний age-ключ, відповідний `env.dev.enc` або `env.prod.enc`, пароль Borg та доступний зашифрований репозиторій. Для `repokey` збережіть експортований ключ Borg і пароль незалежно від ноди та Drive. Якщо репозиторій або його ключ втрачено, а незалежної копії немає, відновлення неможливе.

На чистій ноді спочатку отримайте з контрольованого джерела цей репозиторій OpenCloud, правильний зашифрований `env.<середовище>.enc`, age-ключ і Borg-passphrase з менеджера паролів. Підготуйте Docker Swarm, Traefik, SOPS, Borg, зовнішній доступ та середовище згідно з deployment runbook. `SERVER_ENV` в `/etc/environment` і в середовищі оператора має бути однаковим (`dev` або `prod`); секрети не виводьте в термінал чи журнали. Потрібні права на відновлення власників, ACL та xattr; перевірте ext4/XFS, підтримку `user.*` xattr і місце для поточного та відновленого стану. Не запускайте `opencloud init` над відновленими даними.

Відновлення повертає стан на момент вибраного бекапу. Новіші файли, користувачі чи налаштування в поточному стані автоматично не зливаються. Зберігайте всі попередні каталоги до окремого рішення власника. Не запускайте одночасно бекап, інший restore, деплой чи зміну файлів PosixFS.

## 1. Визначте джерело

За замовчуванням скрипт використовує `BACKUP_LOCAL_DIR/repository` із SOPS-файлу та вибирає останній архів відповідного середовища. За потреби оберіть архів явно через `--archive ІМʼЯ`; архів іншого середовища буде відхилено.

Якщо локального репозиторію немає, скопіюйте **завершений** датований каталог із Google Drive в новий локальний каталог. Підставте фактичний remote й каталог, не видаляючи джерело:

```bash
remote_dir='REMOTE:ШЛЯХ/ДО/ЗАВЕРШЕНОЇ-КОПІЇ-DEV'
rclone cat "$remote_dir/.opencloud-backup-owner"
```

Продовжуйте лише якщо маркер містить `opencloud-backup-v1 dev`. Створіть новий каталог із правами `700`, перевірте місце і виконайте копіювання:

```bash
umask 077
copy_dir=$(mktemp -d /srv/opencloud/.borg-copy.XXXXXXXX)
rclone copy "$remote_dir" "$copy_dir"
```

При помилці зупиніться й перевірте доступність сховища. Для цієї копії додайте до команди restore `--repo "$copy_dir"`. Не змінюйте репозиторій іншими процесами під час відновлення. Наявність маркера і успішний `rclone copy` самі по собі не доводять придатність до відновлення.

Якщо Borg повідомляє, що знає цей репозиторій за попереднім шляхом, після перевірки джерела й маркера явно дозвольте використання переміщеної копії лише для цієї команди:

```bash
SERVER_ENV=dev BORG_RELOCATED_REPO_ACCESS_IS_OK=yes ./scripts/restore.sh --env dev --repo "$copy_dir" --target /srv/opencloud/data.from-backup
```

Це підтвердження зміни розташування; воно не перевіряє цілісність Drive-копії та не змінює оригінальний репозиторій.

## 2. Перевірте архів без зміни сервісу

Запустіть тестове відновлення в окремий тимчасовий каталог. Скрипт читає локальний репозиторій, витягує стан та відповідну конфігурацію, перевіряє наявність PosixFS, IDM, NATS і `user.oc.id` щонайменше в одному звичайному файлі та видаляє власну тестову копію:

```bash
cd /opt/opencloud
SERVER_ENV=dev ./scripts/test-restore.sh --env dev
```

Це перевірка витягування й структури, а не запуск застосунку або перевірка входу. Результат записується атомарно в `NODE_EXPORTER_TEXTFILE_DIR/opencloud_restore_smoke.prom` з `env="dev",service="opencloud"`; при помилці останній успішний timestamp зберігається. Якщо env не розшифрувався чи каталог метрик недоступний, метрику оновити неможливо — перевіряйте код завершення та журнал запуску. Скрипт не налаштовує розклад. Ця команда тестує локальний репозиторій із SOPS; копію з Drive перевіряйте окремим відновленням через `--repo` нижче.

## 3. Витягніть архів у новий каталог

Переконайтеся, що `/srv/opencloud/data.from-backup` **не існує**, а його батьківський каталог є на цільовому filesystem. Не вказуйте наявний каталог, поточне дерево даних, репозиторій Borg чи rclone mount: скрипт їх відхиляє. Для вибору останнього dev-архіву:

```bash
cd /opt/opencloud
SERVER_ENV=dev ./scripts/restore.sh --env dev --target /srv/opencloud/data.from-backup
```

Для конкретного архіву додайте `--archive 'ІМʼЯ-АРХІВУ'`; для завантаженої копії також додайте `--repo "$copy_dir"`. Якщо операція завершилась помилкою, не переходьте до заміни даних: перевірте повідомлення та збережений частковий каталог. Повторний запуск не перезаписує наявний цільовий каталог.

Запишіть виведені значення `ARCHIVE`, `DATA_PATH`, `CONFIG_PATH`, `SERVICE_PATH`. Два останні файли створено у приватному каталозі `/dev/shm/opencloud-restore.*`; вони містять конфігурацію і потенційно чутливі дані. Працюйте під тим самим користувачем, не виводьте їхній вміст. Наприклад, підставте **точні** шляхи зі свого виводу:

```bash
config_path='/dev/shm/opencloud-restore.REPLACE/opencloud.yaml'
service_path='/dev/shm/opencloud-restore.REPLACE/service.json'
```

Якщо процес був перерваний або хост перезапустився, тимчасовий каталог може залишитися або зникнути. Не вважайте частково витягнуті дані придатними: повторіть відновлення в нову ціль і після перевірки видаліть лише власні непотрібні тимчасові файли.

## 4. Звірте стан, конфігурацію та образ

Вибраний `opencloud.yaml` привʼязаний до стану в архіві. Перед запуском відновлених даних звірте його з чинним `env.dev.enc` і Swarm Secret; команди не друкують конфігурацію:

```bash
set -o pipefail
sops --decrypt --input-type dotenv --output-type binary --extract '["OPENCLOUD_YAML_B64"]' env.dev.enc |
  base64 --decode | cmp -s "$config_path" - && echo 'SOPS-конфігурація збігається'
config_hash=$(sha256sum "$config_path")
expected_secret="opencloud_opencloud_yaml_v${config_hash:0:16}"
actual_secret=$(docker service inspect opencloud_opencloud --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{if eq .File.Name "/etc/opencloud/opencloud.yaml"}}{{.SecretName}}{{end}}{{end}}')
[ "$expected_secret" = "$actual_secret" ] && echo 'Swarm Secret збігається'
```

Обидва повідомлення мають зʼявитися. Якщо ні, зупиніться: відновіть саме відповідну конфігурацію через SOPS і versioned Swarm Secret за окремо погодженою процедурою, перевірте її до старту сервісу. Не змінюйте файл `env.*.enc` навмання і не використовуйте секрет іншого середовища. На чистій ноді відтворіть відсутні Swarm Config через штатний deployment процес і звірте їх з архівною специфікацією.

Звірте образ разом із digest, mount, змінні та посилання на Swarm Config із збереженим `SERVICE_PATH`. Наступна перевірка друкує лише результат зіставлення:

```bash
python3 - "$service_path" <<'PY'
import json, subprocess, sys
saved = json.load(open(sys.argv[1]))[0]['Spec']['TaskTemplate']['ContainerSpec']
current = json.loads(subprocess.run(['docker', 'service', 'inspect', 'opencloud_opencloud'], check=True, capture_output=True, text=True).stdout)[0]['Spec']['TaskTemplate']['ContainerSpec']
checks = {
    'image': saved.get('Image') == current.get('Image'),
    'mounts': saved.get('Mounts', []) == current.get('Mounts', []),
    'environment': sorted(saved.get('Env', [])) == sorted(current.get('Env', [])),
    'configs': saved.get('Configs', []) == current.get('Configs', []),
}
for name, ok in checks.items(): print(name + ': ' + ('OK' if ok else 'MISMATCH'))
if not all(checks.values()): sys.exit(1)
PY
```

На повністю новій ноді, де сервісу ще немає, порівняйте специфікацію приватно з підготовленим deployment маніфестом і відтвореними config/secret. Відмінність версії образу або конфігурації може вимагати окремої міграції; не запускайте її автоматично.

## 5. Перевірте витягнуті дані

Перевірте власника та права кореневого каталогу, наявність `storage/users`, `idm/idm.boltdb`, `nats/jetstream`, кількість файлів і доступне місце. Наступна команда знаходить один звичайний файл із `user.oc.id` без виведення його імені:

```bash
stat -c '%u:%g %a %n' /srv/opencloud/data.from-backup
find /srv/opencloud/data.from-backup -type f -printf '.' | wc -c
control_rel=$(python3 - <<'PY'
import os, sys
base='/srv/opencloud/data.from-backup'
for root, dirs, files in os.walk(os.path.join(base, 'storage/users'), followlinks=False):
    for name in files:
        path=os.path.join(root, name)
        if os.path.islink(path) or not os.path.isfile(path): continue
        try:
            if os.getxattr(path, 'user.oc.id', follow_symlinks=False):
                print(os.path.relpath(path, base)); sys.exit(0)
        except OSError: pass
sys.exit(1)
PY
) && test -n "$control_rel"
getfattr -n user.oc.id --only-values -- "/srv/opencloud/data.from-backup/$control_rel" >/dev/null && echo 'user.oc.id читається'
```

Порівняйте UID/GID і права з конфігурацією контейнера, а кількість і контрольний файл — з очікуваною точкою відновлення. Якщо контрольного файлу, xattr чи потрібних компонентів немає, не перемикайте дані. Сам xattr і кількість файлів не підтверджують збереження всіх користувачів, прав або посилань.

## 6. Зупиніть сервіс і перемкніть каталоги

Погодьте простій. Зафіксуйте початкову кількість реплік. Якщо сервіс уже був зупинений, не запускайте його автоматично. Переконайтеся, що `/srv/opencloud/data.clean-drill` не існує, data не є окремим mountpoint, обидва каталоги лежать на одному filesystem і немає сторонніх процесів, що записують у data. Зупиніть сервіс і підтвердьте відсутність контейнера:

```bash
docker service scale --detach=false opencloud_opencloud=0
docker ps --filter label=com.docker.swarm.service.name=opencloud_opencloud --format '{{.ID}}'
```

Продовжуйте лише за успішних команд і порожнього списку контейнерів. Після цього будь-яка помилка означає: **залишити сервіс зупиненим, зберегти всі каталоги й дослідити причину**.

```bash
test ! -e /srv/opencloud/data.clean-drill && test ! -L /srv/opencloud/data.clean-drill &&
  test -d /srv/opencloud/data.from-backup &&
  test ! -L /srv/opencloud/data.from-backup &&
  mv -T -n -- /srv/opencloud/data /srv/opencloud/data.clean-drill &&
  test ! -e /srv/opencloud/data &&
  mv -T -n -- /srv/opencloud/data.from-backup /srv/opencloud/data &&
  test ! -e /srv/opencloud/data.from-backup
```

Якщо друге перейменування не вдалося, залиште сервіс зупиненим. Перевірте фактичні шляхи; якщо `/srv/opencloud/data` відсутній, можна повернути `/srv/opencloud/data.clean-drill` у `/srv/opencloud/data`, не перезаписуючи жодного каталогу. Якщо перемикання завершилося, але потрібен відкат, спочатку зупиніть сервіс, збережіть відновлений каталог під іншою новою назвою та поверніть відповідну стару копію разом із її конфігурацією. Старі `data.old` і `data.before-drill.*` не зачіпайте.

## 7. Запуск і приймання

Якщо сервіс працював до зупинки та попередні кроки успішні:

```bash
docker service scale --detach=false opencloud_opencloud=1
docker service ls --filter name=opencloud_opencloud --format '{{.Name}} {{.Replicas}}'
docker ps --filter label=com.docker.swarm.service.name=opencloud_opencloud --format '{{.Names}} {{.Status}}'
```

Дочекайтеся `1/1`, `healthy`, оновлення маршруту Traefik та HTTPS `200`. Перевірте вхід Entra, користувачів, Spaces, права, наявний файл і його завантаження, нове завантаження через UI, пошук та наявні публічні посилання. Порівняйте `user.oc.id` контрольного файла; перевірте також відновлення окремого файлу через UI. Якщо хоч один критерій не проходить, зупиніть сервіс, збережіть обидві копії та дослідіть або виконайте погоджений відкат. `healthy` не є повним прийманням.

Після приймання видаліть лише тимчасову копію конфігурації у `/dev/shm`, шлях до якої вивів `restore.sh`, попередньо переконавшись, що це саме створений ним каталог. Старі дерева та Drive-копії не видаляйте без окремого рішення власника. Зафіксуйте час початку, завершення, RTO, вікно втрати змін (RPO), версію образу, архів та результати перевірок без секретів.
