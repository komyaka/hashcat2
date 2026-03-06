# Анализ модулей 35900–35904 — hashcat2

> **Язык:** Русский (техническая документация)  
> **Репозиторий:** hashcat2  
> **Последнее обновление:** 2026-03-06

---

## Содержание

1. [Общий обзор](#1-общий-обзор)
2. [Архитектура OpenCL-ядер](#2-архитектура-opencl-ядер)
3. [Модуль 35900 — Bitcoin Brainwallet (SHA-256)](#3-модуль-35900--bitcoin-brainwallet-sha-256)
4. [Модуль 35901 — Bitcoin Brainwallet (SHA3-256)](#4-модуль-35901--bitcoin-brainwallet-sha3-256)
5. [Модуль 35902 — Ethereum Brainwallet (Keccak-256)](#5-модуль-35902--ethereum-brainwallet-keccak-256)
6. [Модуль 35903 — Ethereum Brainwallet (SHA-256)](#6-модуль-35903--ethereum-brainwallet-sha-256)
7. [Модуль 35904 — Ethereum Brainwallet (SHA3-256)](#7-модуль-35904--ethereum-brainwallet-sha3-256)
8. [Сравнительный анализ](#8-сравнительный-анализ)
9. [Структура secp256k1_t](#9-структура-secp256k1_t)
10. [Поддерживаемые режимы атак](#10-поддерживаемые-режимы-атак)

---

## 1. Общий обзор

Модули 35900–35904 реализуют взлом Bitcoin и Ethereum brainwallet — схемы
деривации криптокошелька из текстовой парольной фразы. Общая структура атаки:

```
Пароль → Хеш-функция → Приватный ключ → secp256k1 → Публичный ключ → Адрес
```

Все модули разделяют общую библиотеку `inc_ecc_secp256k1.cl` и отличаются
лишь выбором хеш-функции для деривации приватного ключа и алгоритмом
формирования адреса (Bitcoin vs Ethereum).

### Соглашение об именовании файлов

Каждый модуль имеет 3 файла ядер для разных режимов атаки:
```
m{НОМЕР}_a0-pure.cl  — режим a0: атака по правилам (Rules-based)
m{НОМЕР}_a1-pure.cl  — режим a1: атака по словарю (Wordlist/Combinator)
m{НОМЕР}_a3-pure.cl  — режим a3: атака по маске (Mask/Brute-force)
```

Суффикс `-pure` означает «чистый» OpenCL без SIMD-расширений
(в отличие от `-optimized` вариантов, использующих векторизацию).

---

## 2. Архитектура OpenCL-ядер

### 2.1 Структура типового ядра

```c
// Секция определений
#define SECP256K1_TMPS_TYPE PRIVATE_AS  // хранить preG в приватной памяти GPU

// Секция includes (KERNEL_STATIC guard)
#ifdef KERNEL_STATIC
#include M2S(INCLUDE_PATH/inc_vendor.h)
#include M2S(INCLUDE_PATH/inc_types.h)
#include M2S(INCLUDE_PATH/inc_platform.cl)
#include M2S(INCLUDE_PATH/inc_common.cl)
#include M2S(INCLUDE_PATH/inc_rp.h)           // только для a0
#include M2S(INCLUDE_PATH/inc_rp.cl)           // только для a0
#include M2S(INCLUDE_PATH/inc_scalar.cl)
#include M2S(INCLUDE_PATH/inc_hash_*.cl)       // зависит от модуля
#include M2S(INCLUDE_PATH/inc_ecc_secp256k1.cl)
#endif

// Основное ядро (пример a0 - Rules)
KERNEL_FQ KERNEL_FA void m{НОМЕР}_mxx (KERN_ATTR_RULES ())
{
    const u64 gid = get_global_id(0);
    if (gid >= GID_CNT) return;

    // 1. Инициализация предвычисленных кратных G
    secp256k1_t preG;
    set_precomputed_basepoint_g(&preG);

    COPY_PW(pws[gid]);

    for (u32 il_pos = 0; il_pos < IL_CNT; il_pos++)
    {
        pw_t p = PASTE_PW;
        p.pw_len = apply_rules(rules_buf[il_pos].cmds, p.i, p.pw_len);

        // 2. Деривация приватного ключа (хеш-функция специфична для модуля)
        u32 prv_key[8];
        // ... hash(passphrase) → prv_key

        // 3. ECC: G × prv_key → публичный ключ
        u32 x[8], y[8];
        point_mul_xy(x, y, prv_key, &preG);

        // 4. Формирование адреса (Bitcoin или Ethereum)
        // ...

        // 5. Сравнение с целевым хешем
        if (r0 == search[0]) { ... }
    }
}
```

### 2.2 Макрос SECP256K1_TMPS_TYPE

```c
#define SECP256K1_TMPS_TYPE PRIVATE_AS
```

Определяет класс памяти для структуры `secp256k1_t` с предвычисленными
кратными базовой точки G (1G, 3G, 5G, 7G). При `PRIVATE_AS` каждый
GPU-поток хранит свою копию в регистрах/локальной памяти.

### 2.3 Макросы атрибутов ядра

| Макрос | Значение |
|---|---|
| `KERNEL_FQ` | `__kernel __attribute__((reqd_work_group_size(64, 1, 1)))` |
| `KERNEL_FA` | `__attribute__((vec_type_hint(u32x)))` |
| `KERN_ATTR_RULES()` | атрибуты ядра для режима правил (a0) |
| `KERN_ATTR_BASIC()` | атрибуты ядра для базовых режимов (a1, a3) |
| `GID_CNT` | количество глобальных рабочих элементов |

---

## 3. Модуль 35900 — Bitcoin Brainwallet (SHA-256)

### 3.1 Файлы модуля

```
OpenCL/m35900_a0-pure.cl   — Rules-based attack kernel
OpenCL/m35900_a1-pure.cl   — Wordlist/Combinator attack kernel
OpenCL/m35900_a3-pure.cl   — Mask/Brute-force attack kernel
modules/module_35900.c      — Дескриптор режима (C-уровень)
```

### 3.2 Полный список includes (m35900_a0-pure.cl)

```c
#ifdef KERNEL_STATIC
#include M2S(INCLUDE_PATH/inc_vendor.h)       // вендорные расширения OpenCL
#include M2S(INCLUDE_PATH/inc_types.h)        // u8, u16, u32, u64 типы
#include M2S(INCLUDE_PATH/inc_platform.cl)    // платформенные макросы
#include M2S(INCLUDE_PATH/inc_common.cl)      // общие утилиты
#include M2S(INCLUDE_PATH/inc_rp.h)           // прототипы правил (только a0)
#include M2S(INCLUDE_PATH/inc_rp.cl)          // движок правил (только a0)
#include M2S(INCLUDE_PATH/inc_scalar.cl)      // скалярные утилиты
#include M2S(INCLUDE_PATH/inc_hash_sha256.cl) // SHA-256 реализация
#include M2S(INCLUDE_PATH/inc_hash_ripemd160.cl) // RIPEMD-160 реализация
#include M2S(INCLUDE_PATH/inc_ecc_secp256k1.cl)  // ECC secp256k1
#endif
```

### 3.3 Вызываемые функции ECC

| Функция | Строки в .cl | Назначение |
|---|---|---|
| `set_precomputed_basepoint_g(&preG)` | 2297–2418 | Инициализировать 1G,3G,5G,7G |
| `point_mul_xy(x, y, prv_key, &preG)` | 2029–2169 | G×k → (x,y) в аффинных коорд. |

### 3.4 Полный конвейер вычислений

```
┌─────────────────────────────────────────────────────────┐
│                   МОДУЛЬ 35900                          │
│                                                         │
│  passphrase (переменная длина)                          │
│       │                                                 │
│       ▼ sha256_init/update_swap/final                   │
│  prv_key[8] = SHA-256(passphrase)  [32 байта]          │
│       │                                                 │
│       │  Преобразование byte order:                     │
│       │  for i in 0..8: prv_key[i] = swap32(sha_ctx.h[i])
│       │                                                 │
│       ▼ point_mul_xy(x, y, prv_key, &preG)              │
│  (x[8], y[8]) — аффинные координаты pubkey             │
│       │                                                 │
│       ▼ Сжатие публичного ключа:                        │
│  prefix = (y[0] & 1) ? 0x03 : 0x02                     │
│  compressed_pubkey[33] = {prefix} || {x[32]}           │
│       │                                                 │
│       │              ┌─────────────────────────┐        │
│       ▼              │  P2PKH / P2SH / Bech32  │        │
│  sha256(compressed_pubkey[33]) → tmp[32]        │        │
│       │              │                         │        │
│       ▼              │                         │        │
│  ripemd160(tmp[32]) → hash160[20]              │        │
│       │              └─────────────────────────┘        │
│       │                                                 │
│       ├─▶ P2PKH:  payload = 0x00 || hash160[20]         │
│       │           checksum = SHA256(SHA256(payload))[4] │
│       │           address = BASE58(payload || checksum) │
│       │                                                 │
│       ├─▶ P2SH:   (если salt_buf[0] == 1)               │
│       │           script = 0x00 0x14 hash160[20]        │
│       │           p2sh_hash160 = RIPEMD(SHA256(script)) │
│       │           address = BASE58(0x05||hash160||chk)  │
│       │                                                 │
│       └─▶ Bech32: witness_program = hash160[20]         │
│                   address = bech32_encode("bc",0,hash160)│
└─────────────────────────────────────────────────────────┘
```

### 3.5 Формат хеша для атаки

```
Хранится в digest:  hash160[20 байт] = RIPEMD160(SHA256(compressed_pubkey))
Формат сравнения:   первые 5 × u32 слова hash160
```

### 3.6 Обработка типов адресов

В модуле 35900 тип адреса кодируется в `salt_buf`:
```c
if (salt_buf[0] == 0) → P2PKH или Bech32
if (salt_buf[0] == 1) → P2SH (дополнительный hash160 через P2SH-скрипт)
```

---

## 4. Модуль 35901 — Bitcoin Brainwallet (SHA3-256)

### 4.1 Файлы модуля

```
OpenCL/m35901_a0-pure.cl
OpenCL/m35901_a1-pure.cl
OpenCL/m35901_a3-pure.cl
modules/module_35901.c
```

### 4.2 Полный список includes (m35901_a0-pure.cl)

```c
#ifdef KERNEL_STATIC
#include M2S(INCLUDE_PATH/inc_vendor.h)
#include M2S(INCLUDE_PATH/inc_types.h)
#include M2S(INCLUDE_PATH/inc_platform.cl)
#include M2S(INCLUDE_PATH/inc_common.cl)
#include M2S(INCLUDE_PATH/inc_rp.h)
#include M2S(INCLUDE_PATH/inc_rp.cl)
#include M2S(INCLUDE_PATH/inc_scalar.cl)
#include M2S(INCLUDE_PATH/inc_hash_sha256.cl)    // для HASH160 шага (SHA-256 pubkey)
#include M2S(INCLUDE_PATH/inc_hash_ripemd160.cl) // для HASH160 шага (RIPEMD pubkey)
#include M2S(INCLUDE_PATH/inc_ecc_secp256k1.cl)
#endif
```

> **Важно:** SHA3-256 реализован **инлайн внутри m35901_ax-pure.cl**, а не
> через отдельный include. Это предотвращает конфликты с другими Keccak-хешами.

### 4.3 Инлайн-реализация SHA3-256

```c
// В ядре m35901_a0-pure.cl, примерно строки 83–160:
CONSTANT_VK u32 keccakf_piln[24] = { /* константы перестановки */ };
CONSTANT_VK u32 keccakf_rotc[24] = { /* биты вращения */ };

DECLSPEC void keccak_transform_S(PRIVATE_AS u64 *st);  // Keccak-f[1600]

// SHA3-256: rate=136 байт, capacity=64 байт, padding=0x06
DECLSPEC void sha3_256_hash(
    PRIVATE_AS const u32 *pw,
    const u32 pw_len,
    PRIVATE_AS u32 *out
);
```

**Параметры SHA3-256:**
```
Алгоритм:    SHA3-256 (FIPS 202)
Rate:        136 байт = 1088 бит
Capacity:    512 бит
Padding:     0x06 (multi-rate padding для SHA3)
Output:      256 бит = 32 байта
```

### 4.4 Конвейер вычислений

```
passphrase → SHA3-256(rate=136, pad=0x06) → prv_key[32]
    → point_mul_xy(x,y,prv_key,&preG)
    → compressed_pubkey[33]
    → SHA-256 → RIPEMD-160 → hash160[20]
    → P2PKH / P2SH / Bech32 (идентично модулю 35900)
```

**Отличие от 35900:** только первый шаг (SHA-256 → SHA3-256 для ключа).

---

## 5. Модуль 35902 — Ethereum Brainwallet (Keccak-256)

### 5.1 Файлы модуля

```
OpenCL/m35902_a0-pure.cl
OpenCL/m35902_a1-pure.cl
OpenCL/m35902_a3-pure.cl
modules/module_35902.c
```

### 5.2 Полный список includes (m35902_a0-pure.cl)

```c
#ifdef KERNEL_STATIC
#include M2S(INCLUDE_PATH/inc_vendor.h)
#include M2S(INCLUDE_PATH/inc_types.h)
#include M2S(INCLUDE_PATH/inc_platform.cl)
#include M2S(INCLUDE_PATH/inc_common.cl)
#include M2S(INCLUDE_PATH/inc_rp.h)
#include M2S(INCLUDE_PATH/inc_rp.cl)
#include M2S(INCLUDE_PATH/inc_scalar.cl)
// ❌ НЕТ inc_hash_sha256.cl — не нужен
// ❌ НЕТ inc_hash_ripemd160.cl — не нужен
#include M2S(INCLUDE_PATH/inc_ecc_secp256k1.cl)
#endif
```

> **Ключевое отличие:** модуль 35902 не включает SHA256 и RIPEMD160,
> т.к. Ethereum не использует HASH160. Keccak реализован инлайн в ядре.

### 5.3 Инлайн Keccak-256

```c
// В m35902_a0-pure.cl, примерно строки 21–80:
CONSTANT_VK u64a keccakf_rndc[24] = {
    KECCAK_RNDC_00, ..., KECCAK_RNDC_23
};

// Keccak-256 (оригинальный Ethereum, padding 0x01)
// Rate = 136 байт, output = 32 байта
```

**Различие Keccak vs SHA3:**
```
Keccak-256 (Ethereum): padding = 0x01  ← используется в 35902
SHA3-256   (FIPS 202): padding = 0x06  ← используется в 35901/35904
```

### 5.4 Конвейер вычислений Ethereum

```
┌──────────────────────────────────────────────────────────┐
│               МОДУЛЬ 35902                               │
│                                                          │
│  passphrase                                              │
│       │                                                  │
│       ▼ Keccak-256 (pad=0x01, rate=136)                  │
│  prv_key[32 байта]                                       │
│       │                                                  │
│       ▼ point_mul_xy(x, y, prv_key, &preG)               │
│  (x[8], y[8]) — аффинные координаты                     │
│       │                                                  │
│       │  ⚠️ НЕ сжимать pubkey! Ethereum использует       │
│       │  несжатый формат без 0x04 префикса               │
│       │                                                  │
│       ▼ Конкатенация:                                    │
│  pubkey[64] = x[32] || y[32]  (little-endian 32-bit слова)
│       │                                                  │
│       ▼ Keccak-256(pubkey[64])                           │
│  eth_hash[32 байта]                                      │
│       │                                                  │
│       ▼ Взять последние 20 байт (bytes 12..31)           │
│  eth_address[20 байт]                                    │
│       │                                                  │
│       ▼ Сравнение:                                       │
│  compare eth_address с target digest                     │
└──────────────────────────────────────────────────────────┘
```

### 5.5 Порядок байт публичного ключа

```c
// Ethereum ожидает: x[0..31] || y[0..31]
// OpenCL хранит в u32[8] little-endian словах
// При передаче в Keccak необходима перестановка байт:
u32 pub64[16];
for (int i = 0; i < 8; i++) {
    pub64[i]   = hc_swap32(x[7-i]);  // x от старшего к младшему
    pub64[8+i] = hc_swap32(y[7-i]);  // y от старшего к младшему
}
```

---

## 6. Модуль 35903 — Ethereum Brainwallet (SHA-256)

### 6.1 Файлы модуля

```
OpenCL/m35903_a0-pure.cl
OpenCL/m35903_a1-pure.cl
OpenCL/m35903_a3-pure.cl
modules/module_35903.c
```

### 6.2 Полный список includes (m35903_a0-pure.cl)

```c
#ifdef KERNEL_STATIC
#include M2S(INCLUDE_PATH/inc_vendor.h)
#include M2S(INCLUDE_PATH/inc_types.h)
#include M2S(INCLUDE_PATH/inc_platform.cl)
#include M2S(INCLUDE_PATH/inc_common.cl)
#include M2S(INCLUDE_PATH/inc_rp.h)
#include M2S(INCLUDE_PATH/inc_rp.cl)
#include M2S(INCLUDE_PATH/inc_scalar.cl)
#include M2S(INCLUDE_PATH/inc_hash_sha256.cl)    // SHA-256 для деривации ключа
// ❌ НЕТ inc_hash_ripemd160.cl
#include M2S(INCLUDE_PATH/inc_ecc_secp256k1.cl)
#endif
```

### 6.3 Конвейер вычислений

```
passphrase
    │
    ▼ sha256_init/update_swap/final
prv_key[32] = SHA-256(passphrase)
    │
    ▼ point_mul_xy(x, y, prv_key, &preG)
pubkey_x[32], pubkey_y[32]  (несжатые координаты)
    │
    ▼ Keccak-256 (инлайн, padding 0x01)
eth_hash[32]
    │
    ▼ последние 20 байт
eth_address[20] → сравнение
```

**Гибрид:** SHA-256 для ключа (как Bitcoin), Keccak для адреса (как Ethereum).
Это представляет атаку на кошельки, деривирующие Ethereum-адрес из SHA-256-хеша
парольной фразы.

---

## 7. Модуль 35904 — Ethereum Brainwallet (SHA3-256)

### 7.1 Файлы модуля

```
OpenCL/m35904_a0-pure.cl
OpenCL/m35904_a1-pure.cl
OpenCL/m35904_a3-pure.cl
modules/module_35904.c
```

### 7.2 Полный список includes (m35904_a0-pure.cl)

```c
#ifdef KERNEL_STATIC
#include M2S(INCLUDE_PATH/inc_vendor.h)
#include M2S(INCLUDE_PATH/inc_types.h)
#include M2S(INCLUDE_PATH/inc_platform.cl)
#include M2S(INCLUDE_PATH/inc_common.cl)
#include M2S(INCLUDE_PATH/inc_rp.h)
#include M2S(INCLUDE_PATH/inc_rp.cl)
#include M2S(INCLUDE_PATH/inc_scalar.cl)
// ❌ НЕТ inc_hash_sha256.cl
// ❌ НЕТ inc_hash_ripemd160.cl
// SHA3 и Keccak реализованы инлайн
#include M2S(INCLUDE_PATH/inc_ecc_secp256k1.cl)
#endif
```

### 7.3 Конвейер вычислений

```
passphrase
    │
    ▼ SHA3-256 (FIPS 202, padding 0x06, rate=136)
prv_key[32]
    │
    ▼ point_mul_xy(x, y, prv_key, &preG)
pubkey_x[32], pubkey_y[32]
    │
    ▼ Keccak-256 (оригинальный, padding 0x01)
eth_hash[32] → последние 20 байт → eth_address[20]
```

**Двойной Keccak:** ключ через SHA3 (0x06), адрес через Keccak (0x01).

---

## 8. Сравнительный анализ

### 8.1 Сводная таблица includes

| Include | 35900 | 35901 | 35902 | 35903 | 35904 |
|---|---|---|---|---|---|
| `inc_vendor.h` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `inc_types.h` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `inc_platform.cl` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `inc_common.cl` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `inc_rp.h/.cl` | ✅(a0) | ✅(a0) | ✅(a0) | ✅(a0) | ✅(a0) |
| `inc_scalar.cl` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `inc_hash_sha256.cl` | ✅ | ✅ | ❌ | ✅ | ❌ |
| `inc_hash_ripemd160.cl` | ✅ | ✅ | ❌ | ❌ | ❌ |
| `inc_ecc_secp256k1.cl` | ✅ | ✅ | ✅ | ✅ | ✅ |
| SHA3/Keccak инлайн | ❌ | ✅ | ✅ | ✅ | ✅ |

### 8.2 Сравнение конвейеров

| Этап | 35900 | 35901 | 35902 | 35903 | 35904 |
|---|---|---|---|---|---|
| Деривация ключа | SHA-256 | SHA3-256 | Keccak-256 | SHA-256 | SHA3-256 |
| ECC умножение | G×k | G×k | G×k | G×k | G×k |
| Формат pubkey | сжатый | сжатый | несжатый | несжатый | несжатый |
| Хеш адреса | SHA256+RIPEMD | SHA256+RIPEMD | Keccak-256 | Keccak-256 | Keccak-256 |
| Формат адреса | BASE58/Bech32 | BASE58/Bech32 | 20 байт | 20 байт | 20 байт |
| Сеть | Bitcoin | Bitcoin | Ethereum | Ethereum | Ethereum |

### 8.3 Вызываемые функции ECC (общие для всех модулей)

| Функция | Файл | Строка | Вызывается из |
|---|---|---|---|
| `set_precomputed_basepoint_g` | inc_ecc_secp256k1.cl | 2297 | Все модули (init) |
| `point_mul_xy` | inc_ecc_secp256k1.cl | 2029 | Все модули (main loop) |
| `convert_to_window_naf` | inc_ecc_secp256k1.cl | 1919 | Из point_mul_xy |
| `point_get_coords` | inc_ecc_secp256k1.cl | 1475 | Из set_precomputed |
| `point_double` | inc_ecc_secp256k1.cl | 1104 | Из point_get_coords |
| `point_add` | inc_ecc_secp256k1.cl | 1291 | Из point_mul_xy |
| `mul_mod` | inc_ecc_secp256k1.cl | 593 | Из point_double, add |
| `sqr_mod` | inc_ecc_secp256k1.cl | 746 | Из point_double, add |
| `inv_mod` | inc_ecc_secp256k1.cl | 1000 | Из point_get_coords |
| `sqrt_mod` | inc_ecc_secp256k1.cl | 948 | Из transform_public |
| `add_mod` | inc_ecc_secp256k1.cl | 235 | Из всех арифм. функций |
| `sub_mod` | inc_ecc_secp256k1.cl | 214 | Из всех арифм. функций |
| `mod_512` | inc_ecc_secp256k1.cl | 281 | Из mul_mod, sqr_mod |

### 8.4 Цепочка вызовов при скалярном умножении

```
point_mul_xy(x, y, k, preG)         [строки 2029–2169]
  └── convert_to_window_naf(naf, k)  [строки 1919–2028]
  └── for each NAF digit:
        point_double(x, y, z)        [строки 1104–1290]
          ├── sqr_mod(r, a)          [строки 746–947]   ← 4× за удвоение
          ├── mul_mod(r, a, b)       [строки 593–745]   ← 4× за удвоение
          ├── add_mod(r, a, b)       [строки 235–280]   ← 6× за удвоение
          └── sub_mod(r, a, b)       [строки 214–234]   ← 3× за удвоение
        point_add(x1, y1, z1, x2, y2) [строки 1291–1474]
          ├── sqr_mod(r, a)          [строки 746–947]   ← 3× за сложение
          ├── mul_mod(r, a, b)       [строки 593–745]   ← 8× за сложение
          ├── add_mod(r, a, b)       [строки 235–280]   ← 7× за сложение
          └── sub_mod(r, a, b)       [строки 214–234]   ← 4× за сложение
```

---

## 9. Структура secp256k1_t

```c
// Определена в inc_ecc_secp256k1.h
typedef struct {
    // Предвычисленные аффинные координаты кратных базовой точки G
    // Хранятся для 1G, 3G, 5G, 7G (w-NAF с w=4)
    u32 xy[2 * 4 * 8];  // 4 точки × 2 координаты × 8 u32-слов
    // Итого: 256 байт на поток
} secp256k1_t;
```

**Расположение в памяти:**
```
xy[0..7]   = x-координата 1G (8 u32 = 32 байта)
xy[8..15]  = y-координата 1G (8 u32 = 32 байта)
xy[16..23] = x-координата 3G (8 u32 = 32 байта)
xy[24..31] = y-координата 3G (8 u32 = 32 байта)
xy[32..39] = x-координата 5G (8 u32 = 32 байта)
xy[40..47] = y-координата 5G (8 u32 = 32 байта)
xy[48..55] = x-координата 7G (8 u32 = 32 байта)
xy[56..63] = y-координата 7G (8 u32 = 32 байта)
```

С `SECP256K1_TMPS_TYPE = PRIVATE_AS` структура занимает 256 байт
в **приватной памяти** каждого GPU-потока (регистровый файл / local memory).

---

## 10. Поддерживаемые режимы атак

### 10.1 Режим a0 — Атака по правилам (Rules)

```
Файл ядра: m{НОМЕР}_a0-pure.cl
Атрибуты:  KERN_ATTR_RULES()
Функция:   apply_rules(rules_buf[il_pos].cmds, p.i, p.pw_len)
Пример:    hashcat -m 35900 -a 0 hash.txt wordlist.txt -r rules/best64.rule
```

Правила применяются к словам из словаря: обрезание, замена символов, l33tspeak и т.д.

### 10.2 Режим a1 — Атака по словарю/комбинатор (Wordlist/Combinator)

```
Файл ядра: m{НОМЕР}_a1-pure.cl
Атрибуты:  KERN_ATTR_BASIC()
Функция:   прямой перебор слов
Пример (словарь): hashcat -m 35900 -a 0 hash.txt wordlist.txt
Пример (комбинатор): hashcat -m 35900 -a 1 hash.txt dict1.txt dict2.txt
```

### 10.3 Режим a3 — Атака по маске (Mask/Brute-force)

```
Файл ядра: m{НОМЕР}_a3-pure.cl
Атрибуты:  KERN_ATTR_BASIC()
Маски:     ?l (строчные), ?u (прописные), ?d (цифры), ?s (спецсимволы)
Пример:    hashcat -m 35900 -a 3 hash.txt ?l?l?l?l?l?l?l?l
```

### 10.4 Матрица совместимости режимов и модулей

| Режим атаки | 35900 | 35901 | 35902 | 35903 | 35904 |
|---|---|---|---|---|---|
| a0 (Rules) | ✅ | ✅ | ✅ | ✅ | ✅ |
| a1 (Wordlist) | ✅ | ✅ | ✅ | ✅ | ✅ |
| a3 (Mask) | ✅ | ✅ | ✅ | ✅ | ✅ |
| a6 (Hybrid W+M) | ❓ | ❓ | ❓ | ❓ | ❓ |
| a7 (Hybrid M+W) | ❓ | ❓ | ❓ | ❓ | ❓ |

> ❓ — режимы a6/a7 требуют проверки поддержки в C-дескрипторах модулей.  
> **Как проверить:** открыть `src/modules/module_3590X.c` и убедиться, что  
> функция `module_attack_exec()` возвращает `ATTACK_EXEC_INSIDE_KERNEL`, а поле  
> `OPTS_TYPE` содержит нужные флаги (см. `include/types.h`, enum `opts_type_t`).  
> Альтернативно: `./hashcat -m 35900 --example-hashes` покажет список поддерживаемых режимов.

---

## Приложение A: Константы предвычисленной базовой точки

Из `inc_ecc_secp256k1.h`, координаты G и кратных G (1G, 3G, 5G, 7G):

```c
// 1G = Gx: 79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
//     Gy: 483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
#define SECP256K1_G_PRE_COMPUTED_00 0x16f81798  // Gx[0] (LSW)
#define SECP256K1_G_PRE_COMPUTED_07 0x79be667e  // Gx[7] (MSW)
#define SECP256K1_G_PRE_COMPUTED_08 0xfb10d4b8  // Gy[0] (LSW)
// ...

// 3G, 5G, 7G аналогично хранятся в SECP256K1_G_PRE_COMPUTED_{16..63}
```

---

## Приложение B: Тестовые векторы

Для верификации реализации можно использовать следующие векторы:

```
# Модуль 35900 (Bitcoin SHA-256 brainwallet)
Passphrase: "correct horse battery staple"
Private key: c4bbcb1fbec99d65bf59d85c8cb62ee2db963f0fe106f483d9afa73bd4e39a8a
Address (P2PKH): 1JwSSubhmg6iPtRjtyqhUYYH7bZg3Lfy1T

# Модуль 35902 (Ethereum Keccak-256 brainwallet)
Passphrase: "correct horse battery staple"
Private key: c4bbcb1fbec99d65bf59d85c8cb62ee2db963f0fe106f483d9afa73bd4e39a8a
Address: 0xa8b2e47F4a...  (вычислить)
```

> **Примечание:** Тестовые векторы подлежат верификации путём сравнения
> с эталонными реализациями (bitcoin-core, web3.py).
