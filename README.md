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

Every migration is executed in a **two-phase commit** pattern:

每个迁移以**两阶段提交**模式执行：

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
| Title format / 标题格式 | `[a-z0-9_]+` | `create_users`, `add_email_index` |
| Separator / 分隔符 | Underscore `_` between version and title | `00000001_create_users` |
| Extension / 扩展名 | `.up.sql` or `.down.sql` | `.up.sql` |

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
| Any filename is scanned / 扫描所有文件 | Only `.up.sql` and `.down.sql` are processed / 只处理 `.up.sql` 和 `.down.sql` |
| `.up.sql` required / `.up.sql` 必须存在 | Every version must have an up file / 每个版本必须有 up 文件 |
| `.down.sql` optional / `.down.sql` 可选 | If missing, `down/2` will error for that version / 缺少则 `down/2` 该版本会报错 |
| Must be readable / 必须可读 | File permission errors abort the scan / 权限错误会中止扫描 |

### SQL Content Rules / SQL 内容规则

| Rule / 规则 | Description / 说明 |
|-------------|---------------------|
| Multi-statement supported / 支持多语句 | `epgsql:squery` executes the full file / `epgsql:squery` 直接执行整个文件 |
| No explicit transaction needed / 无需显式事务 | Each migration runs in its own auto-transaction / 每个迁移在自身事务中运行 |
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
| `lock_id` | no / 否 | `erlang:phash2(Table)` | Advisory lock ID (auto-derived) / 锁 ID（自动派生）|
| `lock_timeout` | no / 否 | `15000` | Lock wait timeout in ms / 获锁等待超时毫秒数 |
| `logger` | no / 否 | `undefined` | `fun(Level, Msg) -> ok` callback / 日志回调函数 |

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

`erlang_migrate` uses `pg_advisory_lock` — equivalent to golang-migrate's database-layer advisory lock.
Safe for multi-node Erlang clusters. Only one node executes migrations at a time.

`erlang_migrate` 使用 `pg_advisory_lock`，等价于 golang-migrate 的数据库层 advisory lock。
对多节点 Erlang 集群安全。同一时刻只有一个节点执行迁移。

Lock timeout is configurable via `lock_timeout` in Config (default `15000`ms, matching golang-migrate).
Internally uses `pg_try_advisory_lock` + 100ms retry loop until deadline.

锁超时通过 Config 中的 `lock_timeout` 配置（默认 `15000`ms，与 golang-migrate 一致）。
内部使用 `pg_try_advisory_lock` + 100ms 重试循环直到超时。

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
| Advisory lock | ✅ | ✅ `pg_advisory_lock` | ✅ Done |
| Dirty state machine | ✅ | ✅ | ✅ Done |
| Migration history | ❌ single-row | ❌ single-row + `applied_at` | ✅ Done |
| Lock timeout | ✅ 15s | ✅ `lock_timeout` ms (default 15s) | ✅ Done |
| GracefulStop | ✅ channel | ❌ | 🔲 Planned |
| Logger interface | ✅ pluggable | ✅ optional `logger` fun/2 in Config | ✅ Done |
| CLI tooling | ✅ | ❌ library only | 🔲 Future |
| Source abstraction | ✅ 15+ sources | filesystem only | 🔲 Future |
| Multi-database | ✅ 15+ | PostgreSQL / MySQL / SQLite | ✅ Done |
| Integration tests | ✅ Docker | 🔲 planned | 🔲 Planned |

---

## Installation / 安装

### PostgreSQL

Add `epgsql` to your own `deps`. `erlang_migrate` has **zero hard dependencies**.

在你的 `deps` 中添加 `epgsql`。`erlang_migrate` **没有任何硬依赖**。

```erlang
{deps, [
    {erlang_migrate, "0.2.1"},
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
    {erlang_migrate, "0.2.1"},
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
    {erlang_migrate, "0.2.1"},
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
    {erlang_migrate, {git, "https://github.com/imboy-pub/erlang_migrate.git", {tag, "v0.2.1"}}}
]}.
```

---

## Development / 开发

```bash
rebar3 compile
rebar3 eunit
```

---

## License / 许可证

Apache 2.0 — see [LICENSE](LICENSE)
