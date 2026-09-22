# erlang_migrate

**Erlang/OTP database migration library — pixel-perfect reference implementation of [golang-migrate/migrate v4](https://github.com/golang-migrate/migrate).**

**Erlang/OTP 数据库迁移库 —— 像素级对标 [golang-migrate/migrate v4](https://github.com/golang-migrate/migrate) 的设计实现。**

> Supported databases / 支持的数据库：**PostgreSQL 10+** · **MySQL 8+** · **SQLite 3+**

---

## Design Philosophy / 设计理念

`erlang_migrate` directly inherits the architectural philosophy of `golang-migrate/migrate/v4`:

`erlang_migrate` 直接继承 `golang-migrate/migrate/v4` 的架构哲学：

### 1. Source/Database Separation / 来源与数据库分离

golang-migrate decouples migration **source** (where SQL files come from) from migration **target** (which database to run against).
`erlang_migrate` follows the same separation: `erlang_migrate_source` handles file discovery, `erlang_migrate_pg` handles PostgreSQL execution.

golang-migrate 将迁移**来源**（SQL 文件从哪里读）与迁移**目标**（运行在哪个数据库）彻底解耦。
`erlang_migrate` 遵循同样的分离：`erlang_migrate_source` 负责文件发现，`erlang_migrate_pg` 负责 PostgreSQL 执行。

### 2. Dirty State Machine / Dirty 状态机

Every migration is executed with a **mark → run → clear** protocol around the
version bookkeeping:

每个迁移以**标记 → 执行 → 清除**协议包裹版本记账：

```
set_version(V, dirty=true)   ← mark as in-progress / 标记为执行中
run SQL                       ← execute migration / 执行迁移
set_version(V, dirty=false)  ← mark as complete / 标记为完成
```

If the process crashes between phases, `dirty=true` is permanently recorded, blocking future runs until `force/2` is called.
This is identical to golang-migrate's `SetVersion(v, true)` → `Run()` → `SetVersion(v, false)` pattern.

如果进程在两阶段之间崩溃，`dirty=true` 会被永久记录，阻止后续运行直到调用 `force/2`。
这与 golang-migrate 的 `SetVersion(v, true)` → `Run()` → `SetVersion(v, false)` 模式完全一致。

### 3. Advisory Lock for Distributed Safety / Advisory Lock 分布式安全

Both golang-migrate and `erlang_migrate` use the database's own advisory lock mechanism to prevent concurrent migrations across multiple application nodes. The lock is always released in an `after` block (equivalent to Go's `defer`), ensuring no orphaned locks.

golang-migrate 和 `erlang_migrate` 都使用数据库自身的 advisory lock 机制，防止多个应用节点并发执行迁移。锁始终在 `after` 块中释放（等价于 Go 的 `defer`），确保不会产生孤立锁。

### 4. Version as Integer / 版本号为整数

Versions are **unsigned integers** — either sequential (1, 2, 3…) or Unix timestamps. There is no semantic versioning. The ordering is strict numeric, making "which migration runs next" deterministic and unambiguous.

版本号是**无符号整数**——可以是顺序整数（1, 2, 3…）或 Unix 时间戳。没有语义版本控制，排序是严格数值排序，使"下一个运行哪个迁移"具有确定性且无歧义。

### 5. Plain SQL Only / 仅使用纯 SQL

Migrations are plain `.sql` files. No ORM, no DSL, no code generation. The SQL you write is exactly what runs against the database. This keeps migrations auditable, portable, and debuggable.

迁移是纯 `.sql` 文件。没有 ORM，没有 DSL，没有代码生成。你写的 SQL 就是直接在数据库上运行的 SQL。这使迁移可审计、可移植、可调试。

---

## Migration File Rules / 迁移文件规则

### File Naming Pattern / 文件命名规则

| Rule / 规则 | Pattern / 格式 | Example / 示例 |
|-------------|----------------|----------------|
| Up migration / 正向迁移 | `{version}_{title}.up.sql` | `00000001_create_users.up.sql` |
| Down migration / 反向迁移 | `{version}_{title}.down.sql` | `00000001_create_users.down.sql` |
| Version format / 版本格式 | Positive integer / 正整数 | `1`, `00000001`, `20240101120000` |
| Title format / 标题格式 | any filename-safe text; `[a-z0-9_]+` recommended (UTF-8 supported by `create/2`) / 任意文件名安全文本，推荐 `[a-z0-9_]+`（`create/2` 支持 UTF-8） | `create_users`, `用户表` |
| Separator / 分隔符 | Underscore `_` between version and title | `00000001_create_users` |
| Extension / 扩展名 | `.up.sql` or `.down.sql` | `.up.sql` |
| Unparseable files / 无法解析的文件 | A `*.up.sql` whose `{version}_` prefix does not parse aborts the scan with `{error, {invalid_migration_filename, ...}}` — never silently skipped / 版本段无法解析的 `*.up.sql` 会使扫描报错，绝不静默跳过 | `abc_init.up.sql` → error |

### Version Rules / 版本号规则

| Rule / 规则 | Description / 说明 | Valid / 合法 | Invalid / 非法 |
|-------------|---------------------|-------------|----------------|
| Must be positive integer / 必须是正整数 | No zero, no negative / 非零，非负 | `1`, `100` | `0`, `-1` |
| Zero-padded recommended / 建议补零 | For consistent sorting / 保证排序一致 | `00000001` | `1` (still works / 也能用) |
| Unix timestamp allowed / 允许 Unix 时间戳 | 14-digit preferred / 推荐 14 位 | `20240101120000` | — |
| No gaps required / 不要求连续 | Gaps are fine / 允许跳号 | `1, 2, 5, 10` | — |
| Must be unique / 必须唯一 | Duplicate versions are rejected / 重复版本会被拒绝 | — | Two files with same version |

### Directory Rules / 目录规则

| Rule / 规则 | Description / 说明 |
|-------------|---------------------|
| Flat directory / 平铺目录 | No subdirectories scanned / 不扫描子目录 |
| `.up.sql` drives the scan / 以 `.up.sql` 为准 | Only `.up.sql` files are enumerated; a lone `.down.sql` without its `.up.sql` is ignored / 只枚举 `.up.sql`；无 up 对应的 `.down.sql` 会被忽略 |
| Bad names are errors / 坏文件名即报错 | An `.up.sql` file whose version segment does not parse as a positive integer fails the whole scan — nothing is silently skipped / 版本段不是正整数的 `.up.sql` 会让整个扫描失败，不做静默跳过 |
| `.down.sql` optional / `.down.sql` 可选 | If missing, `down/2` will error for that version / 缺少则 `down/2` 该版本会报错 |
| Must be readable / 必须可读 | Unreadable directory aborts the scan / 目录不可读会中止扫描 |

### SQL Content Rules / SQL 内容规则

| Rule / 规则 | Description / 说明 |
|-------------|---------------------|
| Multi-statement supported / 支持多语句 | PG: `epgsql:squery` simple-query protocol; MySQL: mysql-otp enables `CLIENT_MULTI_STATEMENTS` by default; SQLite: `esqlite3:exec` runs full scripts / 三驱动均支持整文件多语句执行 |
| No explicit transaction needed / 无需显式事务 | Each migration file is wrapped in its own `BEGIN`/`COMMIT` by the driver — do **not** put `BEGIN`/`COMMIT` inside the file (nested transaction error) / 驱动自动为整个文件包一层事务；文件内**不要**再写 `BEGIN`/`COMMIT`（会报嵌套事务错误） |
| ⚠️ MySQL DDL atomicity / MySQL DDL 原子性 | MySQL implicitly commits before each DDL — a multi-statement file failing midway is NOT fully rolled back (PG is). Prefer one DDL per file on MySQL. / MySQL 在每条 DDL 前隐式提交，多语句文件中途失败**不会**整体回滚（PG 可以）；MySQL 下建议一文件一 DDL |
| DDL and DML both allowed / DDL 和 DML 均可 | `CREATE TABLE`, `INSERT`, `ALTER`, etc. / 均支持 |
| Empty file allowed / 允许空文件 | Acts as a no-op version marker / 作为无操作版本标记 |
| Comments allowed / 允许注释 | Standard SQL `--` and `/* */` / 标准 SQL 注释均可 |

### Example Directory Layout / 示例目录布局

```
priv/migrations/
  00000001_create_users.up.sql       ← required / 必须
  00000001_create_users.down.sql     ← recommended / 建议
  00000002_add_email_index.up.sql
  00000002_add_email_index.down.sql
  00000003_add_roles_table.up.sql
  00000003_add_roles_table.down.sql
  20240101120000_add_audit_log.up.sql
  20240101120000_add_audit_log.down.sql
```

---

## Configuration / 配置

All behaviour is controlled by a single `Config` map passed to every API call.
**No changes to `erlang_migrate` source are needed** — everything is configured at call site.

所有行为通过传入每个 API 调用的 `Config` map 控制。
**无需修改 `erlang_migrate` 源码** —— 所有定制均在调用方配置。

### Three key customisation points / 三个核心定制项

| Key / 键 | What it controls / 控制什么 | Default / 默认值 |
|----------|-----------------------------|-----------------|
| `driver` | Which database backend to use / 使用哪个数据库后端 | `erlang_migrate_pg` |
| `dir`    | Where migration SQL files live / 迁移 SQL 文件目录 | *(required / 必填)* |
| `table`  | Name of the tracking table / 迁移状态跟踪表名 | `<<"schema_migrations">>` |

```erlang
%% PostgreSQL — default driver, custom path and table name
%% PostgreSQL —— 默认驱动，自定义路径和表名
Config = #{
    conn   => Conn,
    driver => erlang_migrate_pg,            % default, can be omitted / 默认可省略
    dir    => "priv/migrations/postgres",   % your SQL file directory / 你的迁移文件目录
    table  => <<"myapp_schema_migrations">> % custom tracking table / 自定义跟踪表名
},
ok = erlang_migrate:up(Config).

%% MySQL 8+
Config = #{
    conn   => Conn,
    driver => erlang_migrate_mysql,
    dir    => "priv/migrations/mysql",
    table  => <<"myapp_schema_migrations">>
},
ok = erlang_migrate:up(Config).

%% SQLite 3+
Config = #{
    conn   => Conn,
    driver => erlang_migrate_sqlite,
    dir    => "priv/migrations/sqlite",
    table  => <<"myapp_schema_migrations">>
},
ok = erlang_migrate:up(Config).
```

> The tracking table is created automatically on first run if it does not exist.
> Lock ID is auto-derived from the table name, so different table names are lock-isolated.
>
> 跟踪表在首次运行时自动创建（如不存在）。
> 锁 ID 从表名自动派生，不同表名之间的锁互相隔离。

---

## Quick Start / 快速开始

```erlang
%% 1. Connect to PostgreSQL / 连接 PostgreSQL
{ok, Conn} = epgsql:connect(#{
    host     => "localhost",
    port     => 5432,
    database => "mydb",
    username => "user",
    password => "pass"
}),

%% 2. Build config — see "Configuration" section for driver/dir/table options
%% 构建配置 —— driver/dir/table 定制项见上方「Configuration」章节
Config = #{
    conn => Conn,
    dir  => "priv/migrations"
},

%% 3. Apply all pending migrations / 应用所有待执行迁移
ok = erlang_migrate:up(Config),

%% 4. Apply next 2 migrations / 应用接下来 2 个迁移
ok = erlang_migrate:up(Config, 2),

%% 5. Check current version and dirty flag / 查询当前版本和 dirty 状态
{ok, Version, Dirty} = erlang_migrate:version(Config),

%% 6. Roll back 1 migration / 回滚 1 个迁移
ok = erlang_migrate:down(Config, 1),

%% 7. Roll back all applied migrations / 回滚全部迁移
ok = erlang_migrate:down(Config),

%% 8. Jump to a specific version (auto up or down) / 跳转到指定版本（自动判断方向）
ok = erlang_migrate:goto(Config, 5),

%% 9. Force-set version after manual recovery / 手动恢复后强制设置版本
ok = erlang_migrate:force(Config, 5),

%% 10. Drop schema_migrations table (tests only) / 删除 schema_migrations 表（仅测试用）
ok = erlang_migrate:drop(Config).
```

---

## API Reference / API 参考

| Function / 函数 | golang-migrate equivalent | Description / 说明 |
|-----------------|--------------------------|---------------------|
| `up(Config)` | `Up()` | Apply all pending migrations / 应用所有待执行迁移 |
| `up(Config, N)` | `Steps(+N)` | Apply up to N pending migrations / 应用最多 N 个待执行迁移 |
| `down(Config)` | `Down()` | Roll back all applied migrations / 回滚所有已应用迁移 |
| `down(Config, N)` | `Steps(-N)` | Roll back N migrations / 回滚 N 个迁移 |
| `goto(Config, Version)` | `Migrate(version)` | Migrate to exact version (auto up/down) / 迁移到指定版本（自动判断方向） |
| `create(Dir, Title)` | `create` (CLI) | Generate `{utc_timestamp}_{title}.up/.down.sql` pair / 生成时间戳迁移文件对 |
| `force(Config, Version)` | `Force(version)` | Force set version, clears dirty flag / 强制设置版本，清除 dirty 标志 |
| `version(Config)` | `Version()` | Return `{ok, Version, Dirty}` / 返回版本和 dirty 状态 |
| `drop(Config)` | `Drop()` *(partial)* | Drop `schema_migrations` table / 删除 schema_migrations 表 |

> **Note on `drop/1` / `drop/1` 说明**
>
> golang-migrate's `Drop()` drops **all tables** in the target database.
> `erlang_migrate:drop/1` only drops the `schema_migrations` tracking table.
> Use in tests only.
>
> golang-migrate 的 `Drop()` 会删除目标数据库中的**所有表**。
> `erlang_migrate:drop/1` 仅删除 `schema_migrations` 状态跟踪表。仅在测试环境使用。

---

## Config Keys / 配置项

| Key / 键 | Required / 必填 | Default / 默认值 | Description / 说明 |
|----------|-----------------|-----------------|---------------------|
| `conn` | yes / 是 | — | Database connection pid / 数据库连接进程 |
| `dir` | yes / 是 | — | Path to migration files / 迁移文件目录路径 |
| `driver` | no / 否 | `erlang_migrate_pg` | Driver module / 驱动模块，见下方驱动说明 |
| `table` | no / 否 | `<<"schema_migrations">>` | Tracking table name / 迁移状态表名 |
| `lock_id` | no / 否 | `erlang:phash2(Table, 1 bsl 30)` | Advisory lock ID (auto-derived) / 锁 ID（自动派生）|
| `lock_timeout` | no / 否 | `15000` | Lock wait timeout in ms / 获锁等待超时毫秒数 |
| `logger` | no / 否 | `undefined` | `fun(Level, Msg)` 或 `fun(Level, Meta, Msg)` callback / 日志回调函数 |
| `dry_run` | no / 否 | `false` | Log what would be applied without touching the DB / 只记录不执行，跳过 strict 记账 |
| `set_version_retries` | no / 否 | `3` | Retries for `set_version` on contention / 版本写入重试次数 |
| `set_version_retry_ms` | no / 否 | `200` | Retry delay in ms / 版本写入重试延迟毫秒数 |
| `strict` | no / 否 | `false` | Out-of-order detection via `<table>_history` / 乱序迁移检测，见下方"Strict Mode" |
| `strict_bootstrap` | no / 否 | `backfill` | First strict run on an existing install: `backfill` (assume all `=<` current were applied) or `fail` (refuse the guess); any other explicit value returns `{error, {invalid_strict_bootstrap, Value}}` / 已有环境首次启用 strict 的回填策略；显式非法值直接报错 |

---

## Strict Mode / 严格模式（乱序迁移检测）

With timestamp versions and multiple developers, a migration merged late (its
timestamp is lower than the already-applied current version) is **silently
skipped forever** under golang-migrate semantics. `strict => true` closes this
gap:

时间戳版本号 + 多人开发时，后合并的迁移（时间戳小于当前已应用版本）在
golang-migrate 语义下会被**永久静默跳过**。`strict => true` 修复此问题：

- Every applied migration is also recorded in a `<table>_history` table
  (one row per version). / 每个已应用迁移同时记录到 `<table>_history` 表（每版本一行）。
- `up/1,2` fails with `{error, {out_of_order, Versions}}` when a file version
  `=<` current was never applied. / 当存在版本号 `=<` 当前版本但从未应用的文件时，
  `up/1,2` 返回 `{error, {out_of_order, Versions}}`。
- First strict run on an existing install backfills the history (assumes all
  versions `=<` current were applied). **Warning / 警告**: if any of those files
  were actually never executed (e.g. merged late, lower timestamp), backfill
  marks them applied **forever** and they will never run. Set
  `strict_bootstrap => fail` to refuse this guess: the first run then returns
  `{error, {strict_bootstrap_needed, Current}}` and recovery is an explicit
  `force/2` (rebuilds history from source files — the same assumption, but
  made deliberately) or a deliberate `strict_bootstrap => backfill` run.
  Any other explicit `strict_bootstrap` value is rejected rather than falling
  back to the unsafe assumption.
  / 已有环境首次启用时自动回填历史（**假定** `=<` 当前版本的迁移均已应用）。
  **警告**：若其中部分文件实际从未执行（如后合并的低时间戳迁移），回填会把它们
  **永久**标记为已应用且永不执行。设置 `strict_bootstrap => fail` 可拒绝该猜测：
  首次运行返回 `{error, {strict_bootstrap_needed, Current}}`，恢复方式为显式
  `force/2`（同样是重建历史，但由你主动确认）或显式 `strict_bootstrap => backfill`。
  其他显式值会直接报配置错误，不会退回到默认盲回填。
- `force/2` rebuilds the history; `drop/1` also drops it; `dry_run` bypasses
  strict bookkeeping. / `force/2` 重建历史表；`drop/1` 一并删除；`dry_run` 跳过 strict。

Recovery for an out-of-order file: re-timestamp it to a fresh version
(recommended), or apply it manually and run `force/2`.
乱序文件的处理：重新生成新时间戳（推荐），或手动应用后执行 `force/2`。

Requires a driver exporting `applied_versions/2` — the bundled PG / MySQL /
SQLite drivers all do. / 需要驱动导出 `applied_versions/2`（自带三驱动均已实现）。

---

## Creating Migrations / 创建迁移文件

```erlang
%% In-app / 程序内
{ok, Up, Down} = erlang_migrate:create("priv/migrations", "add_user_index").
%% -> priv/migrations/20260610120000_add_user_index.up.sql / .down.sql
```

```bash
# CLI (no DB drivers needed / 无需数据库驱动)
rebar3 escriptize
_build/default/bin/erlang_migrate_cli new add_user_index priv/migrations
```

Versions are UTC timestamps (`YYYYMMDDHHMMSS`), so concurrent developers get
non-overlapping versions by construction; same-second collisions bump +1.
版本号为 UTC 时间戳，多人并行开发天然不重叠；同秒冲突自动 +1。

---

## Schema Migrations Table / 状态跟踪表

```sql
CREATE TABLE schema_migrations (
    version    BIGINT PRIMARY KEY,
    dirty      BOOLEAN NOT NULL DEFAULT false,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

The table always contains **at most one row** — the current version state.
Every `set_version` call is a `DELETE` + optional `INSERT` (when `Version =/= undefined`).
An empty table means no migrations have been applied.

表中**永远最多只有一行**——即当前版本状态。
每次 `set_version` 调用都是 `DELETE` + 可选 `INSERT`（`Version =:= undefined` 时只 DELETE）。
空表表示尚未执行任何迁移。

This is identical to golang-migrate's `TRUNCATE + INSERT` semantics, ensuring `force/2` always produces a clean single-row state with no stale dirty rows.

这与 golang-migrate 的 `TRUNCATE + INSERT` 语义完全一致，确保 `force/2` 总能产生干净的单行状态，不存在残留 dirty 行。

---

## Dirty State / Dirty 状态

If a migration fails mid-execution, the `dirty` flag is set to `true`. All future `up/down/goto` calls will refuse to proceed.

迁移执行中途失败，`dirty` 标志被设为 `true`。所有后续 `up/down/goto` 调用均会拒绝执行。

```
  ┌──────────┐   up/goto    ┌──────────────┐  success   ┌──────────┐
  │  clean   │ ────────────►│  executing   │ ──────────►│  clean   │
  │ (v=N)    │              │  dirty=true  │             │ (v=N+1)  │
  └──────────┘              └──────────────┘             └──────────┘
                                    │
                              failure / error
                                    │
                                    ▼
                            ┌──────────────┐
                            │    dirty     │  ← blocks all future runs / 阻断所有操作
                            │  dirty=true  │
                            └──────────────┘
                                    │
                        manual DB fix + force(Config, V)
                                    │
                                    ▼
                            ┌──────────────┐
                            │    clean     │
                            │  dirty=false │
                            └──────────────┘
```

Recovery steps / 恢复步骤：

1. Inspect the database and fix any partial state manually / 检查数据库并手动修复部分状态
2. Call `erlang_migrate:force(Config, LastGoodVersion)` / 调用 `force/2` 设置最后一个正常版本

---

## Concurrency Safety / 并发安全

Migrations are serialised by a lock held for the whole `up`/`down`/`goto`
run and always released in an `after` block. The lock mechanism — and its
scope — differs per driver:

迁移通过锁串行化，锁覆盖整个 `up`/`down`/`goto` 运行过程，并始终在 `after` 块中释放。
锁机制与**作用范围**因驱动而异：

| Driver | Mechanism / 机制 | Scope / 范围 |
|--------|------------------|--------------|
| PostgreSQL | `pg_try_advisory_lock` (session-level) + 100ms retry loop | ✅ Cross-process / cross-node — safe for multi-node Erlang clusters / 跨进程跨节点，多节点集群安全 |
| MySQL | `GET_LOCK` / `RELEASE_LOCK` (named lock, per connection) + 100ms retry loop | ✅ Cross-process / cross-node / 跨进程跨节点 |
| SQLite | OTP `global:set_lock` (single node list `[node()]`) | ⚠️ **Same Erlang VM only** — no cross-node/cross-VM mutual exclusion; concurrent migration from a second VM is not prevented (SQLite file locking only serialises individual writes) / **仅同一 Erlang 节点内互斥**，不提供跨节点/跨 VM 互斥（SQLite 文件锁只串行化底层单次写入） |

Lock timeout is configurable via `lock_timeout` in Config (default `15000`ms,
matching golang-migrate). Internally the PG/MySQL drivers use a try-lock +
100ms retry loop until the deadline; a contending run fails with
`{error, lock_timeout}` rather than blocking forever.

锁超时通过 Config 中的 `lock_timeout` 配置（默认 `15000`ms，与 golang-migrate 一致）。
PG/MySQL 驱动内部使用 try-lock + 100ms 重试循环直到超时；竞争方以
`{error, lock_timeout}` 失败退出，而非无限阻塞。

```erlang
Config = #{
    conn         => Conn,
    dir          => "priv/migrations",
    lock_timeout => 5000,
    logger       => fun(Level, Msg) ->
        logger:log(Level, "erlang_migrate: ~s", [Msg])
    end
}.
```

---

## Implementation Status / 实现进度

| Feature / 功能 | golang-migrate | erlang_migrate | Status / 状态 |
|----------------|---------------|----------------|---------------|
| `up` all | ✅ `Up()` | ✅ `up/1` | ✅ Done |
| `up` N steps | ✅ `Steps(+N)` | ✅ `up/2` | ✅ Done |
| `down` all | ✅ `Down()` | ✅ `down/1` | ✅ Done |
| `down` N steps | ✅ `Steps(-N)` | ✅ `down/2` | ✅ Done |
| `goto` version | ✅ `Migrate(v)` | ✅ `goto/2` | ✅ Done |
| `force` version | ✅ `Force(v)` | ✅ `force/2` | ✅ Done |
| `version` + dirty | ✅ `Version()` | ✅ `version/1` → `{ok, V, Dirty}` | ✅ Done |
| `drop` state table | ✅ all tables | ✅ state table only | ⚠️ Partial |
| Advisory lock | ✅ | ✅ `pg_try_advisory_lock` | ✅ Done |
| Dirty state machine | ✅ | ✅ | ✅ Done |
| Migration history | ❌ single-row | ❌ single-row + `applied_at` | ✅ Done |
| Lock timeout | ✅ 15s | ✅ `lock_timeout` ms (default 15s) | ✅ Done |
| GracefulStop | ✅ channel | ✅ `erlang_migrate_abort` signal | ✅ Done |
| Logger interface | ✅ pluggable | ✅ optional `logger` fun/2 or fun/3 in Config | ✅ Done |
| CLI tooling | ✅ | ✅ `erlang_migrate_cli` (file gen only) | ✅ Done |
| Source abstraction | ✅ 15+ sources | filesystem only | 🔲 Future |
| Multi-database | ✅ 15+ | PostgreSQL / MySQL / SQLite | ✅ Done |
| Integration tests | ✅ Docker | ✅ real-DB suites (SQLite always-on; PostgreSQL/MySQL env-gated, `test/integration/run.sh`) | ✅ Done |

---

## Installation / 安装

### PostgreSQL

Add `epgsql` to your own `deps`. `erlang_migrate` has **zero hard dependencies**.

在你的 `deps` 中添加 `epgsql`。`erlang_migrate` **没有任何硬依赖**。

```erlang
{deps, [
    {erlang_migrate, "0.3.2"},
    {epgsql, "4.8.0"}
]}.
```

```erlang
Config = #{conn => Conn, dir => "priv/migrations"},
ok = erlang_migrate:up(Config).
```

### MySQL 8+

Add `mysql` to your own `deps`, then set `driver => erlang_migrate_mysql` in Config.

在你的项目 `deps` 中添加 `mysql`，Config 中指定驱动即可。

```erlang
{deps, [
    {erlang_migrate, "0.3.2"},
    {mysql, "1.8.0"}           %% add mysql driver yourself / 自行添加驱动依赖
]}.
```

```erlang
{ok, Conn} = mysql:start_link([{host, "localhost"}, {user, "root"},
                                {password, "pass"}, {database, "mydb"}]),
Config = #{conn => Conn, dir => "priv/migrations", driver => erlang_migrate_mysql},
ok = erlang_migrate:up(Config).
```

### SQLite 3+

Add `esqlite` to your own `deps`, then set `driver => erlang_migrate_sqlite` in Config.

在你的项目 `deps` 中添加 `esqlite`，Config 中指定驱动即可。

```erlang
{deps, [
    {erlang_migrate, "0.3.2"},
    {esqlite, "0.8.1"}         %% add esqlite driver yourself / 自行添加驱动依赖
]}.
```

```erlang
{ok, Conn} = esqlite3:open("mydb.sqlite"),
Config = #{conn => Conn, dir => "priv/migrations", driver => erlang_migrate_sqlite},
ok = erlang_migrate:up(Config).
```

### From GitHub / 从 GitHub 安装

```erlang
{deps, [
    {erlang_migrate, {git, "https://github.com/imboy-pub/erlang_migrate.git", {tag, "v0.3.2"}}}
]}.
```

---

## Development / 开发

```bash
rebar3 compile
rebar3 as test eunit            # unit + mock tests
EM_SQLITE_IT=1 rebar3 as test eunit --module=erlang_migrate_sqlite_integration_it
rebar3 as dev dialyzer          # src-only gate with real driver deps in the PLT
```

Real-database integration suites (PostgreSQL / MySQL) are env-gated and skip
silently when the variables are unset — `test/erlang_migrate_pg_integration_tests.erl`
needs `EM_PG_HOST/EM_PG_USER/EM_PG_PASSWORD/EM_PG_DB` (+ optional `EM_PG_PORT`),
`test/erlang_migrate_mysql_integration_tests.erl` needs `EM_MYSQL_HOST/EM_MYSQL_USER/EM_MYSQL_PASSWORD/EM_MYSQL_DB`
(+ optional `EM_MYSQL_PORT`). The SQLite suite runs in a separate EUnit VM because
the unit suite mocks the `esqlite3` NIF module; keeping the real-NIF suite isolated
avoids unsafe NIF unload/reload in one VM. CI and `test/integration/run.sh` run both.
To run everything against disposable containers:

```bash
sh test/integration/run.sh
```

真库集成套件（PostgreSQL / MySQL）按环境变量门控，未设置时静默跳过。
完整跑一遍（含一次性容器）用 `sh test/integration/run.sh`。

---

## Publishing to Hex / 发布到 Hex

`rebar3_hex` is configured as a project plugin. Release a version from a clean
working tree only; never store a Hex API key in this repository.

项目已配置 `rebar3_hex` 插件。只在工作区干净时发布；不要把 Hex API Key 写入仓库或提交。

1. Bump `{vsn, "x.y.z"}` in `src/erlang_migrate.app.src`, add the release notes
   to `CHANGELOG.md`, then run the full test suite.

   ```bash
   rebar3 as test eunit
   EM_SQLITE_IT=1 rebar3 as test eunit --module=erlang_migrate_sqlite_integration_it
   ```

2. **Guard the lock file / 检查锁文件** — `rebar3_hex` derives the published
   package's `requirements` from `rebar.lock`, so a lock carrying dependency
   entries publishes them as hard requirements. This library must publish
   with **zero** requirements; regenerate and verify before building:

   ```bash
   rm rebar.lock && rebar3 compile && cat rebar.lock   # must print [].
   rebar3 hex build
   ```

   （`rebar3_hex` 从 `rebar.lock` 生成发布的 `requirements`；lock 里若有依赖条目
   就会被发布成硬依赖。本库必须以**零** requirements 发布，构建前先重建并核对。）

3. On a machine that has not been authenticated with Hex, run the interactive
   user setup command. It stores credentials in the local rebar3 configuration,
   not in this repository.

   ```bash
   rebar3 hex user
   ```

4. Generate and inspect the package without publishing it.

   ```bash
   rebar3 hex publish --dry-run
   ```

5. Publish interactively, confirm the package metadata and documentation, then
   create and push the matching Git tag.

   ```bash
   rebar3 hex publish
   git tag -a vX.Y.Z -m "erlang_migrate X.Y.Z"
   git push github main vX.Y.Z
   git push origin main vX.Y.Z
   ```

6. Verify the released package is discoverable and installable.

   ```bash
   rebar3 hex search erlang_migrate
   ```

Hex public releases are immutable in normal use: publish a new version for a
fix instead of using `--replace`. Use `rebar3 hex publish --yes` only in a
reviewed CI release job with an externally managed credential.

Hex 的公开版本通常应视为不可变：修复请发布新版本，不要使用 `--replace`。只有在
凭证由外部安全管理、且已审核的 CI 发布任务中，才使用 `rebar3 hex publish --yes`。

---

## License / 许可证

Apache 2.0 — see [LICENSE](LICENSE)
