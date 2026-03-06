## *hashcat* ##

**hashcat** is the world's fastest and most advanced password recovery utility, supporting five unique modes of attack for over 300 highly-optimized hashing algorithms. hashcat currently supports CPUs, GPUs, and other hardware accelerators on Linux, Windows, and macOS, and has facilities to help enable distributed password cracking.

### License ###

**hashcat** is licensed under the MIT license. Refer to [docs/license.txt](docs/license.txt) for more information.

### Installation ###

Download the [latest release](https://hashcat.net/hashcat/) and unpack it in the desired location. Please remember to use `7z x` when unpacking the archive from the command line to ensure full file paths remain intact.

Your platform may also provide [packages](docs/packages.md).

### Usage/Help ###

Please refer to the [Hashcat Wiki](https://hashcat.net/wiki/) and the output of `--help` for usage information and general help. A list of frequently asked questions may also be found [here](https://hashcat.net/wiki/doku.php?id=frequently_asked_questions). The [Hashcat Forum](https://hashcat.net/forum/) also contains a plethora of information. If you still think you need help by a real human come to [Discord](https://discord.gg/HFS523HGBT).

### Building ###

Refer to [BUILD.md](BUILD.md) for instructions on how to build **hashcat** from source.

Tests:

Travis | Coverity | GitHub Actions
------ | -------- | --------------
[![Hashcat Travis Build status](https://travis-ci.org/hashcat/hashcat.svg?branch=master)](https://travis-ci.org/hashcat/hashcat) | [![Coverity Scan Build Status](https://scan.coverity.com/projects/11753/badge.svg)](https://scan.coverity.com/projects/hashcat) | [![Hashcat GitHub Actions Build status](https://github.com/hashcat/hashcat/actions/workflows/build.yml/badge.svg)](https://github.com/hashcat/hashcat/actions/workflows/build.yml)

### Contributing ###

Contributions are welcome and encouraged, provided your code is of sufficient quality. Before submitting a pull request, please ensure your code adheres to the following requirements:

1. Licensed under MIT license, or dedicated to the public domain (BSD, GPL, etc. code is incompatible)
2. Adheres to gnu99 standard
3. Compiles cleanly with no warnings when compiled with `-W -Wall -std=gnu99`
4. Uses [Allman-style](https://en.wikipedia.org/wiki/Indent_style#Allman_style) code blocks & indentation
5. Uses 2-spaces as the indentation or a tab if it's required (for example: Makefiles)
6. Uses lower-case function and variable names
7. Avoids the use of `!` and uses positive conditionals wherever possible (e.g., `if (foo == 0)` instead of `if (!foo)`, and `if (foo)` instead of `if (foo != 0)`)
8. Use code like array[index + 0] if you also need to do array[index + 1], to keep it aligned

You can use GNU Indent to help assist you with the style requirements:

```
indent -st -bad -bap -sc -bl -bli0 -ncdw -nce -cli0 -cbi0 -pcs -cs -npsl -bs -nbc -bls -blf -lp -i2 -ts2 -nut -l1024 -nbbo -fca -lc1024 -fc1
```

Your pull request should fully describe the functionality you are adding/removing or the problem you are solving. Regardless of whether your patch modifies one line or one thousand lines, you must describe what has prompted and/or motivated the change.

Solve only one problem in each pull request. If you're fixing a bug and adding a new feature, you need to make two separate pull requests. If you're fixing three bugs, you need to make three separate pull requests. If you're adding four new features, you need to make four separate pull requests. So on, and so forth.

If your patch fixes a bug, please be sure there is an [issue](https://github.com/hashcat/hashcat/issues) open for the bug before submitting a pull request. If your patch aims to improve performance or optimize an algorithm, be sure to quantify your optimizations and document the trade-offs, and back up your claims with benchmarks and metrics.

In order to maintain the quality and integrity of the **hashcat** source tree, all pull requests must be reviewed and signed off by at least two [board members](https://github.com/orgs/hashcat/people) before being merged. The [project lead](https://github.com/jsteube) has the ultimate authority in deciding whether to accept or reject a pull request. Do not be discouraged if your pull request is rejected!

---

### Модули Brainwallet и Private Key (35900–35911) ###

#### Описание модулей ####

| Режим | Описание | Вход / Хеш ключа | Получение адреса |
|-------|----------|-----------------|------------------|
| 35900 | Bitcoin Brainwallet (SHA-256) | SHA-256(passphrase) | RIPEMD160(SHA256(compressed_pubkey)) → Base58Check |
| 35901 | Bitcoin Brainwallet (SHA3-256) | SHA3-256(passphrase) | RIPEMD160(SHA256(compressed_pubkey)) → Base58Check |
| 35902 | Ethereum Brainwallet (Keccak-256) | Keccak-256(passphrase) | Keccak256(uncompressed_pubkey)[12:] → 0x hex |
| 35903 | Ethereum Brainwallet (SHA-256) | SHA-256(passphrase) | Keccak256(uncompressed_pubkey)[12:] → 0x hex |
| 35904 | Ethereum Brainwallet (SHA3-256) | SHA3-256(passphrase) | Keccak256(uncompressed_pubkey)[12:] → 0x hex |
| **35905** | **Bitcoin Private Key Hex + Reversed** | **64-символьный hex приватного ключа** | **RIPEMD160(SHA256(compressed_pubkey)) → P2PKH / P2SH / Bech32** |
| **35906** | **Ethereum Private Key Hex + Reversed** | **64-символьный hex приватного ключа** | **Keccak256(uncompressed_pubkey)[12:] → 0x hex** |
| 35910 | Bitcoin Brainwallet (BLAKE2b-256, P2PKH/Bech32/P2SH) | BLAKE2b-256(passphrase) | RIPEMD160(SHA256(compressed_pubkey)) → P2PKH / P2SH / Bech32 |
| 35911 | Ethereum Brainwallet (BLAKE2s-256) | BLAKE2s-256(passphrase) | Keccak256(uncompressed_pubkey)[12:] → 0x hex |

#### Принцип работы (Brainwallet — режимы 35900–35904, 35910, 35911) ####

Модули brainwallet реализуют атаку на «мозговые кошельки»:

1. Парольная фраза хешируется выбранным алгоритмом (SHA-256, SHA3-256, Keccak-256, BLAKE2b-256 или BLAKE2s-256) → получается 256-битный приватный ключ.
2. По приватному ключу вычисляется точка на эллиптической кривой secp256k1 (публичный ключ).
3. Из публичного ключа выводится адрес кошелька:
   - **Bitcoin P2PKH/P2SH** (35900, 35901, 35910): Сжатый публичный ключ (33 байта) → SHA-256 → RIPEMD-160 → Base58Check с версией 0x00 (P2PKH) или 0x05 (P2SH).
   - **Bitcoin Bech32** (35910): Сжатый публичный ключ → SHA-256 → RIPEMD-160 → Bech32-кодирование (адрес `bc1q...`).
   - **Ethereum** (35902, 35903, 35904, 35911): Несжатый публичный ключ (64 байта, без префикса 0x04) → Keccak-256 → последние 20 байт → адрес в формате `0x...`.
4. Полученный адрес сравнивается с целевым адресом (или списком адресов) из хеш-файла.

#### Принцип работы (Private Key Hex — режимы 35905, 35906) ####

Модули 35905 и 35906 предназначены для атаки на базы адресов когда известны или перебираются **готовые 256-битные приватные ключи** в hex-формате (64 символа):

1. **Вход**: 64-символьная строка в шестнадцатеричном формате — приватный ключ (256 бит / 32 байта).
2. Ключ напрямую используется как скаляр secp256k1 (без хеширования).
3. Для каждого кандидата выполняются **два режима проверки**:
   - **а) Ключ как есть**: `privkey → G·k → pubkey → адрес`
   - **б) Ключ побайтово перевёрнут**: `reverse(privkey) → G·k → pubkey → адрес`
4. Оба результата сравниваются с базой адресов.
5. Адрес получается по правилу:
   - **35905 (Bitcoin)**: Сжатый публичный ключ → SHA-256 → RIPEMD-160 → P2PKH / P2SH / Bech32
   - **35906 (Ethereum)**: Несжатый публичный ключ (x‖y) → Keccak-256 → последние 20 байт → `0x...`

#### Формат базы адресов (хеш-файл) ####

База адресов — это обычный текстовый файл, в котором **каждый адрес записан на отдельной строке**. Этот файл указывается в параметре hashcat как хеш-файл.

**Для Bitcoin (режимы 35900, 35901):**

Каждая строка содержит один Bitcoin-адрес в формате Base58Check (обычный P2PKH-адрес, начинается с `1`):

```
1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa
1CkwUnESKuVFyn3PVm1fyyMtXx6CT2STg7
1HsXwzdgD2ynmEbgMgLikdBDP7wWrFchTL
```

- Длина адреса: 26–34 символа.
- Допустимые символы: алфавит Base58 (`123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`).
- Адрес должен начинаться с `1` (P2PKH, mainnet).
- Встроенная проверка Base58Check контрольной суммы.

**Для Bitcoin (режим 35910 — P2PKH / P2SH / Bech32):**

Модуль 35910 поддерживает три формата Bitcoin-адресов в одном хеш-файле (можно смешивать):

```
1BKkWJS4VZKTr9fi9g5UhQ8Y1EGsNuor76
3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy
bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq
```

- **P2PKH** (`1...`): Base58Check, версия 0x00, длина 26–34 символа.
- **P2SH** (`3...`): Base58Check, версия 0x05, длина ~34 символа.
- **Bech32** (`bc1q...`): нативный SegWit v0, длина 42 символа.
- Встроенная проверка контрольной суммы для всех трёх форматов.

**Для Ethereum (режимы 35902, 35903, 35904, 35911):**

Каждая строка содержит один Ethereum-адрес в шестнадцатеричном формате с префиксом `0x`:

```
0x9c7002ea607c998e062793c420116b66f92421ac
0xacc6378af93c8cdb42d429625cd531038531a1db
0xb238859ca7d4d8fa1af573c6e522b4c52fd58f0a
```

- Длина адреса: 42 символа (включая префикс `0x`).
- После `0x` следуют ровно 40 шестнадцатеричных символов (строчные `a-f` и цифры `0-9`).
- Префикс `0x` обязателен.

**Размер базы:** Hashcat поддерживает загрузку больших списков адресов (например, 30 000 000 адресов). Файл должен умещаться в оперативную память. Рекомендуется использовать SSD для быстрой загрузки.

**Расположение файла:** Файл с адресами может находиться в любом месте файловой системы. Путь к нему указывается в командной строке hashcat.

#### Примеры использования ####

##### Режим 35900 — Bitcoin Brainwallet (SHA-256) #####

Парольная фраза хешируется через SHA-256 для получения приватного ключа Bitcoin.

**Пример 1: Атака по словарю**
```bash
./hashcat -m 35900 -a 0 bitcoin_addresses.txt wordlist.txt
```
Здесь `bitcoin_addresses.txt` — файл со списком Bitcoin-адресов (по одному на строку), `wordlist.txt` — словарь с парольными фразами.

**Пример 2: Атака по маске (брутфорс)**
```bash
./hashcat -m 35900 -a 3 bitcoin_addresses.txt ?a?a?a?a?a?a
```
Перебор всех комбинаций из 6 печатных ASCII-символов.

**Пример 3: Комбинаторная атака**
```bash
./hashcat -m 35900 -a 1 bitcoin_addresses.txt words_left.txt words_right.txt
```
Каждое слово из `words_left.txt` комбинируется с каждым словом из `words_right.txt`.

**Пример 4: Атака по словарю с правилами**
```bash
./hashcat -m 35900 -a 0 bitcoin_addresses.txt wordlist.txt -r rules/best64.rule
```
Применение правил трансформации к словарю.

**Пример 5: Атака по маске с инкрементом длины**
```bash
./hashcat -m 35900 -a 3 bitcoin_addresses.txt ?l?l?l?l?l?l?l?l --increment --increment-min 4
```
Перебор строчных слов длиной от 4 до 8 символов.

##### Режим 35901 — Bitcoin Brainwallet (SHA3-256) #####

Парольная фраза хешируется через SHA3-256 для получения приватного ключа Bitcoin.

**Пример 1: Атака по словарю**
```bash
./hashcat -m 35901 -a 0 bitcoin_addresses.txt wordlist.txt
```

**Пример 2: Атака по словарю с правилами**
```bash
./hashcat -m 35901 -a 0 bitcoin_addresses.txt wordlist.txt -r rules/best64.rule
```
Применение правил трансформации к каждому слову из словаря.

**Пример 3: Атака по маске с пользовательскими наборами символов**
```bash
./hashcat -m 35901 -a 3 bitcoin_addresses.txt -1 ?l?d ?1?1?1?1?1?1?1?1
```
Перебор 8-символьных строк из строчных букв и цифр.

**Пример 4: Комбинаторная атака**
```bash
./hashcat -m 35901 -a 1 bitcoin_addresses.txt words1.txt words2.txt
```
Комбинирование слов из двух словарей.

**Пример 5: Атака по маске с инкрементом длины**
```bash
./hashcat -m 35901 -a 3 bitcoin_addresses.txt ?a?a?a?a?a?a --increment --increment-min 3
```
Перебор ASCII-символов длиной от 3 до 6 символов.

##### Режим 35902 — Ethereum Brainwallet (Keccak-256) #####

Парольная фраза хешируется через Keccak-256 для получения приватного ключа Ethereum.

**Пример 1: Атака по словарю**
```bash
./hashcat -m 35902 -a 0 ethereum_addresses.txt wordlist.txt
```
Здесь `ethereum_addresses.txt` — файл с Ethereum-адресами (формат `0x...`, по одному на строку).

**Пример 2: Атака по маске**
```bash
./hashcat -m 35902 -a 3 ethereum_addresses.txt ?a?a?a?a?a?a?a
```
Перебор всех 7-символьных парольных фраз.

**Пример 3: Атака по словарю с правилами**
```bash
./hashcat -m 35902 -a 0 ethereum_addresses.txt wordlist.txt -r rules/dive.rule
```

**Пример 4: Комбинаторная атака**
```bash
./hashcat -m 35902 -a 1 ethereum_addresses.txt words_part1.txt words_part2.txt
```
Каждое слово из `words_part1.txt` комбинируется с каждым словом из `words_part2.txt`.

**Пример 5: Атака по маске с инкрементом длины**
```bash
./hashcat -m 35902 -a 3 ethereum_addresses.txt ?l?l?l?l?l?l?l?l --increment --increment-min 3
```
Перебор строчных слов длиной от 3 до 8 символов.

##### Режим 35903 — Ethereum Brainwallet (SHA-256) #####

Парольная фраза хешируется через SHA-256 для получения приватного ключа Ethereum.

**Пример 1: Атака по словарю**
```bash
./hashcat -m 35903 -a 0 ethereum_addresses.txt wordlist.txt
```

**Пример 2: Атака по словарю с правилами**
```bash
./hashcat -m 35903 -a 0 ethereum_addresses.txt wordlist.txt -r rules/best64.rule
```
Применение правил трансформации к словарю.

**Пример 3: Комбинаторная атака**
```bash
./hashcat -m 35903 -a 1 ethereum_addresses.txt words_part1.txt words_part2.txt
```

**Пример 4: Атака по маске (брутфорс)**
```bash
./hashcat -m 35903 -a 3 ethereum_addresses.txt ?a?a?a?a?a?a
```
Перебор всех комбинаций из 6 печатных ASCII-символов.

**Пример 5: Атака по маске с инкрементом длины**
```bash
./hashcat -m 35903 -a 3 ethereum_addresses.txt ?a?a?a?a?a?a?a?a --increment --increment-min 4
```
Перебор парольных фраз длиной от 4 до 8 символов.

##### Режим 35904 — Ethereum Brainwallet (SHA3-256) #####

Парольная фраза хешируется через SHA3-256 для получения приватного ключа Ethereum.

**Пример 1: Атака по словарю**
```bash
./hashcat -m 35904 -a 0 ethereum_addresses.txt wordlist.txt
```

**Пример 2: Атака по маске**
```bash
./hashcat -m 35904 -a 3 ethereum_addresses.txt ?l?l?l?l?l?l
```
Перебор 6-символьных строчных слов.

**Пример 3: Атака по словарю с правилами**
```bash
./hashcat -m 35904 -a 0 ethereum_addresses.txt wordlist.txt -r rules/rockyou-30000.rule
```

**Пример 4: Комбинаторная атака**
```bash
./hashcat -m 35904 -a 1 ethereum_addresses.txt words_left.txt words_right.txt
```
Комбинирование слов из двух словарей.

**Пример 5: Атака по маске с инкрементом длины**
```bash
./hashcat -m 35904 -a 3 ethereum_addresses.txt ?d?d?d?d?d?d?d?d --increment --increment-min 4
```
Перебор числовых фраз длиной от 4 до 8 цифр.

##### Режим 35910 — Bitcoin Brainwallet (BLAKE2b-256, P2PKH/Bech32/P2SH) #####

Парольная фраза хешируется через BLAKE2b-256 для получения приватного ключа Bitcoin. Поддерживаются форматы адресов P2PKH (`1...`), P2SH (`3...`) и Bech32 (`bc1q...`).

**Пример 1: Атака по словарю (P2PKH-адреса)**
```bash
./hashcat -m 35910 -a 0 bitcoin_addresses_p2pkh.txt wordlist.txt
```

**Пример 2: Атака по словарю (Bech32-адреса)**
```bash
./hashcat -m 35910 -a 0 bitcoin_addresses_bech32.txt wordlist.txt
```

**Пример 3: Атака по маске (брутфорс)**
```bash
./hashcat -m 35910 -a 3 bitcoin_addresses.txt ?a?a?a?a?a?a
```
Перебор всех комбинаций из 6 печатных ASCII-символов.

**Пример 4: Атака по словарю с правилами**
```bash
./hashcat -m 35910 -a 0 bitcoin_addresses.txt wordlist.txt -r rules/best64.rule
```

**Пример 5: Атака по маске с инкрементом длины**
```bash
./hashcat -m 35910 -a 3 bitcoin_addresses.txt ?l?l?l?l?l?l?l?l --increment --increment-min 4
```
Перебор строчных слов длиной от 4 до 8 символов.

##### Режим 35911 — Ethereum Brainwallet (BLAKE2s-256) #####

Парольная фраза хешируется через BLAKE2s-256 для получения приватного ключа Ethereum.

**Пример 1: Атака по словарю**
```bash
./hashcat -m 35911 -a 0 ethereum_addresses.txt wordlist.txt
```

**Пример 2: Атака по маске**
```bash
./hashcat -m 35911 -a 3 ethereum_addresses.txt ?a?a?a?a?a?a?a
```
Перебор всех 7-символьных парольных фраз.

**Пример 3: Атака по словарю с правилами**
```bash
./hashcat -m 35911 -a 0 ethereum_addresses.txt wordlist.txt -r rules/best64.rule
```

**Пример 4: Комбинаторная атака**
```bash
./hashcat -m 35911 -a 1 ethereum_addresses.txt words_part1.txt words_part2.txt
```

**Пример 5: Атака по маске с инкрементом длины**
```bash
./hashcat -m 35911 -a 3 ethereum_addresses.txt ?l?l?l?l?l?l?l?l --increment --increment-min 3
```
Перебор строчных слов длиной от 3 до 8 символов.

##### Режим 35905 — Bitcoin Private Key Hex + Reversed #####

На вход подаётся 64-символьная строка в hex-формате — приватный ключ Bitcoin (256 бит).
Для каждого кандидата автоматически проверяются два варианта:
- Ключ в исходном виде
- Ключ с побайтовым реверсом

Поддерживаются форматы адресов: P2PKH (`1...`), P2SH (`3...`), Bech32 (`bc1q...`).

**Формат входного словаря** — каждая строка содержит ровно 64 hex-символа:
```
127e6fbfe24a750e72930c220a8e138275656b8e5d8f48a98c3c92df2caba935
0000000000000000000000000000000000000000000000000000000000000001
a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2
```

**Формат базы адресов (хеш-файл)** — такой же, как для режима 35910:
```
1CkwUnESKuVFyn3PVm1fyyMtXx6CT2STg7
3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy
bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq
```

**Пример 1: Атака по словарю (файл с приватными ключами)**
```bash
./hashcat -m 35905 -a 0 bitcoin_addresses.txt private_keys.txt
```
`private_keys.txt` — файл с hex-ключами (64 символа на строку), `bitcoin_addresses.txt` — база целевых Bitcoin-адресов.

**Пример 2: Атака с правилами (мутации ключей)**
```bash
./hashcat -m 35905 -a 0 bitcoin_addresses.txt private_keys.txt -r rules/best64.rule
```

**Пример 3: Комбинаторная атака (склейка двух половин ключа)**
```bash
./hashcat -m 35905 -a 1 bitcoin_addresses.txt first_half.txt second_half.txt
```
Каждая строка `first_half.txt` = 32 hex-символа, `second_half.txt` = 32 hex-символа.

**Пример 4: Брутфорс по маске (UNIX)**
```bash
./hashcat -m 35905 -a 3 bitcoin_addresses.txt 0000000000000000000000000000000000000000000000000000000000?h?h?h?h?h?h
```
Перебирает последние 3 байта ключа (6 hex-символов).

**Пример 4 (Windows):**
```cmd
hashcat.exe -m 35905 -a 3 bitcoin_addresses.txt 0000000000000000000000000000000000000000000000000000000000?h?h?h?h?h?h
```

**Самотест (проверка корректности работы модуля):**
```bash
./hashcat -m 35905 --self-test-disable -a 0 1CkwUnESKuVFyn3PVm1fyyMtXx6CT2STg7 keys.txt
```
Где `keys.txt` содержит строку: `127e6fbfe24a750e72930c220a8e138275656b8e5d8f48a98c3c92df2caba935`

##### Режим 35906 — Ethereum Private Key Hex + Reversed #####

На вход подаётся 64-символьная строка в hex-формате — приватный ключ Ethereum (256 бит).
Для каждого кандидата автоматически проверяются два варианта:
- Ключ в исходном виде
- Ключ с побайтовым реверсом

**Формат входного словаря** — каждая строка содержит ровно 64 hex-символа:
```
127e6fbfe24a750e72930c220a8e138275656b8e5d8f48a98c3c92df2caba935
0000000000000000000000000000000000000000000000000000000000000001
a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2
```

**Формат базы адресов (хеш-файл)** — Ethereum-адреса с префиксом `0x`:
```
0xacc6378af93c8cdb42d429625cd531038531a1db
0x9c7002ea607c998e062793c420116b66f92421ac
0xb238859ca7d4d8fa1af573c6e522b4c52fd58f0a
```

**Пример 1: Атака по словарю (файл с приватными ключами)**
```bash
./hashcat -m 35906 -a 0 ethereum_addresses.txt private_keys.txt
```

**Пример 2: Атака с правилами**
```bash
./hashcat -m 35906 -a 0 ethereum_addresses.txt private_keys.txt -r rules/best64.rule
```

**Пример 3: Комбинаторная атака**
```bash
./hashcat -m 35906 -a 1 ethereum_addresses.txt first_half.txt second_half.txt
```

**Пример 4: Брутфорс по маске (UNIX)**
```bash
./hashcat -m 35906 -a 3 ethereum_addresses.txt 000000000000000000000000000000000000000000000000000000000000?h?h?h?h
```
Перебирает последние 2 байта ключа (4 hex-символа).

**Пример 4 (Windows):**
```cmd
hashcat.exe -m 35906 -a 3 ethereum_addresses.txt 000000000000000000000000000000000000000000000000000000000000?h?h?h?h
```

**Самотест:**
```bash
./hashcat -m 35906 --self-test-disable -a 0 0xacc6378af93c8cdb42d429625cd531038531a1db keys.txt
```
Где `keys.txt` содержит строку: `127e6fbfe24a750e72930c220a8e138275656b8e5d8f48a98c3c92df2caba935`

#### Гибридные атаки (Hybrid Attacks) ####

Гибридные атаки комбинируют словарь с маской, что позволяет эффективно перебирать пароли, состоящие из запоминаемого слова и предсказуемого суффикса/префикса (например, год, PIN-код, спецсимвол).

**Режим -a 6 (Hybrid Wordlist + Mask)** — добавляет к каждому слову из словаря маску справа:

```
Формат: ./hashcat -a 6 -m <MODE> <HASH_FILE> <WORDLIST> <MASK>
```

##### Примеры для всех модулей #####

**Режим 35900 (Bitcoin SHA-256):**
```bash
# Пример 1: Слово + 4 цифры (год или PIN)
./hashcat -m 35900 -a 6 bitcoin_addresses.txt wordlist.txt ?d?d?d?d

# Пример 2: Слово + спецсимвол + 2 цифры
./hashcat -m 35900 -a 6 bitcoin_addresses.txt wordlist.txt ?s?d?d

# Пример 3: Слово + год (2020-2026)
./hashcat -m 35900 -a 6 bitcoin_addresses.txt common_words.txt 202?d
```

**Режим 35901 (Bitcoin SHA3-256):**
```bash
# Пример: Слово + восклицательный знак + 3 цифры
./hashcat -m 35901 -a 6 bitcoin_addresses.txt wordlist.txt !?d?d?d
```

**Режим 35902 (Ethereum Keccak-256):**
```bash
# Пример 1: Слово + маска (4 hex-символа для адреса)
./hashcat -m 35902 -a 6 ethereum_addresses.txt wordlist.txt ?h?h?h?h

# Пример 2: Слово + год
./hashcat -m 35902 -a 6 ethereum_addresses.txt wordlist.txt ?d?d?d?d
```

**Режим 35903 (Ethereum SHA-256):**
```bash
# Пример: Слово + спецсимвол + год
./hashcat -m 35903 -a 6 ethereum_addresses.txt dictionary.txt ?s202?d
```

**Режим 35904 (Ethereum SHA3-256):**
```bash
# Пример: Слово + маска с пользовательским набором (год 1990-2026)
./hashcat -m 35904 -a 6 ethereum_addresses.txt wordlist.txt -1 12 ?d?d?1?d
```

**Режим 35910 (Bitcoin BLAKE2b-256):**
```bash
# Пример: Слово + год (2020-2026)
./hashcat -m 35910 -a 6 bitcoin_addresses.txt wordlist.txt 202?d
```

**Режим 35911 (Ethereum BLAKE2s-256):**
```bash
# Пример: Слово + 4 цифры
./hashcat -m 35911 -a 6 ethereum_addresses.txt wordlist.txt ?d?d?d?d
```

**Режим -a 7 (Hybrid Mask + Wordlist)** — добавляет маску слева от слова:

```
Формат: ./hashcat -a 7 -m <MODE> <HASH_FILE> <MASK> <WORDLIST>
```

##### Примеры для всех модулей #####

**Режим 35900 (Bitcoin SHA-256):**
```bash
# Пример: Год + слово
./hashcat -m 35900 -a 7 bitcoin_addresses.txt ?d?d?d?d wordlist.txt
```

**Режим 35902 (Ethereum Keccak-256):**
```bash
# Пример: Спецсимвол + слово
./hashcat -m 35902 -a 7 ethereum_addresses.txt ?s wordlist.txt
```

**Режим 35910 (Bitcoin BLAKE2b-256):**
```bash
# Пример: Год + слово
./hashcat -m 35910 -a 7 bitcoin_addresses.txt ?d?d?d?d wordlist.txt
```

**Режим 35911 (Ethereum BLAKE2s-256):**
```bash
# Пример: Спецсимвол + слово
./hashcat -m 35911 -a 7 ethereum_addresses.txt ?s wordlist.txt
```

**Когда использовать гибридные атаки:**
- Известны паттерны паролей: "слово + год", "название + цифры", "префикс + слово"
- Аудит корпоративных систем с политикой "слово + спецсимвол + цифры"
- Пользователи добавляют предсказуемые суффиксы к запоминаемым словам
- Гибриды эффективнее полного брутфорса при сохранении высокой вероятности успеха

**Маски символов:**
- `?l` = строчные буквы (a-z)
- `?u` = заглавные буквы (A-Z)
- `?d` = цифры (0-9)
- `?h` = строчные шестнадцатеричные (0-9a-f)
- `?H` = заглавные шестнадцатеричные (0-9A-F)
- `?s` = спецсимволы (!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~)
- `?a` = все печатные ASCII-символы (?l?u?d?s)
- `?b` = все 256 символов (0x00-0xFF)

#### Самопроверочные хеши (self-test) ####

Для парольной фразы `hashcat`:

| Режим | Пароль / Ключ | Адрес (ST_HASH) |
|-------|--------------|-----------------|
| 35900 | `hashcat` | `1CkwUnESKuVFyn3PVm1fyyMtXx6CT2STg7` |
| 35901 | `hashcat` | `1HsXwzdgD2ynmEbgMgLikdBDP7wWrFchTL` |
| 35902 | `hashcat` | `0x9c7002ea607c998e062793c420116b66f92421ac` |
| 35903 | `hashcat` | `0xacc6378af93c8cdb42d429625cd531038531a1db` |
| 35904 | `hashcat` | `0xb238859ca7d4d8fa1af573c6e522b4c52fd58f0a` |
| **35905** | `127e6fbfe24a750e72930c220a8e138275656b8e5d8f48a98c3c92df2caba935` | **`1CkwUnESKuVFyn3PVm1fyyMtXx6CT2STg7`** |
| **35906** | `127e6fbfe24a750e72930c220a8e138275656b8e5d8f48a98c3c92df2caba935` | **`0xacc6378af93c8cdb42d429625cd531038531a1db`** |
| 35910 | `hashcat` | `1BKkWJS4VZKTr9fi9g5UhQ8Y1EGsNuor76` |
| 35911 | `hashcat` | `0x4d10f53d02f5440505e6666696405a21ed910326` |

> **Примечание:** Для режимов 35905 и 35906 в поле «Пароль / Ключ» указан SHA-256 от строки `hashcat` в hex-формате. Это тот же приватный ключ, что используется в режиме 35900. Таким образом, режимы 35900 и 35905 находят одинаковый Bitcoin-адрес, но с разными типами входных данных: 35900 принимает текстовую парольную фразу, 35905 — готовый hex-ключ.

---

### Happy Cracking!
