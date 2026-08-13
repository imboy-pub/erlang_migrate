> [imboy.pub 根目录](../CLAUDE.md) > **erlang_migrate（Erlang 迁移库）**

# erlang_migrate - AI 上下文文档

> **最后更新**: 2026-06-10 | **语言**: Erlang/OTP | **构建**: rebar3

---

## 库定位与用途

数据库 Schema 迁移库，专为 Erlang/OTP 项目设计。采用驱动模式（behaviour），无硬运行时依赖，支持 PostgreSQL、MySQL、SQLite。

核心设计原则：
- 迁移文件为纯 SQL 文件，命名约定 `{version}_{title}.up.sql` / `{version}_{title}.down.sql`
- 版本号为正整数（可用时间戳格式如 `20240101120000`）
- 通过排他锁防并发冲突，支持 `dirty` 标记检测异常中断

---

## 核心模块

| 模块 | 职责 |
|------|------|
| `erlang_migrate` | 对外 API 入口：`up/down/goto/version/force/drop/create`，编排锁、驱动与 source |
| `erlang_migrate_source` | 扫描目录获取迁移文件列表，按版本排序（标题支持 UTF-8） |
| `erlang_migrate_driver` | 驱动 behaviour 定义；可选回调 `applied_versions/2`（strict 模式需要） |
| `erlang_migrate_cli` | escript CLI 入口（`rebar3 escriptize`），仅 `new` 子命令生成迁移文件 |

### strict 模式（乱序检测）

`Config` 加 `strict => true`：已应用迁移同步记录到 `<table>_history` 表；
`up` 发现"版本 =< 当前版本但从未应用"的文件时返回 `{error, {out_of_order, Versions}}`，
解决时间戳版本号多人开发下后合并迁移被静默跳过的问题。
首次启用自动回填；`force/2` 重建历史；`dry_run` 跳过 strict。

### create/2 与 CLI

```erlang
{ok, Up, Down} = erlang_migrate:create("priv/migrations", "add_user_index").
%% 生成 {UTC时间戳YYYYMMDDHHMMSS}_{title}.up.sql / .down.sql，同秒冲突自动 +1
```

```bash
rebar3 escriptize && _build/default/bin/erlang_migrate_cli new add_user_index priv/migrations
```

---

## 核心 API

### erlang_migrate_source

```erlang
%% 扫描目录，返回按版本升序排列的迁移列表
-spec scan(Dir :: file:filename()) ->
    {ok, [migration()]} | {error, term()}.

%% 读取迁移文件 SQL 内容
-spec read_sql(File :: file:filename(), Direction :: up | down) ->
    {ok, binary()} | {error, term()}.

%% migration() 类型
-type migration() :: #{
    version   := integer(),
    title     := binary(),
    up_file   := file:filename(),
    down_file := file:filename() | undefined
}.
```

### erlang_migrate_driver（behaviour 回调）

```erlang
%% 创建或验证 schema_migrations 追踪表
-callback ensure_table(Conn, Table :: binary()) -> ok | {error, term()}.

%% 获取当前最高已应用版本，返回 {ok, Version | undefined, Dirty}
-callback current_version(Conn, Table :: binary()) ->
    {ok, integer() | undefined, boolean()} | {error, term()}.

%% 获取排他锁（防并发）
-callback lock(Conn, LockId :: integer(), TimeoutMs :: integer()) ->
    ok | {error, lock_timeout} | {error, term()}.

%% 释放锁
-callback unlock(Conn, LockId :: integer()) -> ok.

%% 更新追踪行（Version=undefined 表示无已应用迁移）
-callback set_version(Conn, Table :: binary(),
                      Version :: integer() | undefined, Dirty :: boolean()) ->
    ok | {error, term()}.

%% 检查当前版本是否处于 dirty 状态
-callback is_dirty(Conn, Table :: binary()) -> {ok, boolean()} | {error, term()}.

%% 执行任意 SQL
-callback exec_sql(Conn, SQL :: binary()) -> ok | {error, term()}.

%% 删除追踪表
-callback drop_table(Conn, Table :: binary()) -> ok | {error, term()}.
```

---

## 迁移文件命名规范

```
priv/migrations/
├── 1_create_users.up.sql
├── 1_create_users.down.sql
├── 2_add_email_index.up.sql
└── 20240101120000_add_column.up.sql   # 时间戳格式版本号也可
```

- 版本号：正整数，必须唯一，升序执行
- `down.sql` 可选；无则回滚时报错
- 文件内容：标准 SQL，库不做解析，原样传给驱动执行

---

## 依赖说明

```
运行时依赖：无（零依赖）
测试依赖：meck 0.9.2, epgsql 4.8.0, mysql 1.8.0, esqlite 0.8.1
```

使用方在自己的 `rebar.config` 中按需添加驱动依赖（如仅用 PostgreSQL 只需添加 `epgsql`）。

---

## 与 imboy 主项目的集成

- imboy 使用 PostgreSQL 作为数据库，对应使用 epgsql 驱动实现
- 迁移文件位于 `imboy/priv/migrations/*.sql`
- 通过 `make ctl ARGS="db ping"` 验证数据库连接
- 迁移通过 `make ctl ARGS="db migrate"` 执行（或等效命令）

---

## 测试

```
test/
├── erlang_migrate_source_tests.erl   # source 模块单元测试
├── erlang_migrate_tests.erl          # 核心流程测试
├── erlang_migrate_create_tests.erl   # create/2 生成器测试
├── erlang_migrate_pg_tests.erl       # PostgreSQL 驱动测试
├── erlang_migrate_mysql_tests.erl    # MySQL 驱动测试
└── erlang_migrate_sqlite_tests.erl   # SQLite 驱动测试
```

运行测试：
```bash
rebar3 eunit
rebar3 as test eunit   # 含测试依赖
```

---

## 关键文件清单

| 文件 | 说明 |
|------|------|
| `src/erlang_migrate_source.erl` | 迁移文件扫描与读取 |
| `src/erlang_migrate_driver.erl` | 驱动 behaviour 定义 |
| `rebar.config` | 构建配置，运行时零依赖 |
| `rebar.lock` | 依赖锁定文件 |

---

## 变更记录

| 日期 | 内容 |
|------|------|
| 2026-06-10 | 新增 strict 乱序检测（`<table>_history` + 可选回调 `applied_versions/2`）、`create/2` 生成器、`erlang_migrate_cli` escript；修复 UTF-8 标题崩溃与日志乱码 |
| 2026-05-28 | 初始 CLAUDE.md 创建，覆盖库定位、核心 API、迁移规范、集成方式 |
