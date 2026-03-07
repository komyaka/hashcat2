# МАСТЕР-ПЛАН ОПТИМИЗАЦИИ hashcat2/secp256k1
## Для ИИ-агентов программистов

> **Версия:** 1.0  
> **Дата:** 2026-03-07  
> **Ветка:** `copilot/add-attack-modules-for-keys`

---

## Текущее состояние (инвентаризация)

### Файлы ECC (ядро OpenCL)

| Файл | Размер | Описание |
|---|---|---|
| `OpenCL/inc_ecc_secp256k1.cl` | ~115 500 байт | Основное ядро: field arithmetic, point ops, GLV, wNAF, batch inv |
| `OpenCL/inc_ecc_secp256k1.h` | — | Заголовок: константы, макросы, объявления функций |

### Модули m359*

| Модуль | OpenCL файлы | Host-файл | Описание |
|---|---|---|---|
| m35900 | a0/a1/a3-pure.cl | module_35900.c | BTC Brainwallet SHA-256 → P2PKH |
| m35901 | a0/a1/a3-pure.cl | module_35901.c | BTC Brainwallet SHA-256 → Bech32 |
| m35902 | a0/a1/a3-pure.cl | module_35902.c | BTC Brainwallet SHA-256 → P2SH |
| m35903 | a0/a1/a3-pure.cl | module_35903.c | BTC Brainwallet SHA-512 → P2PKH |
| m35904 | a0/a1/a3-pure.cl | module_35904.c | BTC Brainwallet SHA-512 → Bech32 |
| m35905 | a0/a1/a3-pure.cl | module_35905.c | BTC Private Key Hex → P2PKH |
| m35906 | a0/a1/a3-pure.cl | module_35906.c | BTC Private Key Hex → Bech32 |
| m35910 | a0/a1/a3-pure.cl | module_35910.c | BTC Brainwallet BLAKE2b-256 → P2PKH/Bech32/P2SH |
| m35912 | a0/a1/a3-pure.cl | module_35912.c | ETH Brainwallet BLAKE2s-256 |

### Python-инфраструктура

| Файл | Описание |
|---|---|
| `Python/test_regression_libsecp256k1.py` | 238+ регрессионных тестов (libsecp256k1 vectors, GLV, wNAF) |
| `Python/bench_secp256k1.py` | CPU reference benchmark: mul_mod, inv_mod, point_mul (std/GLV/wNAF) |
| `Python/test_field_arithmetic.py` | 42 edge/fuzz теста полевой арифметики |
| `Python/test_glv_decompose.py` | GLV scalar decomposition tests |
| `Python/test_wnaf_window.py` | wNAF window tests |
| `Python/test_shmem.py` | SHMEM basepoint tests |
| `Python/test_task7_regression_stability.py` | Stability regression tests |
| `Python/test_task8_api_unification.py` | API unification tests |

### Уже реализованные оптимизации

| Оптимизация | Файл | Описание | Прирост |
|---|---|---|---|
| `sqr_mod` | `inc_ecc_secp256k1.cl` | 36 mul вместо 64 (−43%) | −43% умножений |
| `inv_mod` Fermat + `#pragma unroll 16` | `inc_ecc_secp256k1.cl` | 256 фиксированных итераций, 0 ветвлений | — |
| `mul_mod_ptx` | `inc_ecc_secp256k1.cl` | NVIDIA PTX carry-chain (8×8) | +20–30% NVIDIA |
| `MULADD64` + развёрнутый `mul_mod` | `inc_ecc_secp256k1.cl` | 64 явных MULADD64, нет переменных циклов | +10–15% AMD |
| GLV endomorphism | `inc_ecc_secp256k1.cl` | `glv_decompose` + `point_mul_glv_xy` | +30–50% |
| `batch_inv_mod` | `inc_ecc_secp256k1.cl` | Montgomery's trick | −(n−1) inversions |
| wNAF w=5 | `inc_ecc_secp256k1.cl` | `point_mul_wnaf_w5` с предвычисленной таблицей | +15–20% |
| SHMEM basepoint | `inc_ecc_secp256k1.cl` | `point_mul_xy_lm` (m35910) | +5–10% |

---

## ФАЗА 1: Аудит и Стабилизация (Baseline)

### Задачи

1. **AUDIT-01** (`OpenCL/inc_ecc_secp256k1.cl`) — Проверить баланс скобок и корректность `#ifdef`/`#endif` блоков.
2. **AUDIT-02** (`OpenCL/inc_ecc_secp256k1.cl`) — Проверить корректность всех 13 замен `mul_mod` → `sqr_mod`.
3. **AUDIT-03** (`OpenCL/inc_ecc_secp256k1.cl`) — Проверить `inv_mod` Fermat chain: граничные случаи k=0, k=1, k=n-1.
4. **AUDIT-04** (`OpenCL/inc_ecc_secp256k1.cl`) — Проверить `mul_mod_ptx` carry-chain (DEFECT-01 из STATUS.md).
5. **AUDIT-05** (`OpenCL/inc_ecc_secp256k1.cl`) — Проверить корректность `glv_decompose` (сравнить с libsecp256k1).
6. **AUDIT-06** (`OpenCL/inc_ecc_secp256k1.h`) — Проверить все макросы `secp256k1_fe_mul`, `secp256k1_fe_sqr` и константы SECP256K1_P*, SECP256K1_N*.
7. **AUDIT-07** (`OpenCL/m35900`–`m35910`) — Проверить наличие `#define SECP256K1_TMPS_TYPE PRIVATE_AS`, включение `inc_ecc_secp256k1.cl`, a0/a1/a3 вариантов и host-файлов.
8. **TEST-01** (`Python/test_regression_libsecp256k1.py`) — Добавить edge case тесты (k=1, k=n-1, k=2).
9. **TEST-02** (`Python/test_regression_libsecp256k1.py`) — Добавить `inv_mod` специфические value-equality тесты.
10. **TEST-03** (`Python/test_regression_libsecp256k1.py`) — Добавить `batch_inv_mod` тесты для n=1, n=2, n=256.
11. **TEST-04** (`Python/test_regression_libsecp256k1.py`) — Добавить cross-validation `point_mul(k) == point_mul_glv(k)` для 20 random k.
12. **DOC-01** (`docs/OPTIMIZATION_MASTERPLAN.md`) — Создать данный файл.
13. **STATUS-01** (`STATUS.md`) — Обновить Phase 1 audit entry.

### Критерии прохождения (чеклист)

- [ ] Все `#ifdef`/`#endif` сбалансированы в `inc_ecc_secp256k1.cl`
- [ ] Все 13 `sqr_mod` замен корректны (нет ложных срабатываний)
- [ ] `inv_mod(1) == 1`, `inv_mod(p-1) == p-1`
- [ ] `batch_inv_mod` корректен для n=1, n=2, n=256
- [ ] `point_mul_glv(k) == point_mul(k)` для 20 random k
- [ ] Все существующие 238+ Python-тестов проходят
- [ ] `docs/OPTIMIZATION_MASTERPLAN.md` создан
- [ ] `STATUS.md` обновлён

### Команды верификации

```bash
# Запустить регрессионные тесты
python3 -m unittest Python/test_regression_libsecp256k1.py -v

# Запустить все Python-тесты
python3 -m unittest discover -s Python/ -p "test_*.py" -v

# Проверить баланс ifdef в OpenCL
grep -c '#ifdef\|#if ' OpenCL/inc_ecc_secp256k1.cl
grep -c '#endif' OpenCL/inc_ecc_secp256k1.cl
```

---

## ФАЗА 2: Оптимизация полевой арифметики (mul_mod / add / sub) ✅ ЗАВЕРШЕНА

### Задачи

1. ✅ **FIELD-01** — K1-специализированная редукция через `reduce_mod_p()`:
   - Файл: `OpenCL/inc_ecc_secp256k1.cl`
   - Реализовано: новая inline-функция `reduce_mod_p(r, c, p_arr)` — два branch-free
     прохода условного вычитания p, достаточных для c ∈ {0,1,2}.
   - Используется: `mul_mod()` и `sqr_mod()` вызывают `reduce_mod_p()` вместо циклов.

2. ✅ **FIELD-02** — AMD u64 carry-chain для `add()` и `sub()`:
   - `#elif 0` заменён на `#elif defined IS_AMD` в обоих функциях.
   - `add()`: развёрнутая u64 carry-chain — AMD компилятор генерирует `v_add_co_u32`/`v_addc_co_u32`.
   - `sub()`: развёрнутая u64 borrow-chain со знаковым сдвигом — AMD генерирует `v_sub_co_u32`/`v_subb_co_u32`.

3. ✅ **FIELD-03** — Полностью развёрнутый `sqr_mod()` без `#pragma unroll` циклов:
   - 16 явно развёрнутых колонок (column 0–15) с обработкой симметрии.
   - Диагональные члены (`a[i]^2`) — без удвоения; кросс-члены (`2*a[i]*a[j]`) — с overflow-safe удвоением.
   - Финальная редукция через `reduce_mod_p()`.

4. ✅ **FIELD-04** — Branch-free финальная редукция в `add_mod()`, `sub_mod()`, `mul_mod()`, `sqr_mod()`:
   - `add_mod()`: `mask = -(c | (borrow^1u))` — CMOV-паттерн, нет циклов и ветвлений.
   - `sub_mod()`: `mask = -(borrow)` — CMOV-паттерн, нет `if (c)` ветвления.
   - `mul_mod()`, `sqr_mod()`: `reduce_mod_p()` — два branch-free conditional-subtract прохода.

### Источники

| Источник | Что берём | Лицензия |
|---|---|---|
| [VanitySearch](https://github.com/JeanLucPons/VanitySearch) `IntMod.cpp` | `ModMulK1`, `ModSqK1`, K1-специализированная редукция | GPL-3.0 |
| [AMD GCN ISA manual](https://gpuopen.com/amd-isa-documentation/) | `v_add_co_u32`, `v_addc_co_u32` ASM | Public |
| [secp256k1-gpu-accelerator](https://github.com/brichard19/BitCrack) `ptx_macros.cu` | PTX register math | MIT |

### Ожидаемый прирост

- AMD: **+15–25%** (ModMulK1 + inline ASM)
- NVIDIA: **+5–10%** (branch-free reduction)
- Общий: **+10–20%**

---

## ФАЗА 3: Оптимизация point_mul (скалярное умножение)

### Задачи

1. **PMUL-01** — wNAF w=6 с SHMEM-таблицей:
   - Увеличить окно с 5 до 6 (таблица 32 точки вместо 16)
   - Хранить таблицу в `__local` (SHMEM) для уменьшения latency
   - Файл: `OpenCL/inc_ecc_secp256k1.cl`, новая функция `point_mul_wnaf_w6`

2. **PMUL-02** — Co-Z Jacobian coordinates (eprint 2011/338):
   - Реализовать `point_add_coz` и `point_double_coz` (одинаковый Z)
   - Экономия: устранение деления при сложении точек в цикле
   - Источник: Longa & Gebotys, "Efficient and Secure Algorithms for GLV-Based Scalar Multiplication and Their Implementation on GLV-GLS Curves", ePrint 2011/338

3. **PMUL-03** — Straus/Shamir для GLV (двойное скалярное умножение):
   - `point_mul_glv_xy` уже реализован через interleaved binary method
   - Ускорить через совместные таблицы Shamir: `w*G` для оба скаляра одновременно
   - Файл: `OpenCL/inc_ecc_secp256k1.cl`, модификация `point_mul_glv_xy`

4. **PMUL-04** — `__constant` memory для preG (NVIDIA):
   - Перенести таблицу базовой точки в `__constant` адресное пространство
   - NVIDIA `__constant` кешируется в L1 (tex cache) — эффективно для read-only данных
   - Файл: `OpenCL/inc_ecc_secp256k1.cl`

### Источники

| Источник | Что берём | Лицензия |
|---|---|---|
| ePrint 2011/338 | Co-Z алгоритмы | Академическая публикация |
| [VanitySearch](https://github.com/JeanLucPons/VanitySearch) `SECP256K1.cpp` | GTable (precomputed multiples), Shamir trick | GPL-3.0 |
| [BitCrack](https://github.com/brichard19/BitCrack) `KeyFinder.cpp` | Group key addition pattern | MIT |

### Ожидаемый прирост

- **+20–35%** для произвольных скаляров
- **+50–100%** для фиксированного базиса (precomputed table)

---

## ФАЗА 4: Оптимизация inv_mod (модулярная инверсия)

### Задачи

1. **INV-01** — Addition chain для `p−2` (из bitcoin-core/secp256k1 `secp256k1_fe_inv`):
   - Заменить 256-итерационный Fermat loop на оптимальную цепочку сложений
   - bitcoin-core/secp256k1 использует цепочку из 15 mul + 255 sqr → ~270 ops vs 511 ops Fermat
   - Файл: `OpenCL/inc_ecc_secp256k1.cl`, новая функция `inv_mod_chain`

2. **INV-02** — Safegcd/divstep62 constant-time (экспериментально):
   - Реализовать `divstep` алгоритм Bernstein & Yang (2019) для быстрой инверсии
   - Только для платформ с хорошей поддержкой 64-bit арифметики
   - Источник: [bitcoin-core/secp256k1](https://github.com/bitcoin-core/secp256k1) `src/field_impl.h`

3. **INV-03** — Оптимизация Fermat chain:
   - Разбить 256-итерационный цикл на сегменты с промежуточными mul
   - Использовать паттерн: `b = a^(2^n)` через `n` squarings, затем умножить с накопителем

### Источники

| Источник | Что берём | Лицензия |
|---|---|---|
| [bitcoin-core/secp256k1](https://github.com/bitcoin-core/secp256k1) `src/field_impl.h` | Addition chain для `p-2`, `secp256k1_fe_inv` | MIT |
| Bernstein & Yang (2019) "Fast constant-time gcd computation and modular inversion" | divstep62 алгоритм | Академическая публикация |

### Ожидаемый прирост

- Addition chain: **+7–12%** (меньше mul/sqr операций)
- Safegcd: **+15–25%** (при поддержке 64-bit)

---

## ФАЗА 5: Оптимизация модулей ядер (kernel-level)

### Задачи

1. **KERN-01** — Перевести m35900–m35906 на SHMEM (по аналогии с m35910):
   - В m35910 уже используется `point_mul_xy_lm` с SHMEM basepoint
   - Применить к остальным модулям brainwallet (m35900–m35904)
   - Файлы: `OpenCL/m35900_a0-pure.cl` ... `OpenCL/m35904_a3-pure.cl`

2. **KERN-02** — Group Key Addition для m35905/m35906 (a3 mode):
   - a3 mode = атака перебором ключей по маске/словарю
   - Вместо вычисления `k * G` с нуля для каждого ключа — инкрементальное сложение: `k_next * G = k * G + G`
   - Источник: [BitCrack](https://github.com/brichard19/BitCrack) `KeyFinder.cpp` pattern
   - Ожидаемый прирост: **100–500×** для a3 mode

3. **KERN-03** — Интеграция GLV в модули m359*:
   - Заменить вызовы `point_mul_xy` на `point_mul_glv_xy`
   - Применимо для brainwallet модулей где скаляр непредсказуем
   - Файлы: все `m359*_a0-pure.cl`, `m359*_a1-pure.cl`

4. **KERN-04** — Реализовать m35911 (ETH Brainwallet BLAKE2s):
   - BLAKE2s-256 hash → private key → secp256k1 → Ethereum address
   - Файлы: `OpenCL/m35911_a0-pure.cl`, `m35911_a1-pure.cl`, `m35911_a3-pure.cl`, `src/modules/module_35911.c`

### Ожидаемый прирост

- SHMEM brainwallet: **+10–15%**
- Group key a3: **+100–500×** (только a3 mode hex key)
- GLV интеграция: **+30–50%** для brainwallet

---

## ФАЗА 6: AMD-специфические оптимизации

### Задачи

1. **AMD-01** — Полный AMD GCN ISA path для `mul_mod`:
   - Реализовать `mul_mod_gcn` используя `v_mad_u64_u32` (GCN 3+) и `v_mul_hi_u32`
   - Условная компиляция: `#ifdef __AMDGCN__`
   - Файл: `OpenCL/inc_ecc_secp256k1.cl`

2. **AMD-02** — Тюнинг workgroup size (`kernel_threads_max`):
   - AMD RDNA 2/3: оптимальный размер 64 (wave64) или 32 (wave32)
   - Тестировать с `--kernel-threads` параметром hashcat
   - Целевой файл: `src/modules/module_359*.c` (параметр `kernel_threads_max`)

3. **AMD-03** — Оптимизация register pressure (VGPR < 96):
   - Проверить VGPR usage через `rocprof --stats`
   - Если VGPR > 96 — применить register blocking / спиллинг
   - Файл: `OpenCL/inc_ecc_secp256k1.cl`

4. **AMD-04** — LDS banking конфликты:
   - Анализ через `rocprof --hsa-trace`
   - Оптимизация padding для SHMEM таблиц (добавить 1 элемент padding на банк)

### Инструменты

```bash
# Профилирование AMD
rocprof --stats hashcat -a 0 -m 35900 hash.txt dict.txt

# Проверить VGPR
rocprof --sys-trace -o out.csv hashcat ...
```

### Ожидаемый прирост

- **+10–20%** только AMD RX 6000/7000
- **+5–10%** AMD Vega/Navi

---

## ФАЗА 7: Расширение функциональности

### Задачи

1. **FEAT-01** — m35911: ETH Brainwallet BLAKE2s (завершить):
   - Если не реализован в Фазе 5, выполнить здесь
   - ST_PASS=hashcat, ST_HASH=<ethereum address>

2. **FEAT-02** — m35912: BTC Brainwallet RIPEMD-160 (если ещё не реализован):
   - Проверить статус m35912 в репозитории
   - RIPEMD-160(SHA256(passphrase)) → private key → address

3. **FEAT-03** — Bech32m / P2TR Taproot поддержка:
   - Добавить `secp256k1_point_to_taproot` в `inc_ecc_secp256k1.cl`
   - x-only public key (32 bytes), BIP340 Schnorr
   - Новые модули: m35913 (BTC P2TR Brainwallet)

4. **FEAT-04** — Мульти-адресная проверка:
   - Для m35905/m35906: проверка одного ключа против нескольких адресов одновременно
   - Использовать a3 mode с bloom filter

### Ожидаемый прирост

- P2TR: новый тип атак (Taproot кошельки)
- Мульти-адрес: **−50–70%** времени для списков адресов

---

## ФАЗА 8: Финальная интеграция и release

### Задачи

1. **INT-01** — Полный регрессионный тест всех 30+ модулей secp256k1:
   - Запустить все Python-тесты: `python3 -m unittest discover -s Python/ -p "test_*.py"`
   - Собрать hashcat и запустить `./hashcat --benchmark -m 35900` ... `--benchmark -m 35912`

2. **INT-02** — Кросс-платформенное тестирование (AMD/NVIDIA):
   - AMD: RX 6800 XT или выше (RDNA 2+)
   - NVIDIA: RTX 3080 или выше (Ampere+)
   - Сравнить hashrate с baseline из `docs/PERF_LOG.md`

3. **INT-03** — Финальный benchmark:
   - Записать результаты в `docs/PERF_LOG.md`
   - Формат: хэш/сек, платформа, дата, коммит

4. **INT-04** — Обновление документации:
   - `README.md`: добавить новые модули и параметры
   - `docs/OPTIMIZATION_MASTERPLAN.md`: отметить выполненные фазы
   - `CHANGELOG.md` или `OPTIMIZATION_SUMMARY.md`: версионированная запись

---

## Сводная таблица файлов по фазам

| Файл | Фазы | Тип изменений |
|---|---|---|
| `OpenCL/inc_ecc_secp256k1.cl` | 2, 3, 4, 5, 6 | Оптимизация алгоритмов, новые функции |
| `OpenCL/inc_ecc_secp256k1.h` | 2, 3, 4 | Новые макросы, объявления |
| `OpenCL/m35900_a*.cl` | 5 | SHMEM, GLV интеграция |
| `OpenCL/m35901_a*.cl` | 5 | SHMEM, GLV интеграция |
| `OpenCL/m35902_a*.cl` | 5 | SHMEM, GLV интеграция |
| `OpenCL/m35903_a*.cl` | 5 | SHMEM, GLV интеграция |
| `OpenCL/m35904_a*.cl` | 5 | SHMEM, GLV интеграция |
| `OpenCL/m35905_a*.cl` | 5 | Group key addition (a3) |
| `OpenCL/m35906_a*.cl` | 5 | Group key addition (a3) |
| `OpenCL/m35910_a*.cl` | 5 | (уже SHMEM, проверить GLV) |
| `OpenCL/m35911_a*.cl` | 5, 7 | Новый модуль ETH BLAKE2s |
| `OpenCL/m35912_a*.cl` | 7 | Новый/уточнённый модуль |
| `OpenCL/m35913_a*.cl` | 7 | Новый модуль P2TR Taproot |
| `src/modules/module_35911.c` | 5, 7 | Host-файл нового модуля |
| `src/modules/module_35912.c` | 7 | Host-файл нового/уточнённого модуля |
| `src/modules/module_35913.c` | 7 | Host-файл нового модуля |
| `Python/test_regression_libsecp256k1.py` | 1, 8 | Новые тесты (edge cases, cross-val) |
| `Python/bench_secp256k1.py` | 1, 8 | Обновление benchmark entry points |
| `docs/PERF_LOG.md` | 8 | Финальные результаты benchmark |
| `STATUS.md` | 1–8 | Запись прогресса каждой фазы |

---

## Внешние источники для заимствования

| Источник | URL | Что берём | Лицензия | Фазы |
|---|---|---|---|---|
| VanitySearch | https://github.com/JeanLucPons/VanitySearch | `ModMulK1`, `ModSqK1`, K1-редукция, GTable, Shamir trick | GPL-3.0 | 2, 3 |
| bitcoin-core/secp256k1 | https://github.com/bitcoin-core/secp256k1 | Addition chain для `p-2`, `secp256k1_fe_inv`, safegcd/divstep | MIT | 4 |
| BitCrack | https://github.com/brichard19/BitCrack | Group key search pattern, инкрементальное сложение | MIT | 3, 5 |
| secp256k1-gpu | https://github.com/PawelGorny/secp256k1-gpu | PTX register math, constant memory tables | MIT | 2, 3 |
| eprint 2011/338 | https://eprint.iacr.org/2011/338 | Co-Z алгоритмы, Longa & Gebotys | Academic | 3 |
| micro-ecc | https://github.com/kmackay/micro-ecc | Compact ECC reference, test vectors | BSD-2 | 1 |
| AMD GCN ISA manual | https://gpuopen.com/amd-isa-documentation/ | `v_add_co_u32`, `v_addc_co_u32`, `v_mad_u64_u32` | Public | 2, 6 |
| NVIDIA CUDA PTX ISA | https://docs.nvidia.com/cuda/parallel-thread-execution/ | `mad.lo.cc`, `addc.cc`, carry-chain macros | Public | 2, 3 |

---

## Важные инварианты для ИИ-агентов

### Не нарушать

1. **secp256k1 параметры неизменны**: `P`, `N`, `Gx`, `Gy`, `LAMBDA`, `BETA` — строгие константы из SEC 2.
2. **API совместимость**: сигнатуры функций `point_mul`, `point_add`, `inv_mod`, `mul_mod` не меняются без синхронизации со всеми модулями m359*.
3. **OpenCL совместимость**: код должен компилироваться как на NVIDIA (PTX path), так и на AMD (GCN path), без `__device__`/CUDA специфики.
4. **Python-тесты как oracle**: все изменения в OpenCL должны проходить Python regression suite (`test_regression_libsecp256k1.py`).

### Обязательные проверки после каждой фазы

```bash
# Базовая верификация
python3 -m unittest Python/test_regression_libsecp256k1.py -v 2>&1 | tail -5

# Полный набор тестов
python3 -m unittest discover -s Python/ -p "test_*.py" -v 2>&1 | tail -10

# Проверка OpenCL синтаксиса (если доступен компилятор)
# clang -x cl -Xclang -finclude-default-header -cl-std=CL2.0 OpenCL/inc_ecc_secp256k1.cl
```

---

*Документ создан в рамках Фазы 1 (Аудит и Стабилизация). Обновляется агентом при завершении каждой фазы.*
