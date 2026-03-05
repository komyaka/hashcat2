# Руководство по оптимизации GPU для режимов Brainwallet (35900-35904)

## Оглавление
- [Введение](#введение)
- [Вариант 1: Риг из 7x AMD Sapphire Nitro+ RX 580 8GB](#вариант-1-риг-из-7x-amd-sapphire-nitro-rx-580-8gb)
- [Вариант 2: Одиночная карта GeForce RTX 3050 6GB](#вариант-2-одиночная-карта-geforce-rtx-3050-6gb)
- [Общие рекомендации по оптимизации](#общие-рекомендации-по-оптимизации)

---

## Введение

Данное руководство содержит оптимальные параметры запуска hashcat для режимов атаки на Brainwallet-кошельки (Bitcoin и Ethereum):

- **35900** — Bitcoin Brainwallet (SHA-256)
- **35901** — Bitcoin Brainwallet (SHA3-256)
- **35902** — Ethereum Brainwallet (Keccak-256)
- **35903** — Ethereum Brainwallet (SHA-256)
- **35904** — Ethereum Brainwallet (SHA3-256)

Каждый из этих режимов включает:
1. Хеширование парольной фразы (SHA-256, SHA3-256 или Keccak-256)
2. Вычисление точки на эллиптической кривой secp256k1 (скалярное умножение)
3. Деривацию адреса кошелька из публичного ключа

Эти операции требуют значительных вычислительных ресурсов GPU, особенно операция скалярного умножения на кривой secp256k1.

---

## Вариант 1: Риг из 7x AMD Sapphire Nitro+ RX 580 8GB

### Характеристики оборудования

| Параметр | Значение |
|----------|----------|
| **Модель GPU** | AMD Sapphire Nitro+ RX 580 8GB |
| **Количество карт** | 7 |
| **Архитектура** | GCN 4-го поколения (Polaris 20) |
| **Compute Units** | 36 на карту (252 всего) |
| **Stream Processors** | 2304 на карту (16128 всего) |
| **Видеопамять** | 8 GB GDDR5 на карту (56 GB суммарно) |
| **Пропускная способность памяти** | 256 GB/s на карту |
| **TDP** | 185W на карту (1295W суммарно) |
| **Backend** | OpenCL 2.0 |
| **Driver** | ROCm 5.x или AMD Adrenalin |

### Общие параметры для всех режимов (7 GPU)

```bash
--backend-devices 1,2,3,4,5,6,7   # Использовать все 7 GPU
-O                                 # Включить оптимизации ядра
--opencl-device-types 1            # Использовать только GPU устройства
```

### Режим 35900 — Bitcoin Brainwallet (SHA-256)

#### Максимальная скорость

```bash
./hashcat -m 35900 -a 0 bitcoin_addresses.txt wordlist.txt \
  --backend-devices 1,2,3,4,5,6,7 \
  -O \
  -w 4 \
  -n 512 \
  --kernel-accel 128 \
  --kernel-loops 256 \
  --kernel-threads 64
```

**Параметры:**
- `-w 4` — максимальная нагрузка (Desktop frozen)
- `-n 512` — количество задач на CU
- `--kernel-accel 128` — ускорение ядра
- `--kernel-loops 256` — количество итераций в ядре
- `--kernel-threads 64` — потоков на рабочую группу

**Ожидаемая производительность:** ~150-170 MH/s суммарно (~21-24 MH/s на карту)

**Потребление энергии:** ~1300-1400W

#### Стабильный режим (долгосрочная работа)

```bash
./hashcat -m 35900 -a 0 bitcoin_addresses.txt wordlist.txt \
  --backend-devices 1,2,3,4,5,6,7 \
  -O \
  -w 3 \
  -n 256 \
  --kernel-accel 64 \
  --kernel-loops 128 \
  --kernel-threads 32 \
  --hwmon-temp-abort 85
```

**Параметры:**
- `-w 3` — высокая нагрузка (Desktop responsive)
- Уменьшенные значения для снижения температуры
- `--hwmon-temp-abort 85` — остановка при температуре выше 85°C

**Ожидаемая производительность:** ~130-145 MH/s суммарно (~18-21 MH/s на карту)

**Потребление энергии:** ~1150-1250W

---

### Режим 35901 — Bitcoin Brainwallet (SHA3-256)

SHA3-256 более вычислительно затратен, чем SHA-256.

#### Максимальная скорость

```bash
./hashcat -m 35901 -a 0 bitcoin_addresses.txt wordlist.txt \
  --backend-devices 1,2,3,4,5,6,7 \
  -O \
  -w 4 \
  -n 384 \
  --kernel-accel 96 \
  --kernel-loops 256 \
  --kernel-threads 64
```

**Ожидаемая производительность:** ~120-135 MH/s суммарно (~17-19 MH/s на карту)

**Потребление энергии:** ~1300-1400W

#### Стабильный режим

```bash
./hashcat -m 35901 -a 0 bitcoin_addresses.txt wordlist.txt \
  --backend-devices 1,2,3,4,5,6,7 \
  -O \
  -w 3 \
  -n 256 \
  --kernel-accel 64 \
  --kernel-loops 128 \
  --kernel-threads 32 \
  --hwmon-temp-abort 85
```

**Ожидаемая производительность:** ~105-120 MH/s суммарно (~15-17 MH/s на карту)

**Потребление энергии:** ~1150-1250W

---

### Режим 35902 — Ethereum Brainwallet (Keccak-256)

Keccak-256 (оригинальный Keccak, не SHA3) часто быстрее SHA3-256.

#### Максимальная скорость

```bash
./hashcat -m 35902 -a 0 ethereum_addresses.txt wordlist.txt \
  --backend-devices 1,2,3,4,5,6,7 \
  -O \
  -w 4 \
  -n 512 \
  --kernel-accel 128 \
  --kernel-loops 256 \
  --kernel-threads 64
```

**Ожидаемая производительность:** ~140-160 MH/s суммарно (~20-23 MH/s на карту)

**Потребление энергии:** ~1300-1400W

#### Стабильный режим

```bash
./hashcat -m 35902 -a 0 ethereum_addresses.txt wordlist.txt \
  --backend-devices 1,2,3,4,5,6,7 \
  -O \
  -w 3 \
  -n 256 \
  --kernel-accel 64 \
  --kernel-loops 128 \
  --kernel-threads 32 \
  --hwmon-temp-abort 85
```

**Ожидаемая производительность:** ~120-140 MH/s суммарно (~17-20 MH/s на карту)

**Потребление энергии:** ~1150-1250W

---

### Режим 35903 — Ethereum Brainwallet (SHA-256)

Производительность аналогична режиму 35900 (Bitcoin SHA-256).

#### Максимальная скорость

```bash
./hashcat -m 35903 -a 0 ethereum_addresses.txt wordlist.txt \
  --backend-devices 1,2,3,4,5,6,7 \
  -O \
  -w 4 \
  -n 512 \
  --kernel-accel 128 \
  --kernel-loops 256 \
  --kernel-threads 64
```

**Ожидаемая производительность:** ~150-170 MH/s суммарно (~21-24 MH/s на карту)

**Потребление энергии:** ~1300-1400W

#### Стабильный режим

```bash
./hashcat -m 35903 -a 0 ethereum_addresses.txt wordlist.txt \
  --backend-devices 1,2,3,4,5,6,7 \
  -O \
  -w 3 \
  -n 256 \
  --kernel-accel 64 \
  --kernel-loops 128 \
  --kernel-threads 32 \
  --hwmon-temp-abort 85
```

**Ожидаемая производительность:** ~130-145 MH/s суммарно (~18-21 MH/s на карту)

**Потребление энергии:** ~1150-1250W

---

### Режим 35904 — Ethereum Brainwallet (SHA3-256)

Производительность аналогична режиму 35901 (Bitcoin SHA3-256).

#### Максимальная скорость

```bash
./hashcat -m 35904 -a 0 ethereum_addresses.txt wordlist.txt \
  --backend-devices 1,2,3,4,5,6,7 \
  -O \
  -w 4 \
  -n 384 \
  --kernel-accel 96 \
  --kernel-loops 256 \
  --kernel-threads 64
```

**Ожидаемая производительность:** ~120-135 MH/s суммарно (~17-19 MH/s на карту)

**Потребление энергии:** ~1300-1400W

#### Стабильный режим

```bash
./hashcat -m 35904 -a 0 ethereum_addresses.txt wordlist.txt \
  --backend-devices 1,2,3,4,5,6,7 \
  -O \
  -w 3 \
  -n 256 \
  --kernel-accel 64 \
  --kernel-loops 128 \
  --kernel-threads 32 \
  --hwmon-temp-abort 85
```

**Ожидаемая производительность:** ~105-120 MH/s суммарно (~15-17 MH/s на карту)

**Потребление энергии:** ~1150-1250W

---

### Рекомендации по охлаждению и энергопотреблению (7x RX 580)

#### Охлаждение

1. **Открытая стойка (mining rig frame)**
   - Обеспечить расстояние между картами не менее 7-10 см
   - Использовать райзеры PCIe для лучшей циркуляции воздуха

2. **Активное охлаждение помещения**
   - Рекомендуется кондиционер или хорошая вентиляция
   - Температура в помещении не должна превышать 25-27°C
   - Приточно-вытяжная вентиляция: минимум 500-700 м³/ч

3. **Настройка вентиляторов GPU**
   ```bash
   # Ручное управление вентиляторами (через amdgpu-pro или rocm-smi)
   # Установить скорость 70-80% для стабильной работы
   rocm-smi --setfan 75 --device 0
   rocm-smi --setfan 75 --device 1
   # ... для всех 7 карт
   ```

4. **Целевые температуры**
   - **Максимальный режим:** 70-80°C (допустимо)
   - **Стабильный режим:** 60-70°C (оптимально)
   - **Критическая температура:** 85°C (авто-остановка через `--hwmon-temp-abort`)

5. **Мониторинг**
   ```bash
   # Постоянный мониторинг температур всех карт
   watch -n 5 'rocm-smi -t'
   ```

#### Энергопотребление

1. **Блок питания (PSU)**
   - Минимальная мощность: **1600W** (80+ Gold или лучше)
   - Рекомендуется: **1800-2000W** для запаса
   - Возможна конфигурация из 2 блоков питания по 1000W (с синхронизатором)

2. **Undervolting (снижение напряжения)**
   - RX 580 хорошо поддаётся undervolting
   - Можно снизить TDP с 185W до ~130-150W на карту с минимальной потерей производительности
   ```bash
   # Пример с amdgpu-pro (требуется root)
   echo "manual" > /sys/class/drm/card0/device/power_dpm_force_performance_level
   echo "5 850" > /sys/class/drm/card0/device/pp_od_clk_voltage
   # Повторить для всех карт
   ```
   - С undervolting: ~1000-1100W суммарно (экономия ~200-300W)

3. **Электрическая безопасность**
   - Использовать качественные кабели питания
   - Не перегружать одну розетку/линию более чем на 80% её номинала
   - Для 1800W нужна линия минимум 220V × 10A = 2200VA

4. **Стоимость электроэнергии**
   - При тарифе 5 руб/кWh:
     - Максимальный режим (1400W): ~50 руб/сутки, ~1500 руб/месяц
     - Стабильный режим (1200W): ~43 руб/сутки, ~1300 руб/месяц
     - С undervolting (1000W): ~36 руб/сутки, ~1080 руб/месяц

---

## Вариант 2: Одиночная карта GeForce RTX 3050 6GB

### Характеристики оборудования

| Параметр | Значение |
|----------|----------|
| **Модель GPU** | NVIDIA GeForce RTX 3050 6GB |
| **Архитектура** | Ampere (GA107) |
| **CUDA Cores** | 2304 |
| **Tensor Cores** | 72 (3-го поколения) |
| **RT Cores** | 18 (2-го поколения) |
| **Видеопамять** | 6 GB GDDR6 |
| **Пропускная способность памяти** | 168 GB/s |
| **TDP** | 70W (низкопрофильные модели) / 130W (стандарт) |
| **Backend** | CUDA 11.x+ |
| **Compute Capability** | 8.6 |

### Общие параметры для RTX 3050

```bash
--backend-devices 1   # Использовать первую (единственную) GPU
-O                     # Включить оптимизации ядра
```

### Режим 35900 — Bitcoin Brainwallet (SHA-256)

#### Максимальная скорость

```bash
./hashcat -m 35900 -a 0 bitcoin_addresses.txt wordlist.txt \
  --backend-devices 1 \
  -O \
  -w 4 \
  -n 256 \
  --kernel-accel 64 \
  --kernel-loops 256 \
  --kernel-threads 128
```

**Параметры:**
- `-w 4` — максимальная нагрузка
- `-n 256` — количество задач
- `--kernel-accel 64` — ускорение ядра
- `--kernel-loops 256` — итераций в ядре
- `--kernel-threads 128` — потоков на блок (оптимально для Ampere)

**Ожидаемая производительность:** ~35-42 MH/s

**Потребление энергии:** ~110-130W (в зависимости от модели)

#### Стабильный режим

```bash
./hashcat -m 35900 -a 0 bitcoin_addresses.txt wordlist.txt \
  --backend-devices 1 \
  -O \
  -w 3 \
  -n 128 \
  --kernel-accel 32 \
  --kernel-loops 128 \
  --kernel-threads 64 \
  --hwmon-temp-abort 80
```

**Ожидаемая производительность:** ~30-36 MH/s

**Потребление энергии:** ~90-110W

---

### Режим 35901 — Bitcoin Brainwallet (SHA3-256)

#### Максимальная скорость

```bash
./hashcat -m 35901 -a 0 bitcoin_addresses.txt wordlist.txt \
  --backend-devices 1 \
  -O \
  -w 4 \
  -n 192 \
  --kernel-accel 48 \
  --kernel-loops 256 \
  --kernel-threads 128
```

**Ожидаемая производительность:** ~28-34 MH/s

**Потребление энергии:** ~110-130W

#### Стабильный режим

```bash
./hashcat -m 35901 -a 0 bitcoin_addresses.txt wordlist.txt \
  --backend-devices 1 \
  -O \
  -w 3 \
  -n 128 \
  --kernel-accel 32 \
  --kernel-loops 128 \
  --kernel-threads 64 \
  --hwmon-temp-abort 80
```

**Ожидаемая производительность:** ~24-30 MH/s

**Потребление энергии:** ~90-110W

---

### Режим 35902 — Ethereum Brainwallet (Keccak-256)

#### Максимальная скорость

```bash
./hashcat -m 35902 -a 0 ethereum_addresses.txt wordlist.txt \
  --backend-devices 1 \
  -O \
  -w 4 \
  -n 256 \
  --kernel-accel 64 \
  --kernel-loops 256 \
  --kernel-threads 128
```

**Ожидаемая производительность:** ~32-40 MH/s

**Потребление энергии:** ~110-130W

#### Стабильный режим

```bash
./hashcat -m 35902 -a 0 ethereum_addresses.txt wordlist.txt \
  --backend-devices 1 \
  -O \
  -w 3 \
  -n 128 \
  --kernel-accel 32 \
  --kernel-loops 128 \
  --kernel-threads 64 \
  --hwmon-temp-abort 80
```

**Ожидаемая производительность:** ~28-34 MH/s

**Потребление энергии:** ~90-110W

---

### Режим 35903 — Ethereum Brainwallet (SHA-256)

#### Максимальная скорость

```bash
./hashcat -m 35903 -a 0 ethereum_addresses.txt wordlist.txt \
  --backend-devices 1 \
  -O \
  -w 4 \
  -n 256 \
  --kernel-accel 64 \
  --kernel-loops 256 \
  --kernel-threads 128
```

**Ожидаемая производительность:** ~35-42 MH/s

**Потребление энергии:** ~110-130W

#### Стабильный режим

```bash
./hashcat -m 35903 -a 0 ethereum_addresses.txt wordlist.txt \
  --backend-devices 1 \
  -O \
  -w 3 \
  -n 128 \
  --kernel-accel 32 \
  --kernel-loops 128 \
  --kernel-threads 64 \
  --hwmon-temp-abort 80
```

**Ожидаемая производительность:** ~30-36 MH/s

**Потребление энергии:** ~90-110W

---

### Режим 35904 — Ethereum Brainwallet (SHA3-256)

#### Максимальная скорость

```bash
./hashcat -m 35904 -a 0 ethereum_addresses.txt wordlist.txt \
  --backend-devices 1 \
  -O \
  -w 4 \
  -n 192 \
  --kernel-accel 48 \
  --kernel-loops 256 \
  --kernel-threads 128
```

**Ожидаемая производительность:** ~28-34 MH/s

**Потребление энергии:** ~110-130W

#### Стабильный режим

```bash
./hashcat -m 35904 -a 0 ethereum_addresses.txt wordlist.txt \
  --backend-devices 1 \
  -O \
  -w 3 \
  -n 128 \
  --kernel-accel 32 \
  --kernel-loops 128 \
  --kernel-threads 64 \
  --hwmon-temp-abort 80
```

**Ожидаемая производительность:** ~24-30 MH/s

**Потребление энергии:** ~90-110W

---

### Рекомендации по охлаждению и энергопотреблению (RTX 3050)

#### Охлаждение

1. **Система охлаждения**
   - Большинство RTX 3050 имеют двухвентиляторное охлаждение (dual-fan)
   - Обеспечить хороший воздушный поток в корпусе
   - Очистить пыль с радиаторов каждые 2-3 месяца

2. **Настройка вентиляторов**
   ```bash
   # Пример с использованием nvidia-settings (Linux)
   nvidia-settings -a "[gpu:0]/GPUFanControlState=1"
   nvidia-settings -a "[fan:0]/GPUTargetFanSpeed=70"
   ```

3. **Целевые температуры**
   - **Максимальный режим:** 65-75°C
   - **Стабильный режим:** 55-65°C
   - **Критическая температура:** 80°C (авто-остановка)

4. **Мониторинг**
   ```bash
   # Постоянный мониторинг температуры и утилизации
   watch -n 5 'nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,power.draw --format=csv'
   ```

#### Энергопотребление

1. **Блок питания**
   - Минимальная мощность: **400W** (для системы с RTX 3050)
   - Рекомендуется: **500-550W** (80+ Bronze или лучше)

2. **Power Limit (ограничение мощности)**
   - RTX 3050 хорошо поддаётся снижению power limit без потери производительности
   ```bash
   # Установить лимит мощности на 85W (из 130W)
   nvidia-smi -i 0 -pl 85
   ```
   - С power limit 85W: ~85-95W потребление при ~90-95% производительности

3. **Стоимость электроэнергии**
   - При тарифе 5 руб/kWh:
     - Максимальный режим (120W): ~4.3 руб/сутки, ~130 руб/месяц
     - Стабильный режим (100W): ~3.6 руб/сутки, ~108 руб/месяц
     - С power limit (85W): ~3 руб/сутки, ~90 руб/месяц

---

## Общие рекомендации по оптимизации

### 1. Подбор параметров

Оптимальные параметры (`-n`, `--kernel-accel`, `--kernel-loops`, `--kernel-threads`) зависят от конкретного GPU и могут отличаться. Для поиска наилучших значений:

```bash
# Автоматический benchmark для определения оптимальных параметров
./hashcat -m 35900 -a 0 --benchmark
```

Или используйте режим tuning (автоматический подбор):
```bash
./hashcat -m 35900 -a 0 bitcoin_addresses.txt wordlist.txt --backend-devices 1 -O -w 4
```

Hashcat автоматически подберёт параметры, если вы не указали их явно.

### 2. Workload Profile (`-w`)

| Значение | Описание | Использование |
|----------|----------|---------------|
| `-w 1` | Low | Система остаётся отзывчивой, минимальная нагрузка на GPU |
| `-w 2` | Default | Баланс между производительностью и отзывчивостью |
| `-w 3` | High | Высокая производительность, система может подтормаживать |
| `-w 4` | Nightmare | Максимальная производительность, система может "зависнуть" |

**Рекомендации:**
- Для headless-серверов (без GUI): `-w 4`
- Для рабочих станций с GUI: `-w 2` или `-w 3`
- Для долгосрочной работы: `-w 3` (баланс производительность/стабильность)

### 3. Оптимизация OpenCL (для AMD)

1. **Установка правильного драйвера**
   - Для майнинговых ригов: **ROCm** или **Adrenalin Pro**
   - Для десктопов: **Adrenalin**

2. **Переменные окружения**
   ```bash
   export GPU_MAX_HEAP_SIZE=100
   export GPU_MAX_USE_SYNC_OBJECTS=1
   export GPU_SINGLE_ALLOC_PERCENT=100
   export GPU_MAX_ALLOC_PERCENT=100
   ```

3. **Компиляция OpenCL ядер**
   - При первом запуске hashcat компилирует ядра (может занять 1-5 минут)
   - Скомпилированные ядра кешируются в `~/.hashcat/kernels/`
   - Для переиспользования на других системах можно скопировать эту папку

### 4. Оптимизация CUDA (для NVIDIA)

1. **Установка последней версии драйвера**
   - Минимум: **525.x** для CUDA 12.x
   - Рекомендуется: **535.x+**

2. **CUDA Toolkit**
   - Не требуется для запуска hashcat
   - Может помочь при отладке

3. **Compute Mode**
   ```bash
   # Установить режим Exclusive Process (для серверов)
   nvidia-smi -i 0 -c 3
   ```

### 5. Работа с большими базами адресов

При работе с миллионами адресов:

1. **Достаточно RAM**
   - 30 млн адресов Ethereum (~42 байта на адрес): ~1.2 GB RAM
   - Рекомендуется иметь минимум 8 GB системной памяти

2. **SSD для быстрой загрузки**
   - Загрузка 30 млн адресов с HDD: ~30-60 секунд
   - Загрузка с SSD: ~5-10 секунд

3. **Формат файла**
   - Используйте файлы с переводами строк Unix (LF), а не Windows (CRLF)
   - Избегайте пустых строк в конце файла

### 6. Мониторинг и автоматизация

#### Скрипт мониторинга для AMD (7 GPU)

```bash
#!/bin/bash
# monitor_amd.sh

while true; do
  clear
  echo "=== AMD GPU Status ==="
  date
  echo ""
  
  for i in {0..6}; do
    temp=$(rocm-smi -d $i --showtemp | grep Temperature | awk '{print $3}')
    util=$(rocm-smi -d $i --showuse | grep GPU | awk '{print $3}')
    power=$(rocm-smi -d $i --showpower | grep Average | awk '{print $4}')
    
    echo "GPU $i: Temp=${temp}°C, Util=${util}%, Power=${power}W"
  done
  
  sleep 5
done
```

#### Скрипт мониторинга для NVIDIA

```bash
#!/bin/bash
# monitor_nvidia.sh

watch -n 5 'nvidia-smi --query-gpu=index,name,temperature.gpu,utilization.gpu,power.draw,memory.used --format=csv,noheader'
```

#### Автоматический перезапуск при сбое

```bash
#!/bin/bash
# auto_restart.sh

while true; do
  echo "Starting hashcat at $(date)"
  
  ./hashcat -m 35900 -a 0 bitcoin_addresses.txt wordlist.txt \
    --backend-devices 1,2,3,4,5,6,7 -O -w 3 \
    --hwmon-temp-abort 85 \
    --restore-timer 60
  
  exit_code=$?
  
  if [ $exit_code -eq 0 ]; then
    echo "Hashcat completed successfully"
    break
  else
    echo "Hashcat exited with code $exit_code, restarting in 10 seconds..."
    sleep 10
  fi
done
```

### 7. Типовые проблемы и решения

#### Проблема: GPU недоступна или не обнаруживается

**AMD:**
```bash
# Проверка видимости GPU
rocm-smi

# Переустановка драйвера (Ubuntu/Debian)
sudo apt purge amdgpu-install
sudo apt autoremove
# Установка ROCm
wget https://repo.radeon.com/amdgpu-install/latest/ubuntu/focal/amdgpu-install_*_all.deb
sudo dpkg -i amdgpu-install_*_all.deb
sudo amdgpu-install --opencl=rocr --usecase=workstation
```

**NVIDIA:**
```bash
# Проверка видимости GPU
nvidia-smi

# Переустановка драйвера (Ubuntu/Debian)
sudo apt purge nvidia-*
sudo apt autoremove
sudo ubuntu-drivers install
sudo reboot
```

#### Проблема: Низкая производительность

1. Проверьте температуру — троттлинг при >85°C
2. Проверьте загрузку GPU (`nvidia-smi` или `rocm-smi`) — должна быть близка к 100%
3. Попробуйте другие значения `-n`, `--kernel-accel`
4. Убедитесь, что используется флаг `-O` (оптимизация)
5. Для AMD: проверьте переменные окружения OpenCL

#### Проблема: GPU зависает или драйвер крашится

1. Снизьте workload profile: `-w 3` вместо `-w 4`
2. Уменьшите `--kernel-accel` и `-n`
3. Проверьте температуру и питание
4. Обновите драйвер GPU
5. Добавьте `--hwmon-temp-abort 80` для автоостановки

#### Проблема: Высокое энергопотребление

**AMD:**
```bash
# Undervolting через OverdriveN API
sudo su
echo "manual" > /sys/class/drm/card0/device/power_dpm_force_performance_level
echo "5 850" > /sys/class/drm/card0/device/pp_od_clk_voltage  # Core voltage
echo "2 900" > /sys/class/drm/card0/device/pp_od_clk_voltage  # Memory voltage
echo "c" > /sys/class/drm/card0/device/pp_od_clk_voltage      # Commit changes
```

**NVIDIA:**
```bash
# Ограничение мощности
nvidia-smi -i 0 -pl 85  # Лимит 85W для RTX 3050
```

### 8. Расширенные техники оптимизации

#### Использование нескольких словарей (pipe mode)

```bash
# Объединение нескольких словарей "на лету"
cat wordlist1.txt wordlist2.txt wordlist3.txt | ./hashcat -m 35900 bitcoin_addresses.txt
```

#### Distributed cracking (распределённая атака)

Для разделения нагрузки между несколькими ригами:

```bash
# Риг 1 (обрабатывает первую половину keyspace)
./hashcat -m 35900 -a 3 addresses.txt ?a?a?a?a?a?a --skip 0 --limit 50000000

# Риг 2 (обрабатывает вторую половину keyspace)
./hashcat -m 35900 -a 3 addresses.txt ?a?a?a?a?a?a --skip 50000000 --limit 50000000
```

#### Использование правил для увеличения словаря

```bash
# Применение нескольких файлов правил одновременно
./hashcat -m 35900 -a 0 addresses.txt wordlist.txt \
  -r rules/best64.rule \
  -r rules/toggles1.rule
```

### 9. Стратегии гибридных атак (-a 6 и -a 7) для корпоративных аудитов

Гибридные атаки комбинируют словари с масками, что делает их чрезвычайно эффективными для аудита реальных систем, где пользователи создают пароли по предсказуемым шаблонам.

#### Архитектура "Penetrator" — многоуровневая стратегия

**Уровень 1: Базовые паттерны (покрывает ~40% паролей)**

```bash
# 1.1. Слово + год (самый распространённый паттерн)
./hashcat -m 35900 -a 6 addresses.txt common_words.txt ?d?d?d?d

# 1.2. Слово + спецсимвол + цифры (compliance-паттерн)
./hashcat -m 35900 -a 6 addresses.txt corporate_dict.txt ?s?d?d

# 1.3. Слово + восклицательный знак (самый популярный спецсимвол)
./hashcat -m 35900 -a 6 addresses.txt wordlist.txt !

# 1.4. Слово + год + спецсимвол
./hashcat -m 35900 -a 6 addresses.txt wordlist.txt ?d?d?d?d?s
```

**Уровень 2: Расширенные паттерны (дополнительные ~20%)**

```bash
# 2.1. Год + слово (обратный порядок)
./hashcat -m 35900 -a 7 addresses.txt ?d?d?d?d wordlist.txt

# 2.2. Слово + месяц/день (01-31)
./hashcat -m 35900 -a 6 addresses.txt wordlist.txt -1 0123 ?1?d

# 2.3. Слово + короткий PIN (00-99)
./hashcat -m 35900 -a 6 addresses.txt wordlist.txt ?d?d

# 2.4. Префикс + слово + год
./hashcat -m 35900 -a 7 addresses.txt ?u wordlist_with_year_suffix.txt
```

**Уровень 3: Локализация и транслитерация (русскоязычные системы, ~15%)**

```bash
# 3.1. Транслитерированные слова + год
./hashcat -m 35900 -a 6 addresses.txt russian_translit_dict.txt ?d?d?d?d

# 3.2. Кириллица → латиница с l33t-заменами + цифры
./hashcat -m 35900 -a 0 addresses.txt russian_dict.txt -r rules/best64.rule

# 3.3. Смешанные паттерны (имя латиницей + год)
./hashcat -m 35900 -a 6 addresses.txt russian_names_translit.txt 19?d?d
```

**Уровень 4: Compliance-обход (пользователи обходят политику, ~10%)**

```bash
# 4.1. Слово + несколько спецсимволов подряд
./hashcat -m 35900 -a 6 addresses.txt wordlist.txt !!

# 4.2. Слово + increment (Password1, Password2, ...)
./hashcat -m 35900 -a 6 addresses.txt wordlist.txt ?d

# 4.3. Сложные маски (спецсимвол в середине + год)
./hashcat -m 35900 -a 0 addresses.txt wordlist.txt -r rules/dive.rule
```

#### Оптимизация производительности гибридных атак

**Важно:** Гибридные атаки (-a 6, -a 7) используют существующие ядра и имеют производительность, сопоставимую с -a 0 (словарь) или -a 3 (маска), в зависимости от длины маски.

**Рекомендации по параметрам для 7x RX 580:**

```bash
# Гибридная атака с короткой маской (1-4 символа)
./hashcat -m 35900 -a 6 addresses.txt large_wordlist.txt ?d?d?d?d \
  --backend-devices 1,2,3,4,5,6,7 \
  -O \
  -w 4 \
  -n 512 \
  --kernel-accel 128

# Гибридная атака с длинной маской (5-8 символов)
./hashcat -m 35900 -a 6 addresses.txt wordlist.txt ?d?d?d?d?d?d?d?d \
  --backend-devices 1,2,3,4,5,6,7 \
  -O \
  -w 3 \
  -n 256 \
  --kernel-accel 64  # Снижаем нагрузку из-за большого keyspace
```

**Рекомендации для GeForce RTX 3050:**

```bash
# Короткая маска
./hashcat -m 35900 -a 6 addresses.txt wordlist.txt ?d?d?d?d \
  -O \
  -w 3 \
  -n 256 \
  --kernel-accel 64

# Длинная маска
./hashcat -m 35900 -a 6 addresses.txt wordlist.txt ?a?a?a?a?a \
  -O \
  -w 2 \
  -n 128 \
  --kernel-accel 32
```

#### Практический пример: полный аудит b2b-системы

```bash
#!/bin/bash
# Скрипт поэтапного аудита корпоративной системы

HASH_FILE="bitcoin_addresses.txt"
DICT="corporate_wordlist.txt"
MODE=35900

# Этап 1: Базовый словарь (быстрая проверка)
echo "[1/7] Straight dictionary attack..."
./hashcat -m $MODE -a 0 $HASH_FILE $DICT --outfile found.txt --outfile-format 2

# Этап 2: Словарь + правила (compliance паттерны)
echo "[2/7] Dictionary + superrules..."
./hashcat -m $MODE -a 0 $HASH_FILE $DICT -r rules/superrules.rule --outfile found.txt --outfile-format 2

# Этап 3: Гибрид — слово + год (2015-2026)
echo "[3/7] Hybrid word + year..."
./hashcat -m $MODE -a 6 $HASH_FILE $DICT -1 12 ?d?d?1?d --outfile found.txt --outfile-format 2

# Этап 4: Гибрид — слово + спецсимвол + цифры
echo "[4/7] Hybrid word + special + digits..."
./hashcat -m $MODE -a 6 $HASH_FILE $DICT ?s?d?d --outfile found.txt --outfile-format 2

# Этап 5: Гибрид — год + слово
echo "[5/7] Hybrid year + word..."
./hashcat -m $MODE -a 7 $HASH_FILE ?d?d?d?d $DICT --outfile found.txt --outfile-format 2

# Этап 6: Комбинатор (два словаря)
echo "[6/7] Combinator attack..."
./hashcat -m $MODE -a 1 $HASH_FILE $DICT short_words.txt --outfile found.txt --outfile-format 2

# Этап 7: Брутфорс коротких паролей (если время позволяет)
echo "[7/7] Brute-force 6-char lowercase..."
./hashcat -m $MODE -a 3 $HASH_FILE ?l?l?l?l?l?l --outfile found.txt --outfile-format 2

echo "Audit complete. Check found.txt for results."
```

#### Когда использовать гибридные атаки

**✅ Используйте -a 6/7 когда:**
- Известны шаблоны паролей организации (аудит показал "слово+год")
- Система имеет политику сложности пароля (заставляет добавлять цифры/спецсимволы)
- Словарь качественный, но недостаточно полный
- Комбинаторная атака (-a 1) слишком медленная из-за больших словарей

**❌ НЕ используйте -a 6/7 когда:**
- Нет информации о паттернах (лучше начать с -a 0 + правила)
- Словарь уже содержит варианты с суффиксами
- Маска слишком длинная (>6 символов) — переходите к -a 3 с инкрементом

#### Ожидаемая производительность гибридных атак

**Режим 35900 (Bitcoin SHA-256):**

| Атака | Словарь | Маска | Комбинаций | Время (7x RX 580 @ 150 MH/s) |
|-------|---------|-------|------------|------------------------------|
| -a 6  | 100K слов | ?d?d?d?d | 1 млрд | ~1.8 часа |
| -a 6  | 1M слов | ?d?d?d?d | 10 млрд | ~18 часов |
| -a 6  | 100K слов | ?s?d?d | 3.7 млрд | ~7 часов |
| -a 7  | ?d?d?d?d | 100K слов | 1 млрд | ~1.8 часа |

**Режим 35903 (Ethereum SHA-256):**

Производительность аналогична режиму 35900 (тот же алгоритм хеширования, разная деривация адреса).

**Режим 35902 (Ethereum Keccak-256):**

Производительность может быть на 10-15% выше из-за особенностей Keccak-256.

---

## Заключение

Данное руководство предоставляет отправные точки для оптимизации hashcat на различном оборудовании. Реальные значения производительности могут варьироваться в зависимости от:

- Качества охлаждения
- Качества блока питания
- Версии драйвера
- Версии hashcat
- Конкретной партии GPU (silicon lottery)

**Рекомендуется:**
1. Начать со "стабильных" конфигураций
2. Постепенно увеличивать параметры, наблюдая за температурой и стабильностью
3. Запустить тестовую сессию на 12-24 часа перед долгосрочной работой
4. Регулярно мониторить состояние оборудования
5. Использовать автоматический перезапуск при сбоях

**Важно:** Данные о производительности являются приблизительными и основаны на типичных значениях для указанного оборудования. Для точных измерений используйте режим benchmark:

```bash
./hashcat -m 35900 --benchmark
```

Happy cracking!
