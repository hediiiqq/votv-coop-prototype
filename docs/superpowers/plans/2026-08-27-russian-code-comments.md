# Russian Code Comments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить подробные русские комментарии в C# bridge и Lua-модули, не изменяя исполняемое поведение.

**Architecture:** Комментарии добавляются послойно: сначала сетевой bridge, затем общие Lua-утилиты и управление процессом, после этого события, удалённый аватар и точка входа. Каждый слой проверяется просмотром diff; в конце выполняются узкие сборка и тесты из спецификации.

**Tech Stack:** C#/.NET, Lua/UE4SS, PowerShell-тесты, Git.

**Spec:** `docs/superpowers/specs/2026-08-27-russian-code-comments-design.md`

## Global Constraints

- Изменять только комментарии и необходимые для их размещения пустые строки в `bridge/Program.cs` и `mod/scripts/*.lua`.
- Все новые и уточнённые комментарии писать на русском языке.
- Комментировать назначение файла, каждую функцию и почти каждый логический блок.
- Не изменять выражения, имена, строковые литералы, порядок операций, интерфейсы, файловые форматы и UDP-пакеты.
- Не запускать репозиторные тесты и форматтеры целиком.
- Не перезаписывать и не включать в коммиты посторонние пользовательские изменения.

---

### Task 1: Документировать C# bridge

**Files:**
- Modify: `bridge/Program.cs:1-309`
- Test: `tests/Test-BridgeActionEvent.ps1`
- Test: `tests/Test-BridgeStaleExit.ps1`
- Test: `tests/Test-BridgeTelemetry.ps1`

**Interfaces:**
- Consumes: `config.ini`, файлы `local_state.txt`, `local_action.txt`, `remote_state.txt`, `remote_action.txt`, `status.txt`, UDP-протокол `VOTVCOOP1`.
- Produces: только поясняющие комментарии; интерфейсы и исполняемый код остаются прежними.

- [ ] **Step 1: Зафиксировать исходное состояние bridge**

Run: `git diff -- bridge/Program.cs`

Expected: пустой diff либо только заранее существующие пользовательские изменения, которые необходимо сохранить.

- [ ] **Step 2: Добавить комментарии уровня файла и основного цикла**

Добавить перед соответствующими блоками комментарии такого уровня конкретности:

```csharp
// UDP-мост обменивается состоянием между Lua-модом и удалённым игроком.
// Lua пишет локальные данные в файлы, а bridge передаёт их по сети и атомарно
// публикует принятые данные обратно для чтения игровым потоком.
```

Пояснить чтение конфигурации, проверку роли и порта, подготовку путей, привязку сокета, handshake, heartbeat, обработку state/action, телеметрию, тайм-ауты и завершение.

- [ ] **Step 3: Документировать вспомогательные функции**

Перед `Send`, `TryReadState`, `TryReadAction`, `TryReadPosition` и `WriteAtomic` описать контракт, формат входа/выхода, обновление sequence и причины возврата `false`. Пример формы:

```csharp
// Читает очередное локальное состояние и возвращает его только при корректном
// формате и более новом sequence, чтобы один кадр не отправлялся повторно.
```

- [ ] **Step 4: Убедиться, что изменились только комментарии**

Run: `git diff --word-diff=porcelain -- bridge/Program.cs`

Expected: добавлены строки `// ...` и пустые строки; исполняемые токены не удалены и не заменены.

- [ ] **Step 5: Собрать bridge и выполнить его узкие тесты**

Run: `dotnet build bridge/VotVCoopBridge.csproj`

Expected: exit code 0.

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-BridgeActionEvent.ps1`

Expected: exit code 0.

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-BridgeStaleExit.ps1`

Expected: exit code 0.

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-BridgeTelemetry.ps1`

Expected: exit code 0.

- [ ] **Step 6: Зафиксировать комментарии bridge**

```bash
git add bridge/Program.cs
git commit -m "docs(bridge): explain network bridge flow"
```

### Task 2: Документировать Lua-утилиты и запуск bridge

**Files:**
- Modify: `mod/scripts/coop_util.lua:1-192`
- Modify: `mod/scripts/coop_bridge.lua:1-41`

**Interfaces:**
- Consumes: объекты UE4SS, пути runtime-файлов, `config.ini`, системный запуск bridge.
- Produces: прежние таблицы `coop_util` и `coop_bridge` с неизменными функциями.

- [ ] **Step 1: Добавить описание модулей и всех функций**

В `coop_util.lua` описать `is_finite_number`, операции yaw, `read_config`, `safe_argument`, `atomic_write`, `read_all`, `split`, вычисление пола, направления взгляда и безопасной идентичности объектов. В `coop_bridge.lua` описать совместимые формы аргументов `start_bridge` и `get_status`.

```lua
-- Модуль собирает безопасные операции, общие для остальных частей кооператива:
-- файловый обмен, нормализацию углов и осторожное чтение объектов UE4SS.
```

- [ ] **Step 2: Пояснить почти каждый логический блок**

Отдельно объяснить атомарную замену файла, резервные способы получить высоту капсулы и yaw, назначение `pcall`, очистку кавычек командной строки и обратную совместимость сигнатур bridge.

- [ ] **Step 3: Проверить комментарийный характер diff**

Run: `git diff --word-diff=porcelain -- mod/scripts/coop_util.lua mod/scripts/coop_bridge.lua`

Expected: исполняемые Lua-токены не заменены и не удалены.

- [ ] **Step 4: Зафиксировать комментарии утилит**

```bash
git add mod/scripts/coop_util.lua mod/scripts/coop_bridge.lua
git commit -m "docs(mod): explain utilities and bridge startup"
```

### Task 3: Документировать обмен действиями

**Files:**
- Modify: `mod/scripts/coop_actions.lua:1-267`
- Test: `tests/Test-LuaRemoteAvatar.ps1`

**Interfaces:**
- Consumes: зависимости из `init(deps)`, локальные и удалённые action-файлы.
- Produces: неизменная таблица `coop_actions` и прежний формат событий.

- [ ] **Step 1: Описать модуль, состояние и функции**

Добавить комментарии для `sanitize_action_name`, `emit_local_action`, `consume_remote_action`, обоих marker-renderers и `init`. Пояснить sequence, дедупликацию, время жизни маркеров и защиту от недоступного Canvas/Controller/Pawn.

```lua
-- Sequence монотонно растёт для каждого локального действия: bridge и удалённая
-- сторона используют его, чтобы не воспроизводить одно событие несколько раз.
```

- [ ] **Step 2: Пояснить ветви рисования и чтения событий**

Перед каждой ранней остановкой и группой вычислений указать, какое отсутствующее состояние она защищает и как формируются экранные координаты, подпись и цвет маркера.

- [ ] **Step 3: Проверить diff и Lua-тест**

Run: `git diff --word-diff=porcelain -- mod/scripts/coop_actions.lua`

Expected: исполняемые Lua-токены не заменены и не удалены.

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-LuaRemoteAvatar.ps1`

Expected: exit code 0.

- [ ] **Step 4: Зафиксировать комментарии действий**

```bash
git add mod/scripts/coop_actions.lua
git commit -m "docs(mod): explain synchronized actions"
```

### Task 4: Документировать удалённый аватар и точку входа

**Files:**
- Modify: `mod/scripts/coop_remote_avatar.lua:1-484`
- Modify: `mod/scripts/main.lua:1-80`
- Test: `tests/Test-LuaRemoteAvatar.ps1`

**Interfaces:**
- Consumes: UE4SS callbacks, локальные/удалённые состояния, зависимости `coop_util`, `coop_bridge`, `coop_actions`.
- Produces: неизменный lifecycle удалённого proxy actor и регистрация игровых callbacks.

- [ ] **Step 1: Документировать lifecycle proxy actor**

Описать модуль, хранимое состояние и функции проверки, идентификации, очистки, сокрытия, копирования transform, создания и обновления proxy. Для всех `pcall` пояснить, какой нестабильный UE4SS boundary изолируется.

```lua
-- Вызовы UE4SS обёрнуты в pcall: игровой объект может стать недействительным
-- между кадрами, и ошибка proxy не должна останавливать основной tick мода.
```

- [ ] **Step 2: Документировать захват и отображение состояния**

Пояснить `capture_local_player`, `consume_remote_player`, `draw_remote_marker`, `get_status_info`, `init`, расчёт пола, yaw, интерполяцию, скрытие при stale/error и экспорт функций.

- [ ] **Step 3: Документировать main.lua**

Описать загрузку модулей, формирование путей, внедрение зависимостей, запуск bridge, `tick`, регистрацию console commands и callbacks.

- [ ] **Step 4: Проверить diff и Lua-тест**

Run: `git diff --word-diff=porcelain -- mod/scripts/coop_remote_avatar.lua mod/scripts/main.lua`

Expected: исполняемые Lua-токены не заменены и не удалены.

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-LuaRemoteAvatar.ps1`

Expected: exit code 0.

- [ ] **Step 5: Зафиксировать комментарии аватара и точки входа**

```bash
git add mod/scripts/coop_remote_avatar.lua mod/scripts/main.lua
git commit -m "docs(mod): explain avatar lifecycle and entrypoint"
```

### Task 5: Финальная проверка области и поведения

**Files:**
- Verify: `bridge/Program.cs`
- Verify: `mod/scripts/*.lua`

**Interfaces:**
- Consumes: изменения Tasks 1-4.
- Produces: доказательство, что комментарии полны, а поведение сохранено.

- [ ] **Step 1: Проверить область изменений**

Run: `git status --short`

Expected: нет незакоммиченных изменений либо показаны только заранее существовавшие пользовательские файлы.

Run: `git diff HEAD~4..HEAD --stat`

Expected: изменены только `bridge/Program.cs` и пять файлов `mod/scripts/*.lua`.

- [ ] **Step 2: Повторить полный узкий набор проверок**

Run: `dotnet build bridge/VotVCoopBridge.csproj`

Expected: exit code 0.

Run по очереди:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-BridgeActionEvent.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-BridgeStaleExit.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-BridgeTelemetry.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-LuaRemoteAvatar.ps1
```

Expected: каждый процесс завершается с exit code 0.

- [ ] **Step 3: Проверить полноту русских комментариев вручную**

Просмотреть diff всех шести файлов и подтвердить наличие описания файла, каждой функции, сетевого и файлового протоколов, lifecycle bridge/proxy, защитных `pcall` и основных ветвей состояния. Английские комментарии в выбранных файлах должны быть переведены или уточнены по-русски.
