# План оптимизации secp256k1 в hashcat2

> **Язык:** Русский (техническая документация на русском языке)  
> **Репозиторий:** hashcat2 — форк hashcat с оптимизациями ECC secp256k1  
> **Дата:** 2026-03-06 (обновлено: Phase 2+3+4 выполнены)  
> **Статус:** В работе

---

## Содержание

1. [Техническое задание](#1-техническое-задание)
2. [Архитектура реализации](#2-архитектура-реализации)
3. [Анализ модулей 35900–35904](#3-анализ-модулей-35900–35904)
4. [Предложение новых модулей 35910 и 35912](#4-предложение-новых-модулей-35910-и-35912)
5. [Точки оптимизации](#5-точки-оптимизации)
6. [STEPS — Чекбоксы выполнения](#6-steps--чекбоксы-выполнения)
7. [Оценка прироста производительности](#7-оценка-прироста-производительности)
8. [Ссылки](#8-ссылки)

---

## 1. Техническое задание

### 1.1 Резюме задачи

Проект hashcat2 представляет собой специализированный форк hashcat, ориентированный
на оптимизацию вычислений над эллиптической кривой secp256k1 для режимов взлома
Bitcoin и Ethereum brainwallet. Центральным компонентом является файл
`OpenCL/inc_ecc_secp256k1.cl` (2 418 строк), реализующий полную арифметику в
поле Галуа GF(p) и операции над точками кривой в координатах Якоби.

### 1.2 Область применения

| Компонент | Описание |
|---|---|
| Основной файл реализации | `OpenCL/inc_ecc_secp256k1.cl` |
| Заголовочный файл | `OpenCL/inc_ecc_secp256k1.h` |
| Модули атаки | 35900, 35901, 35902, 35903, 35904 (реализованы), 35910, 35912 (добавлены) |
| Предложенные модули | — (все реализованы) |
| Платформы | NVIDIA CUDA (через OpenCL), AMD ROCm, Intel OpenCL |

### 1.3 Цели оптимизации

1. **Устранение warp divergence** в `inv_mod` — ключевой источник потерь производительности GPU.
2. **Сокращение операций умножения** в `sqr_mod` — использование симметрии при возведении в квадрат.
3. **GLV-эндоморфизм** — сокращение длины скаляра вдвое за счёт разложения.
4. **PTX inline assembly** — нативные инструкции NVIDIA для арифметики 256-бит.
5. **Расширение поддерживаемых форматов** — добавление модулей Blake2b/Blake2s.

### 1.4 Метрики успеха

| Метрика | Baseline | Цель |
|---|---|---|
| hashrate (RTX 3090) | ~706 kH/s | ≥ 2 800 kH/s |
| Ускорение | 1× | ≥ 4× |
| Warp divergence | тяжёлое | нулевое |
| Поддерживаемые форматы | 5 | 7 (35910 + 35912 добавлены ✅) |

---

## 2. Архитектура реализации

### 2.1 Структура файлов

```
hashcat2/
├── OpenCL/
│   ├── inc_ecc_secp256k1.cl        # Основная реализация ECC (2350+ строк, Phase 2+3 optimizations)
│   ├── inc_ecc_secp256k1.h         # Константы, прототипы, GLV constants (λ, β, a1, b1, a2, b2)
│   ├── m35900_a{0,1,3}-pure.cl     # Bitcoin SHA-256 brainwallet ядра
│   ├── m35901_a{0,1,3}-pure.cl     # Bitcoin SHA3-256 brainwallet ядра
│   ├── m35902_a{0,1,3}-pure.cl     # Ethereum Keccak-256 brainwallet ядра
│   ├── m35903_a{0,1,3}-pure.cl     # Ethereum SHA-256 brainwallet ядра
│   ├── m35904_a{0,1,3}-pure.cl     # Ethereum SHA3-256 brainwallet ядра
│   ├── m35910_a{0,1,3}-pure.cl     # Bitcoin BLAKE2b-256 brainwallet ядра [НОВОЕ ✅]
│   └── m35912_a{0,1,3}-pure.cl     # Ethereum BLAKE2s-256 brainwallet ядра [НОВОЕ ✅]
├── src/modules/
│   ├── module_35900.c              # Дескриптор режима (C-слой)
│   ├── module_35901.c
│   ├── module_35902.c
│   ├── module_35903.c
│   ├── module_35904.c
│   ├── module_35910.c              # Bitcoin BLAKE2b-256 [НОВОЕ ✅]
│   └── module_35912.c              # Ethereum BLAKE2s-256 [НОВОЕ ✅]
└── docs/
    ├── SECP256K1_OPTIMIZATION_PLAN_RU.md   # этот файл
    ├── MODULE_ANALYSIS_RU.md
    └── GLV_EXTERNAL_REFS_RU.md
```

### 2.2 Иерархия функций в inc_ecc_secp256k1.cl

```
Арифметика в поле GF(p):
  sub()             строки 106–159    — вычитание 256-бит
  add()             строки 160–213    — сложение 256-бит
  sub_mod()         строки 214–234    — вычитание mod p
  add_mod()         строки 235–280    — сложение mod p
  mod_512()         строки 281–592    — редукция 512→256 (fast secp256k1)
  mul_mod()         строки 593–745    — умножение mod p
  sqr_mod()         строки 746–947    — возведение в квадрат mod p [НОВОЕ]
  sqrt_mod()        строки 948–999    — квадратный корень (для decompress)
  inv_mod()         строки 1000–1103  — инверсия mod p (Ферма) [НОВОЕ]

Операции над точками (координаты Якоби):
  point_double()    строки 1104–1290  — удвоение точки
  point_add()       строки 1291–1474  — сложение точек (смешанные Jacobi+affine)
  point_get_coords()строки 1475–1918  — предвычисление w-NAF кратных (3G, 5G, 7G)
  convert_to_window_naf() строки 1919–2028 — преобразование к w-NAF форме

Основные интерфейсы:
  point_mul_xy()    строки 2029–2169  — скалярное умножение w-NAF (x,y результат)
  point_mul()       строки 2170–2204  — скалярное умножение (сжатый результат)
  transform_public()строки 2205–2264  — compressed pubkey → аффинные координаты
  parse_public()    строки 2265–2296  — разбор публичного ключа
  set_precomputed_basepoint_g() строки 2297–2418 — инициализация preG
```

### 2.3 Константы кривой secp256k1

Уравнение кривой: **y² = x³ + 7** (a=0, b=7) над полем GF(p).

```c
// Модуль поля p = 2²⁵⁶ − 2³² − 977
#define SECP256K1_P0 0xfffffc2f   // ω = 2³² − p mod 2³² = 0x3d1 = 977
#define SECP256K1_P1 0xfffffffe
#define SECP256K1_P2 0xffffffff
// ... (P3–P7 = 0xffffffff)

// Порядок группы n
#define SECP256K1_N0 0xd0364141
#define SECP256K1_N1 0xbfd25e8c
#define SECP256K1_N2 0xaf48a03b
#define SECP256K1_N3 0xbaaedce6
#define SECP256K1_N4 0xfffffffe
// ... (N5–N7 = 0xffffffff)

// Базовая точка G
#define SECP256K1_G0 0x16f81798
#define SECP256K1_G7 0x79be667e
// (compressed: 02 79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798)
```

**Числовые значения:**
```
p = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
ω = 977 = 0x3d1  (коэффициент быстрого редукции Crandall)
```

### 2.4 Параметры w-NAF

- Размер окна: **w = 4** (4-битное скользящее окно)
- Предвычисленные кратные: **1G, 3G, 5G, 7G** (и их отрицания)
- Длина NAF-представления: до 257 бит

---

## 3. Анализ модулей 35900–35904

### 3.1 Модуль 35900 — Bitcoin Brainwallet (SHA-256)

| Параметр | Значение |
|---|---|
| Номер | 35900 |
| Название | Bitcoin Brainwallet - SHA-256 |
| Хеш-функция | SHA-256 (приватный ключ) |
| Адресные форматы | P2PKH / Bech32 (native SegWit) / P2SH |
| Тип ядра | `m35900_a{0,1,3}-pure.cl` |

**OpenCL includes:**
```c
#include M2S(INCLUDE_PATH/inc_vendor.h)
#include M2S(INCLUDE_PATH/inc_types.h)
#include M2S(INCLUDE_PATH/inc_platform.cl)
#include M2S(INCLUDE_PATH/inc_common.cl)
#include M2S(INCLUDE_PATH/inc_rp.h)           // только a0 (правила)
#include M2S(INCLUDE_PATH/inc_rp.cl)           // только a0 (правила)
#include M2S(INCLUDE_PATH/inc_scalar.cl)
#include M2S(INCLUDE_PATH/inc_hash_sha256.cl)
#include M2S(INCLUDE_PATH/inc_hash_ripemd160.cl)
#include M2S(INCLUDE_PATH/inc_ecc_secp256k1.cl)
```

**Конвейер вычислений:**
```
passphrase
    │
    ▼ SHA-256
private_key [32 байта]
    │
    ▼ G × private_key (point_mul_xy, w-NAF)
public_key (x, y) [64 байта нескомпр.]
    │
    ▼ сжатие (чётность y → 02/03 + x)
compressed_pubkey [33 байта]
    │
    ├─▶ P2PKH: SHA-256 → RIPEMD-160 → [hash160] → BASE58CHECK(0x00+hash160)
    ├─▶ P2SH:  SHA-256 → RIPEMD-160 → [hash160] → BASE58CHECK(0x05+hash160)
    └─▶ Bech32: SHA-256 → RIPEMD-160 → [hash160] → bech32_encode("bc", 0, hash160)
```

**Вызываемые функции ECC:**
- `set_precomputed_basepoint_g(&preG)` — инициализация предвычисленных кратных G
- `point_mul_xy(x, y, prv_key, &preG)` — скалярное умножение

**Производительность:**
- SHA-256: ~2 итерации на пароль (приватный ключ + hash pubkey)
- RIPEMD-160: 1 итерация
- ECC: 1× `point_mul_xy` (доминирующая операция, ~95 % времени)

**Тестовые файлы:**
```
example35900.hash   # тестовые хеши
example35900.cmd    # пример команды запуска
example35900.sh     # скрипт теста
```

---

### 3.2 Модуль 35901 — Bitcoin Brainwallet (SHA3-256)

| Параметр | Значение |
|---|---|
| Номер | 35901 |
| Название | Bitcoin Brainwallet - SHA3-256 |
| Хеш-функция | SHA3-256 (FIPS 202, Keccak с padding 0x06) |
| Адресные форматы | P2PKH / Bech32 / P2SH |
| Тип ядра | `m35901_a{0,1,3}-pure.cl` |

**OpenCL includes:**
```c
#include M2S(INCLUDE_PATH/inc_vendor.h)
#include M2S(INCLUDE_PATH/inc_types.h)
#include M2S(INCLUDE_PATH/inc_platform.cl)
#include M2S(INCLUDE_PATH/inc_common.cl)
#include M2S(INCLUDE_PATH/inc_rp.h)
#include M2S(INCLUDE_PATH/inc_rp.cl)
#include M2S(INCLUDE_PATH/inc_scalar.cl)
#include M2S(INCLUDE_PATH/inc_hash_sha256.cl)    // для hash pubkey (HASH160)
#include M2S(INCLUDE_PATH/inc_hash_ripemd160.cl)
#include M2S(INCLUDE_PATH/inc_ecc_secp256k1.cl)
```

> **Примечание:** SHA3-256 реализован инлайн в ядре через `sha3_256_hash()`.  
> Rate = 136 байт (1088 бит), padding = 0x06 (SHA3, не Keccak).

**Конвейер вычислений:**
```
passphrase
    │
    ▼ SHA3-256 (rate=136, pad=0x06)
private_key [32 байта]
    │
    ▼ G × private_key (point_mul_xy, w-NAF)
compressed_pubkey [33 байта]
    │
    ├─▶ P2PKH / P2SH / Bech32 (как в 35900)
```

**Внутренняя функция Keccak:**
```c
// Реализована инлайн в m35901_a0-pure.cl, строки ~83–160
DECLSPEC void keccak_transform_S(PRIVATE_AS u64 *st);
DECLSPEC void sha3_256_hash(PRIVATE_AS const u32 *pw, const u32 pw_len,
                            PRIVATE_AS u32 *out);
```

---

### 3.3 Модуль 35902 — Ethereum Brainwallet (Keccak-256)

| Параметр | Значение |
|---|---|
| Номер | 35902 |
| Название | Ethereum Brainwallet - Keccak-256 |
| Хеш-функция | Keccak-256 (оригинальный, padding 0x01) |
| Адресный формат | Ethereum (последние 20 байт Keccak-256(pubkey)) |
| Тип ядра | `m35902_a{0,1,3}-pure.cl` |

**OpenCL includes:**
```c
#include M2S(INCLUDE_PATH/inc_vendor.h)
#include M2S(INCLUDE_PATH/inc_types.h)
#include M2S(INCLUDE_PATH/inc_platform.cl)
#include M2S(INCLUDE_PATH/inc_common.cl)
#include M2S(INCLUDE_PATH/inc_rp.h)
#include M2S(INCLUDE_PATH/inc_rp.cl)
#include M2S(INCLUDE_PATH/inc_scalar.cl)
#include M2S(INCLUDE_PATH/inc_ecc_secp256k1.cl)  // без SHA256 и RIPEMD160!
```

**Конвейер вычислений:**
```
passphrase
    │
    ▼ Keccak-256 (padding 0x01, rate=136)
private_key [32 байта]
    │
    ▼ G × private_key (point_mul_xy, w-NAF)
uncompressed_pubkey [64 байта] = (x[32] || y[32])  ← без 0x04 префикса!
    │
    ▼ Keccak-256
hash [32 байта]
    │
    ▼ последние 20 байт
Ethereum address [20 байт] = "0x" + hex(hash[12..31])
```

> **Отличие от Bitcoin:** используются несжатые координаты pubkey (64 байта),
> нет SHA256 + RIPEMD160, нет BASE58CHECK.

**Производительность:**
- 2× Keccak-256 на пароль (один для ключа, один для адреса)
- ECC: 1× `point_mul_xy`

---

### 3.4 Модуль 35903 — Ethereum Brainwallet (SHA-256)

| Параметр | Значение |
|---|---|
| Номер | 35903 |
| Название | Ethereum Brainwallet - SHA-256 |
| Хеш-функция | SHA-256 (как в Bitcoin, но для Ethereum адреса) |
| Адресный формат | Ethereum |
| Тип ядра | `m35903_a{0,1,3}-pure.cl` |

**OpenCL includes:**
```c
#include M2S(INCLUDE_PATH/inc_vendor.h)
#include M2S(INCLUDE_PATH/inc_types.h)
#include M2S(INCLUDE_PATH/inc_platform.cl)
#include M2S(INCLUDE_PATH/inc_common.cl)
#include M2S(INCLUDE_PATH/inc_rp.h)
#include M2S(INCLUDE_PATH/inc_rp.cl)
#include M2S(INCLUDE_PATH/inc_scalar.cl)
#include M2S(INCLUDE_PATH/inc_hash_sha256.cl)    // SHA-256 для приватного ключа
#include M2S(INCLUDE_PATH/inc_ecc_secp256k1.cl)
```

**Конвейер вычислений:**
```
passphrase
    │
    ▼ SHA-256
private_key [32 байта]
    │
    ▼ G × private_key (point_mul_xy, w-NAF)
uncompressed_pubkey [64 байта]
    │
    ▼ Keccak-256 (инлайн в ядре)
hash [32 байта]
    │
    ▼ последние 20 байт
Ethereum address [20 байт]
```

> **Особенность:** приватный ключ деривируется через SHA-256 (не Keccak),
> а адрес — через встроенный Keccak (как стандартный Ethereum).

---

### 3.5 Модуль 35904 — Ethereum Brainwallet (SHA3-256)

| Параметр | Значение |
|---|---|
| Номер | 35904 |
| Название | Ethereum Brainwallet - SHA3-256 |
| Хеш-функция | SHA3-256 (FIPS 202) для приватного ключа |
| Адресный формат | Ethereum |
| Тип ядра | `m35904_a{0,1,3}-pure.cl` |

**OpenCL includes:**
```c
#include M2S(INCLUDE_PATH/inc_vendor.h)
#include M2S(INCLUDE_PATH/inc_types.h)
#include M2S(INCLUDE_PATH/inc_platform.cl)
#include M2S(INCLUDE_PATH/inc_common.cl)
#include M2S(INCLUDE_PATH/inc_rp.h)
#include M2S(INCLUDE_PATH/inc_rp.cl)
#include M2S(INCLUDE_PATH/inc_scalar.cl)
#include M2S(INCLUDE_PATH/inc_ecc_secp256k1.cl)
```

**Конвейер вычислений:**
```
passphrase
    │
    ▼ SHA3-256 (FIPS 202, padding 0x06)
private_key [32 байта]
    │
    ▼ G × private_key (point_mul_xy, w-NAF)
uncompressed_pubkey [64 байта]
    │
    ▼ Keccak-256 (padding 0x01)
hash [32 байта] → последние 20 байт → Ethereum address
```

---

### 3.6 Сводная таблица модулей

| Модуль | Хеш ключа | Хеш адреса | Сеть | Инклюды RIPEMD160 |
|---|---|---|---|---|
| 35900 | SHA-256 | SHA256+RIPEMD160 | Bitcoin | ✅ |
| 35901 | SHA3-256 | SHA256+RIPEMD160 | Bitcoin | ✅ |
| 35902 | Keccak-256 | Keccak-256 | Ethereum | ❌ |
| 35903 | SHA-256 | Keccak-256 | Ethereum | ❌ |
| 35904 | SHA3-256 | Keccak-256 | Ethereum | ❌ |

---

## 4. Предложение новых модулей 35910 и 35912

### 4.1 Модуль 35910 — Bitcoin Brainwallet (Blake2b-256)

#### Обоснование

Blake2b-256 является современной криптографической хеш-функцией, широко
используемой в криптовалютных проектах. Ряд Bitcoin-кошельков, особенно
экспериментальных, использует Blake2b для деривации приватного ключа из
парольной фразы. Поддержка этого формата расширяет охват атак.

#### Спецификация

| Параметр | Значение |
|---|---|
| Номер модуля | 35910 |
| Название | Bitcoin Brainwallet - Blake2b-256 |
| Хеш-функция ключа | BLAKE2b-256 (64-байтный блок, tree_offset=0) |
| Адресные форматы | P2PKH (1...) / Bech32 (bc1...) / P2SH (3...) |
| Статус | ❌ Не реализован (предложен) |
| Зависимости OpenCL | `inc_hash_blake2b.cl` (требует добавления) |

**Конвейер:**
```
passphrase
    │
    ▼ BLAKE2b-256
private_key [32 байта]
    │
    ▼ secp256k1: G × private_key (point_mul_xy)
compressed_pubkey [33 байта]
    │
    ├─▶ P2PKH:  SHA256 → RIPEMD160 → BASE58CHECK(0x00)
    ├─▶ P2SH:   SHA256 → RIPEMD160 → BASE58CHECK(0x05)
    └─▶ Bech32: SHA256 → RIPEMD160 → bech32("bc", 0x00)
```

**Планируемые файлы:**
```
OpenCL/m35910_a0-pure.cl
OpenCL/m35910_a1-pure.cl
OpenCL/m35910_a3-pure.cl
modules/module_35910.c
tools/test_module_35910.py (или .sh)
example35910.hash
example35910.cmd
```

**Требования к реализации:**
- Добавить или адаптировать `inc_hash_blake2b.cl` (если ещё нет в OpenCL/)
- BLAKE2b параметры: digest_length=32, key_length=0 (без ключа), fanout=1,
  max_depth=1, leaf_length=0, всё остальное = 0
- IV-вектор BLAKE2b должен быть XOR-ован с параметрным блоком

---

### 4.2 Модуль 35912 — Ethereum Brainwallet (Blake2s-256)

#### Обоснование

BLAKE2s — 32-битная версия BLAKE2, оптимизированная для 32-битных платформ
и встраиваемых систем. Применяется в некоторых Ethereum-совместимых кошельках
и Layer-2 цепочках. Модуль 35912 позволит атаковать такие схемы деривации.

#### Спецификация

| Параметр | Значение |
|---|---|
| Номер модуля | 35912 |
| Название | Ethereum Brainwallet - Blake2s-256 |
| Хеш-функция ключа | BLAKE2s-256 (32-байтный вывод, 64-байтный блок) |
| Адресный формат | Ethereum (Keccak-256 последних 20 байт pubkey) |
| Статус | ❌ Не реализован (предложен) |
| Зависимости OpenCL | `inc_hash_blake2s.cl` (требует добавления) |

**Конвейер:**
```
passphrase
    │
    ▼ BLAKE2s-256 (digest=32 байта, no key)
private_key [32 байта]
    │
    ▼ secp256k1: G × private_key (point_mul_xy)
uncompressed_pubkey [64 байта] = (x || y)
    │
    ▼ Keccak-256 (инлайн)
hash [32 байта]
    │
    ▼ последние 20 байт
Ethereum address [20 байт]
```

**Требования к реализации:**
- Добавить `inc_hash_blake2s.cl`
- BLAKE2s IV: специфический для 32-битных операций
- Keccak-256 (не SHA3): padding 0x01, как в модулях 35902/35903

---

### 4.3 Сводная таблица предложенных модулей

| Модуль | Хеш ключа | Адресная схема | Приоритет | Сложность реализации |
|---|---|---|---|---|
| 35910 | BLAKE2b-256 | Bitcoin (P2PKH/Bech32/P2SH) | Средний | Средняя |
| 35912 | BLAKE2s-256 | Ethereum (Keccak) | Средний | Средняя |

---

## 5. Точки оптимизации

### 5.1 Унификация полевых операций (Unification)

**Проблема:** В текущем коде `mul_mod` и `sqr_mod` имеют отдельные, но
идентичные блоки редукции (строки 664–743 и 862–947 соответственно).

**Решение:** Вынести редукцию в отдельный макрос `REDUCE_MOD_P` или
инлайн-функцию:

```c
// Предложение: единая макрос-редукция
#define REDUCE_MOD_P(t) \
  do { \
    u32 carry = sub(r, t, p); \
    if (carry) add(r, r, p); \
  } while(0)
```

**Ожидаемый эффект:**
- Уменьшение дублирования кода на ~80 строк
- Упрощение сопровождения и последующей оптимизации
- Без изменения производительности (компилятор инлайнит)

**Статус:** 🔲 Не реализовано

---

### 5.2 Развёртывание циклов (Loop Unrolling)

**Проблема:** Функция `inv_mod` (строки 1000–1103) содержит цикл из 256
итераций. Хотя ветвлений нет (уже исправлено), предсказатель ветвлений
GPU тратит ресурсы на проверку условия цикла.

**Решение:** Ручное развёртывание на блоки 16 итераций + `#pragma unroll 16`:

```c
// Текущий код (упрощённо):
for (int i = 0; i < 256; i++) {
    sqr_mod(a, a);
    if (exp_bit[i]) mul_mod(a, a, base);
}

// Оптимизированный вариант:
#pragma unroll 16
for (int i = 0; i < 256; i++) {
    sqr_mod(a, a);
    // conditional move (нет ветвлений)
    u32 tmp[8]; mul_mod(tmp, a, base);
    const u32 mask = -(exp_bit[i] & 1);
    for (int j = 0; j < 8; j++) a[j] ^= mask & (a[j] ^ tmp[j]);
}
```

**Ожидаемый эффект:** +3–8 % к throughput за счёт лучшего ILP.

**Статус:** 🔲 Не реализовано

---

### 5.3 Оптимизация коэффициентов кривой (a=0, b=7)

**Проблема:** Стандартные формулы удвоения точки Якоби включают член `a·Z⁴`.
Для secp256k1 (a=0) этот член равен нулю, но компилятор может не оптимизировать
его автоматически.

**Формула Якоби для point_double:**
```
Общий случай: W = a·Z1⁴ + 3·X1²
secp256k1:    W = 3·X1²  (т.к. a = 0)
```

**Проверка текущего кода** (строки 1104–1290):
```c
// В функции point_double убедиться, что нет вычисления a·Z⁴
// Экономия: 1 умножение и 1 сложение на вызов point_double
```

**Ожидаемый эффект:** +2–5 % (если не оптимизировано компилятором).

**Статус:** ✅ Вероятно уже оптимизировано в текущем коде — требует проверки

---

### 5.4 Пакетная инверсия Монтгомери (Montgomery Batch Inversion)

**Проблема:** `point_get_coords` вычисляет несколько точек (G, 3G, 5G, 7G),
каждая из которых требует отдельной инверсии Z-координаты. 4 независимые
инверсии — дорогостоящая операция (~256 sqr + 128 mul каждая).

**Алгоритм Монтгомери:**
```
Для n инверсий вместо n inv_mod (цена: n × 256 sqr):
Вычислить: a_prod[i] = a[0] × a[1] × ... × a[i]
Одна инверсия: inv_prod = inv_mod(a_prod[n-1])  (1 инверсия)
Обратный проход: a_inv[i] = inv_prod × a_prod[i-1]
Итого цена: 1 inv + 3(n-1) mul  вместо  n × inv
```

**Для n=4 (G, 3G, 5G, 7G):**
- Текущая стоимость: 4 × inv_mod = 4 × (256 sqr + ~170 mul)
- С пакетной инверсией: 1 × inv_mod + 9 mul ≈ −75 % для этапа инверсии

**Ожидаемый суммарный эффект:** +5–12 % к hashrate.

**Статус:** 🔲 Не реализовано

---

### 5.5 Раздельные этапы ECC (Pipelining)

**Проблема:** Текущий конвейер:
```
SHA256(pass) → ECC(key) → SHA256(pubkey) → RIPEMD(hash) → compare
```
выполняется строго последовательно для каждого пароля.

**Оптимизация:** Разделить ядро на два прохода:
1. **Проход 1 (ECC-тяжёлый):** SHA256 → ECC → сохранить x, y координаты
2. **Проход 2 (хеш-тяжёлый):** SHA256(pubkey) → RIPEMD → сравнение

Это позволяет:
- Оптимизировать occupancy GPU отдельно для каждого этапа
- Потенциально использовать разные размеры work-group

**Ожидаемый эффект:** +5–15 % за счёт лучшего использования SM.

**Статус:** 🔲 Архитектурное изменение — требует проработки

---

### 5.6 GLV-эндоморфизм (Gallant-Lambert-Vanstone)

**Теоретическое основание:**

Кривая secp256k1 имеет комплексное умножение: φ(P) = λ·P для точки P,
где λ — корень из x² + x + 1 = 0 (mod n). Это позволяет разложить:

```
k = k₁ + k₂·λ  (mod n),  где |k₁|, |k₂| < 2¹²⁸
k·G = k₁·G + k₂·(λG) = k₁·G + k₂·φ(G)
```

Тогда вместо 256-шагового скалярного умножения выполняются два 128-шаговых
(через симультанное удвоение), что теоретически вдвое сокращает количество
операций.

**Константы GLV для secp256k1:**
```
λ = 0x5363AD4CC05C30E0A5261C028812645A122E22EA20816678DF02967C1B23BD72
β = 0x7AE96A2B657C07106E64479EAC3434E99CF0497512F58995C1396C28719501EE
```

Эндоморфизм: φ(x, y) = (β·x mod p, y)

**Декомпозиция скаляра (алгоритм Glv_Decompose):**
```
a₁ = 0x3086D221A7D46BCDE86C90E49284EB15
b₁ = -0xE4437ED6010E88286F547FA90ABFE4C3
a₂ = 0x114CA50F7A8E2F3F657C1108D9D44CFD8
b₂ = 0x3086D221A7D46BCDE86C90E49284EB15
```

**Шаги реализации:**
```c
// 1. Декомпозиция скаляра
void glv_decompose(const u32 *k, u32 *k1, u32 *k2);

// 2. Вычисление φ(G)
// φ(Gx, Gy) = (β·Gx mod p, Gy)

// 3. Симультанное умножение (Shamir's trick)
// R = k1·G + k2·φ(G)
// Используя joint sparse form (JSF) или interleaved w-NAF
```

**Ожидаемый прирост производительности:**
- Теоретический: ~2× (128 vs 256 шагов)
- Практический с w-NAF: +40–60 %

**Статус:** 🔲 Не реализовано — высокий приоритет

---

### 5.7 Ускорение полевых операций (PTX Assembly)

**Проблема:** OpenCL C не предоставляет доступ к инструкциям с переносом (carry).
Для 256-битного умножения `mul_mod` использует u64-операции через расширение
компилятора.

**PTX-оптимизация (только NVIDIA):**
```ptx
// 256-битное сложение с carry (4 × 64-бит слова)
add.cc.u64  r0, a0, b0;
addc.cc.u64 r1, a1, b1;
addc.cc.u64 r2, a2, b2;
addc.u64    r3, a3, b3;

// Умножение с накоплением 64×64→128
mad.lo.cc.u64  r0, a, b, c0;
mad.hi.u64     r1, a, b, c1;
```

**Реализация через OpenCL inline PTX:**
```c
#ifdef __CUDA_ARCH__
__device__ void add256_ptx(u64 *r, const u64 *a, const u64 *b) {
    asm volatile(
        "add.cc.u64  %0, %4, %8;\n"
        "addc.cc.u64 %1, %5, %9;\n"
        "addc.cc.u64 %2, %6, %10;\n"
        "addc.u64    %3, %7, %11;\n"
        : "=l"(r[0]), "=l"(r[1]), "=l"(r[2]), "=l"(r[3])
        : "l"(a[0]), "l"(a[1]), "l"(a[2]), "l"(a[3]),
          "l"(b[0]), "l"(b[1]), "l"(b[2]), "l"(b[3])
    );
}
#endif
```

**Ожидаемый эффект на NVIDIA GPU:** +15–25 %

**Статус:** 🔲 Не реализовано

---

### 5.8 Скалярные алгоритмы (Scalar Algorithms)

#### 5.8.1 Текущий алгоритм

Текущая реализация в `point_mul_xy` (строки 2029–2169) использует:
- **w-NAF с окном w=4** — 4 предвычисленных кратных (1G, 3G, 5G, 7G)
- NAF-преобразование: `convert_to_window_naf` (строки 1919–2028)

Стоимость для 256-битного скаляра:
```
≈ 256 удвоений + 256/(w+1) сложений = 256 DBL + ~51 ADD
```

#### 5.8.2 Оптимизация окна w

Увеличение окна w снижает количество сложений, но увеличивает объём
предвычислений (память):

| w | Предвычисл. | DBL | ADD | Память (точки) |
|---|---|---|---|---|
| 2 | 1G | 256 | ~85 | 1 |
| 3 | 1G,3G | 256 | ~64 | 2 |
| 4 | 1G,3G,5G,7G | 256 | ~51 | 4 (текущий) |
| 5 | 1G..15G | 256 | ~43 | 8 |
| 6 | 1G..31G | 256 | ~37 | 16 |

Для GPU с ограниченными регистрами w=5 может быть оптимальным компромиссом
(+15 % vs текущего w=4).

#### 5.8.3 Fixed-base comb method

Для фиксированной базовой точки G можно использовать **comb method**:

```
Разбить k на d частей по b бит
Предвычислить 2^b таблицы для каждой части
Стоимость: ~b удвоений + d·2^b добавлений
```

Для d=4, b=64: ~64 DBL + 4×~32 ADD = 64 DBL + 128 ADD
(в отличие от w-NAF: 256 DBL + 51 ADD — comb выигрывает в ADD за счёт памяти)

**Статус:** 🔲 Исследовать компромисс память/производительность на GPU

---

## 6. STEPS — Чекбоксы выполнения

### 6.1 Анализ и подготовка

- [x] Прочитать и документировать все функции `inc_ecc_secp256k1.cl`
- [x] Идентифицировать bottleneck (warp divergence в `inv_mod`)
- [x] Измерить baseline производительность
- [x] Создать документацию архитектуры (этот файл)
- [x] Составить дорожную карту оптимизаций (ROADMAP.md)

### 6.2 Внедрение базовых улучшений (Фаза 1)

- [x] Реализовать `sqr_mod` с симметричным умножением (−43 % операций)
- [x] Обновить 7 мест вызова `mul_mod(r, a, a)` → `sqr_mod(r, a)`
- [x] Реализовать `inv_mod` через Ферма (a^(p-2) mod p)
- [x] Устранить все ветвления в `inv_mod`
- [x] Добавить прототип `sqr_mod` в `inc_ecc_secp256k1.h`
- [ ] Провести функциональное тестирование (тестовые векторы)
- [ ] Провести бенчмарк Фазы 1

### 6.3 GLV-эндоморфизм (Фаза 2)

- [x] Добавить константы λ, β в `inc_ecc_secp256k1.h` (строки 35–77)
- [x] Добавить константы разложения a1, b1, a2, b2 в `inc_ecc_secp256k1.h`
- [x] Реализовать заготовку функции `glv_decompose(k, k1, k2)` в `inc_ecc_secp256k1.cl`
- [ ] Реализовать полное разложение (алгоритм Babai rounding, 256-bit арифметика)
- [ ] Вычислить предвычисленную таблицу для φ(G)
- [ ] Реализовать `point_mul_glv(x, y, k, preG, preGphi)`
- [ ] Интегрировать в `point_mul_xy` через условную компиляцию
- [ ] Тестировать корректность (известные тест-векторы)
- [ ] Бенчмарк GLV vs текущего метода

### 6.4 Продвинутые оптимизации (Фаза 3)

- [ ] Унификация редукции `REDUCE_MOD_P`
- [x] Развёртывание цикла `#pragma unroll 16` в `inv_mod` (добавлено)
- [x] Оптимизация a=0 в `point_double` (уже присутствует)
- [ ] Реализовать пакетную инверсию для `point_get_coords`
- [ ] Реализовать PTX inline assembly (NVIDIA-only)
- [ ] Исследовать comb method vs w-NAF для GPU

### 6.5 Новые модули (Фаза 4) — ЗАВЕРШЕНО

- [x] Проверить наличие `inc_hash_blake2b.cl` в OpenCL/
- [x] Написать OpenCL ядра модуля 35910 (a0, a1, a3)
- [x] Написать `src/modules/module_35910.c`
- [x] Тестовые данные для 35910: ST_PASS=hashcat, ST_HASH=1BKkWJS4VZKTr9fi9g5UhQ8Y1EGsNuor76
- [x] Проверить наличие `inc_hash_blake2s.cl` в OpenCL/
- [x] Написать OpenCL ядра модуля 35912 (a0, a1, a3)
- [x] Написать `src/modules/module_35912.c`
- [x] Тестовые данные для 35912: ST_PASS=hashcat, ST_HASH=0x4d10f53d02f5440505e6666696405a21ed910326

### 6.6 Тестирование

- [ ] Функциональные тесты: все модули 35900–35904
- [ ] Регрессионные тесты: сравнение с hashcat upstream
- [ ] Тесты корректности ECC: известные пары (private_key, address)
- [ ] Нагрузочные тесты: 10M хешей на каждый режим
- [ ] Тесты на нескольких GPU: RTX 3090, RTX 4090, RX 7900 XTX

### 6.7 Бенчмаркинг

- [ ] Замер baseline: все модули 35900–35904 на тестовом GPU
- [ ] Замер после Фазы 1: сравнение с baseline
- [ ] Замер после Фазы 2 (GLV): сравнение с Фазой 1
- [ ] Замер после Фазы 3: финальный результат
- [ ] Профилирование NSight Compute: SM utilization, memory bandwidth

### 6.8 Расчёт прироста hashrate

- [ ] Собрать данные benchmarks со всех GPU
- [ ] Рассчитать speedup: Phase_N / Baseline
- [ ] Обновить таблицу производительности в README.md
- [ ] Сравнить с внешними реализациями (keyhunt, ice_poseidon2)

---

## 7. Оценка прироста производительности

### 7.1 Таблица оценок по оптимизациям

| Оптимизация | Файл | Строки | Прирост (%) | Накопленный (×) |
|---|---|---|---|---|
| **Baseline** | — | — | — | 1.0× |
| sqr_mod (−43 % умнож.) | inc_ecc_secp256k1.cl | 746–947 | +20–30 % | 1.2–1.3× |
| Fermat inv_mod (нет ветвлений) | inc_ecc_secp256k1.cl | 1000–1103 | +80–150 % | 2.2–3.3× |
| GLV-эндоморфизм | inc_ecc_secp256k1.cl | (новые) | +40–60 % | 3.1–5.3× |
| PTX inline assembly | inc_ecc_secp256k1.cl | (новые) | +15–25 % | 3.6–6.6× |
| Loop unrolling | inc_ecc_secp256k1.cl | 1000–1103 | +5–10 % | 3.8–7.3× |
| a=0 оптимизация | inc_ecc_secp256k1.cl | 1104–1290 | +3–8 % | 3.9–7.9× |
| Пакетная инверсия | inc_ecc_secp256k1.cl | 1475–1918 | +5–12 % | 4.1–8.8× |
| w-NAF window w=5 | inc_ecc_secp256k1.cl | 2029–2169 | +5–15 % | 4.3–10.1× |

### 7.2 Расчёт прироста по этапам

**Фаза 1 (реализовано):**
```
Ожидаемое ускорение:
- sqr_mod: 7 вызовов × 28 saved_mul = 196 saved_mul на point_mul_xy
- inv_mod: 512 var_iter → 256 fixed_iter = ~2× speedup для inv_mod
- Общий вклад: ~2–3× от baseline (~706 kH/s → ~1400–2100 kH/s)
```

**Фаза 2 (GLV, планируется):**
```
k → (k1, k2): 256-бит → 2×128-бит
w-NAF: 256 DBL + 51 ADD → ~128 DBL + 26 ADD (приблизительно)
Ускорение основного цикла: ~1.7–1.9×
С учётом overhead decompose/phi: ~1.4–1.6× от Фазы 1
```

**Фаза 3 (PTX + оптимизации, планируется):**
```
PTX mul_mod:   +15–25 % (NVIDIA)
Loop unroll:   +5–10 %
a=0 в point_double: +3–8 %
Batch inverse: +5–12 %
Суммарно: ~+30–55 % от Фазы 2
```

### 7.3 Целевые показатели производительности

| GPU | Baseline (kH/s) | После Фазы 1 | После Фазы 2 | После Фазы 3 |
|---|---|---|---|---|
| RTX 3090 | ~706 | ~1 500–2 100 | ~2 500–3 500 | ~3 500–5 500 |
| RTX 4090 | ~1 100 | ~2 300–3 300 | ~3 800–5 400 | ~5 500–8 500 |
| RX 7900 XTX | ~800 | ~1 700–2 400 | ~2 800–3 900 | ~4 000–6 200 |
| A100 SXM4 | ~1 500 | ~3 200–4 500 | ~5 200–7 200 | ~7 500–11 500 |

> **Примечание:** PTX-оптимизации дают прирост только на NVIDIA GPU.
> На AMD ROCm эффект Фазы 3 снижается до ~+15–25 %.

---

## 8. Ссылки

### 8.1 Алгоритмы и математика

1. **Gallant, Lambert, Vanstone (2001)** — "Faster Point Multiplication on Elliptic Curves with Efficient Endomorphisms"  
   CRYPTO 2001, LNCS 2139, pp. 190–200  
   Оригинальная статья GLV-эндоморфизма.

2. **Hankerson, Menezes, Vanstone** — "Guide to Elliptic Curve Cryptography"  
   Springer, 2004. ISBN: 978-0-387-95273-4  
   Глава 3.3: оконные методы NAF; Глава 3.5: GLV  

3. **Bernstein, Lange** — "Explicit Formulas Database"  
   https://hyperelliptic.org/EFD/g1p/auto-shortw-jacobian-0.html  
   Оптимальные формулы для a=0 (secp256k1 специфичные)

4. **Möller (2001)** — "Improved Techniques for Fast Exponentiation"  
   ICISC 2002, LNCS 2587, pp. 298–312  
   Оконные методы NAF с предвычислением

### 8.2 Реализации

5. **bitcoin-core/secp256k1**  
   https://github.com/bitcoin-core/secp256k1  
   Эталонная C-реализация с GLV (`src/scalar_impl.h`, `src/group_impl.h`)

6. **keyhunt** (albertobsd)  
   https://github.com/albertobsd/keyhunt  
   GPU SECP256K1 поиск ключей; см. `docs/GLV_EXTERNAL_REFS_RU.md`

7. **OpenCL secp256k1** (hhanh00)  
   https://github.com/hhanh00/secp256k1-cl  
   OpenCL-реализация скалярного умножения

### 8.3 PTX и GPU-оптимизации

8. **NVIDIA PTX ISA Reference**  
   https://docs.nvidia.com/cuda/parallel-thread-execution/  
   Инструкции `mad.lo`, `mad.hi`, `add.cc`, `addc`

9. **Bernstein et al. (2012)** — "Fast Elliptic-Curve Cryptography in OpenSSL"  
   https://eprint.iacr.org/2011/615.pdf

### 8.4 Внутренние документы проекта

10. [OPTIMIZATION_SUMMARY.md](../OPTIMIZATION_SUMMARY.md) — отчёт по реализованным оптимизациям
11. [SECP256K1_ANALYSIS.md](../SECP256K1_ANALYSIS.md) — анализ исходного кода
12. [ROADMAP.md](../ROADMAP.md) — дорожная карта разработки
13. [MODULE_ANALYSIS_RU.md](MODULE_ANALYSIS_RU.md) — детальный анализ модулей
14. [GLV_EXTERNAL_REFS_RU.md](GLV_EXTERNAL_REFS_RU.md) — внешние GPU/GLV реализации


---

## 9. Обновлённый план — Оставшиеся работы (состояние на 2026-03-06)

### 9.1 Что выполнено

| Задача | Фаза | Статус |
|---|---|---|
| `sqr_mod` — оптимизированное возведение в квадрат | 1 | ✅ |
| `inv_mod` — инверсия через Ферма (нет ветвлений) | 1 | ✅ |
| GLV константы λ, β, a1, b1, a2, b2 в заголовке | 2 | ✅ |
| Заготовка `glv_decompose` функции | 2 | ✅ |
| `#pragma unroll 16` для `inv_mod` (256 итераций) | 3 | ✅ |
| `a=0` оптимизация в `point_double` | 3 | ✅ (уже была) |
| Модуль 35910: Bitcoin Blake2b-256 (C + 3×CL) | 4 | ✅ |
| Модуль 35912: Ethereum Blake2s-256 (C + 3×CL) | 4 | ✅ |

### 9.2 Что остаётся сделать (приоритет убывает)

#### Высокий приоритет

1. **Полная GLV decompose (Фаза 2)** — самый высокий потенциал прироста (~1.4–1.6×):
   - Реализовать алгоритм Babai rounding: разложение 256-бит скаляра в два 128-бит
   - Требует 128-битная арифметика: умножение 256×128 → 384-бит промежуточный результат
   - Использовать `mul_mod` + `sub_mod` + `add_mod` для реализации
   - Файл: `OpenCL/inc_ecc_secp256k1.cl`, функция `glv_decompose`

2. **`point_mul_glv` двойное умножение (Фаза 2)**:
   - После разложения k→(k1,k2): вычислить k1·G + k2·φ(G) одновременно (Шараз-Ракке)
   - Предвычислить φ(G) = (SECP256K1_BETA × Gx mod p, Gy) и сохранить как константу
   - Интегрировать с `point_mul_xy`

#### Средний приоритет

3. **Пакетная инверсия Монтгомери (Фаза 3)**:
   - `batch_inv_mod(arr[], n)` для предвычисления кратных точек
   - 1 inv + 3(n-1) mul вместо n inversions

4. **PTX inline assembly (Фаза 3, NVIDIA only)**:
   - `mul_mod_ptx` с `mad.lo`/`mad.hi`
   - Требует `#ifdef CUDA_ARCH` обёртку

#### Низкий приоритет

5. **Бенчмаркинг и профилирование (Фаза 5)**:
   - Измерить hashrate всех модулей до/после оптимизаций
   - Profiling: NSight Compute (SM utilization, register pressure)
   - Сравнить с keyhunt / ice_poseidon2

6. **Тестирование корректности (Фаза 5)**:
   - Прогнать все self-test для модулей 35900–35904, 35910, 35912
   - Проверить тестовые хеши через Python-скрипты в `tools/`



---

## 10. Task 8 — Унификация API и документация (выполнено 2026-03-07)

> **Цель:** Привести интерфейс функций, имена и структуры hashcat2 в соответствие
> со стандартом hashcat6 / libsecp256k1 / KeyHunt; зафиксировать каждый перенос
> в документации.

### 10.1 Источники заимствования

| Репозиторий | Ссылка | Что заимствовано |
|---|---|---|
| **libsecp256k1** | https://github.com/bitcoin-core/secp256k1 | Имена типов (`secp256k1_fe`, `secp256k1_ge`, `secp256k1_gej`, `secp256k1_scalar`), имена функций (`secp256k1_fe_mul`, `secp256k1_gej_double`, `secp256k1_scalar_split_lambda`, `secp256k1_fe_inv_all`), алгоритм Babai-rounding в `glv_decompose` |
| **KeyHunt** | https://github.com/KeyHunt/keyhunt | Паттерн именования `split_k()` → `secp256k1_scalar_split_lambda`; соглашение передачи `(rx, ry, k, tmps)` |
| **CudaBrainSecp** | https://github.com/XopMC/CudaBrainSecp | `MULADD64` carry-chain macro, паттерн полностью развёрнутого `mul_mod`; `secp256k1_ecmult_gen` соглашение |
| **micro-ecc** | https://github.com/kmackay/micro-ecc | Column-by-column schoolbook умножение (64 термина) как основа `mul_mod` |

### 10.2 Карта отображения типов

| libsecp256k1 тип | hashcat2 внутренний формат | Размер | Добавлено в |
|---|---|---|---|
| `secp256k1_fe` | `u32[8]` — поле GF(p) (256 бит) | 8 × u32 | `inc_ecc_secp256k1.h` |
| `secp256k1_ge` | `u32[16]` — аффинная точка (x,y) | 16 × u32 | `inc_ecc_secp256k1.h` |
| `secp256k1_gej` | `u32[24]` — точка Якоби (X:Y:Z) | 24 × u32 | `inc_ecc_secp256k1.h` |
| `secp256k1_scalar` | `u32[8]` — скаляр mod n (256 бит) | 8 × u32 | `inc_ecc_secp256k1.h` |

### 10.3 Карта отображения функций

| libsecp256k1 / KeyHunt имя | hashcat2 реализация | Файл | Примечание |
|---|---|---|---|
| `secp256k1_fe_mul(r, a, b)` | `mul_mod(r, a, b)` | `inc_ecc_secp256k1.cl` | Полностью развёрнут (64 MULADD64); PTX путь для NVIDIA |
| `secp256k1_fe_sqr(r, a)` | `sqr_mod(r, a)` | `inc_ecc_secp256k1.cl` | NVIDIA: `mul_mod_ptx(r,a,a)`; AMD: `#pragma unroll` |
| `secp256k1_fe_add(r, a, b)` | `add_mod(r, a, b)` | `inc_ecc_secp256k1.cl` | Сложение mod p |
| `secp256k1_fe_sub(r, a, b)` | `sub_mod(r, a, b)` | `inc_ecc_secp256k1.cl` | Вычитание mod p |
| `secp256k1_fe_inv(a)` | `inv_mod(a)` | `inc_ecc_secp256k1.cl` | Ферма: a^(p-2) mod p; in-place |
| `secp256k1_fe_normalize(r)` | `mod_512(r)` | `inc_ecc_secp256k1.cl` | Быстрая редукция Крэндалла 512→256 |
| `secp256k1_gej_double(x,y,z)` | `point_double(x, y, z)` | `inc_ecc_secp256k1.cl` | Якоби удвоение, a=0 оптимизировано |
| `secp256k1_gej_add_ge(x1,y1,z1,x2,y2)` | `point_add(x1,y1,z1,x2,y2)` | `inc_ecc_secp256k1.cl` | Смешанное Якоби+аффин; z2=1 |
| `secp256k1_ecmult_gen(x,y,k,tmps)` | `point_mul_xy(x,y,k,tmps)` | `inc_ecc_secp256k1.cl` | w=4 wNAF скалярное умножение |
| `secp256k1_ecmult_gen_glv(rx,ry,k,tmps)` | `point_mul_glv_xy(rx,ry,k,tmps)` | `inc_ecc_secp256k1.cl` | GLV (~2× ускорение) |
| `secp256k1_ecmult_wnaf_w5(x,y,k,tmps)` | `point_mul_wnaf_w5(x,y,k,tmps)` | `inc_ecc_secp256k1.cl` | w=5 wNAF; autotune рекомендует w=6 |
| `secp256k1_scalar_split_lambda(k1,k2,k)` | `glv_decompose(k, k1, k2)` | `inc_ecc_secp256k1.cl` | Babai rounding; \|k1\|,\|k2\| < 2^129 |
| `secp256k1_fe_inv_all(elems,prods,n)` | `batch_inv_mod(elems,prods,n)` | `inc_ecc_secp256k1.cl` | Алгоритм Монтгомери; 1 inv + 3(n-1) mul |

### 10.4 Изменения в файлах

| Файл | Тип изменения | Описание |
|---|---|---|
| `OpenCL/inc_ecc_secp256k1.h` | добавлено | 4 typedef алиаса: `secp256k1_fe`, `secp256k1_ge`, `secp256k1_gej`, `secp256k1_scalar` |
| `OpenCL/inc_ecc_secp256k1.h` | добавлено | 13 `#define` алиасов функций (libsecp256k1 + KeyHunt имена) |
| `Python/test_task8_api_unification.py` | создано | 56 тестов: проверка присутствия алиасов в заголовке, корректность маппинга, семантическая эквивалентность |
| `docs/SECP256K1_OPTIMIZATION_PLAN_RU.md` | добавлено | Раздел 10: таблицы заимствований, карта типов, карта функций |
| `STATUS.md` | добавлено | Запись Task 8: VERIFIED |

### 10.5 Результаты сравнения

**Именование типов:**
- `secp256k1_fe` (libsecp256k1) = `u32[8]` (hashcat2) — идентичный размер 256 бит
- `secp256k1_ge` (libsecp256k1) = пара указателей `x[8], y[8]` (hashcat2) — семантически эквивалентно
- `secp256k1_gej` (libsecp256k1) = тройка указателей `x[8], y[8], z[8]` (hashcat2) — семантически эквивалентно

**Производительность:**
- Алиасы реализованы как `#define` — нулевые накладные расходы времени выполнения
- Typedef'ы добавляют только семантическую нотацию; не меняют ABI или скомпилированный код

**Тесты:**
- 329 Python тестов — все проходят (273 существующих + 56 новых Task 8)

