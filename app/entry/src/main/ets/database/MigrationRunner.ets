import { relationalStore } from '@kit.ArkData';
import { AppError } from '../domain/entities/common';
import { SqlScript } from './SqlScript';
import { Migration, MIGRATIONS } from './migrations/MigrationRegistry';

/**
 * SQL 资源加载器：按 rawfile 相对路径返回 UTF-8 文本。
 * 由 `Database` 用 `resourceManager` 提供默认实现；单测可注入内存实现。
 */
export type SqlAssetLoader = (assetPath: string) => string;

/** 迁移失败时的领域错误码（非用户内容，仅结构性错误）。 */
const MIGRATION_FAILED_CODE: string = 'DB_MIGRATION_FAILED';
/** 迁移失败的用户可见文案资源键（LLD §3.14B 通用状态键）。 */
const MIGRATION_FAILED_MSG_KEY: string = 'state.error';
/** 脱敏诊断详情上限（CLAUDE.md §5：不泄露完整内容/路径）。 */
const DETAIL_MAX_LEN: number = 200;

/**
 * 数据库迁移执行器（P0-3）。
 *
 * 职责：
 * - 引导元数据表 `schema_migrations`（迁移表）与 `db_meta`（§3.2 必需键）；
 * - 读取已应用的最高版本，筛出 `version > current` 的待应用迁移；
 * - 校验登记表版本**单调递增、唯一、无缺号**；
 * - 每条迁移在**单个事务**内执行全部语句并写入迁移记录，失败整体回滚（只执行一次、可回滚）。
 *
 * 未编译验证（缺 HarmonyOS SDK）：事务采用经典 `beginTransaction`/`commit`/`rollBack`；
 * DDL 与约束已在 SQLite 底座全量验证。relationalStore 真机行为以 SDK 实测为准。
 */
export class MigrationRunner {
  /**
   * 执行全部待应用迁移。
   * @param store 已打开的关系数据库实例。
   * @param loadAsset SQL 资源加载器。
   * @returns 本次实际应用的迁移条数（0 表示已是最新）。
   * @throws AppError 任一迁移失败时抛出（该迁移已回滚）。
   */
  static async run(store: relationalStore.RdbStore, loadAsset: SqlAssetLoader): Promise<number> {
    // 先校验登记表自洽，再引导元数据表
    MigrationRunner.validateRegistry();
    await MigrationRunner.ensureMetaTables(store);
    // 已应用的最高版本号
    const current: number = await MigrationRunner.getCurrentVersion(store);
    // 待应用迁移（version 严格大于 current，升序）
    const pending: Migration[] = MIGRATIONS
      .filter((migration: Migration): boolean => migration.version > current)
      .sort((a: Migration, b: Migration): number => a.version - b.version);
    // 逐条在独立事务内应用
    let appliedCount: number = 0;
    for (const migration of pending) {
      await MigrationRunner.applyOne(store, migration, loadAsset);
      appliedCount += 1;
    }
    return appliedCount;
  }

  /**
   * 校验迁移登记表：版本号必须从 1 起、严格递增、唯一、无缺号。
   * @throws AppError 登记表不合法时抛出（开发期错误，应在测试中暴露）。
   */
  private static validateRegistry(): void {
    // 期望的下一个版本号（从 1 起连续）
    let expected: number = 1;
    for (const migration of MIGRATIONS) {
      if (migration.version !== expected) {
        throw MigrationRunner.buildError(
          `迁移登记表非法：期望 version=${expected}，实际 ${migration.version}（${migration.name}）`);
      }
      expected += 1;
    }
  }

  /**
   * 引导元数据表（幂等）。`schema_migrations` 为迁移表，`db_meta` 承载 §3.2 必需键。
   * @param store 数据库实例。
   */
  private static async ensureMetaTables(store: relationalStore.RdbStore): Promise<void> {
    await store.executeSql(
      'CREATE TABLE IF NOT EXISTS schema_migrations (' +
      'version INTEGER NOT NULL PRIMARY KEY, name TEXT NOT NULL, applied_at INTEGER NOT NULL)');
    await store.executeSql(
      'CREATE TABLE IF NOT EXISTS db_meta (' +
      'key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL)');
  }

  /**
   * 读取已应用的最高迁移版本号。
   * @param store 数据库实例。
   * @returns 最高版本号；无任何记录时返回 0。
   */
  private static async getCurrentVersion(store: relationalStore.RdbStore): Promise<number> {
    // MAX(version) 查询结果集
    const resultSet: relationalStore.ResultSet =
      await store.querySql('SELECT MAX(version) AS v FROM schema_migrations');
    // 当前最高版本（默认 0）
    let current: number = 0;
    try {
      if (resultSet.goToFirstRow()) {
        // 列索引
        const columnIndex: number = resultSet.getColumnIndex('v');
        if (!resultSet.isColumnNull(columnIndex)) {
          current = resultSet.getLong(columnIndex);
        }
      }
    } finally {
      resultSet.close();
    }
    return current;
  }

  /**
   * 在单个事务内应用一条迁移：执行全部语句并写迁移记录与 db_meta，失败整体回滚。
   * @param store 数据库实例。
   * @param migration 待应用迁移。
   * @param loadAsset SQL 资源加载器。
   * @throws AppError 执行失败时抛出（事务已回滚）。
   */
  private static async applyOne(
    store: relationalStore.RdbStore, migration: Migration, loadAsset: SqlAssetLoader): Promise<void> {
    // 迁移脚本切分得到的单语句数组
    const statements: string[] = SqlScript.splitStatements(loadAsset(migration.assetPath));
    // 本次迁移时间戳（UTC ms）
    const now: number = Date.now();
    store.beginTransaction();
    try {
      for (const sql of statements) {
        await store.executeSql(sql);
      }
      await store.executeSql(
        'INSERT INTO schema_migrations (version, name, applied_at) VALUES (?, ?, ?)',
        [migration.version, migration.name, now]);
      await MigrationRunner.writeMeta(store, migration.version, now);
      store.commit();
    } catch (cause) {
      store.rollBack();
      throw MigrationRunner.buildError(
        `迁移 v${migration.version}(${migration.name}) 失败：${MigrationRunner.briefMessage(cause)}`);
    }
  }

  /**
   * 写入 §3.2 必需的 db_meta 键：`created_at`（仅首次）、`schema_version`、`last_migration_at`。
   * @param store 数据库实例。
   * @param version 本次应用到的版本号。
   * @param now 当前时间戳（UTC ms）。
   */
  private static async writeMeta(
    store: relationalStore.RdbStore, version: number, now: number): Promise<void> {
    // created_at 仅在首次缺失时写入
    await store.executeSql(
      "INSERT OR IGNORE INTO db_meta (key, value, updated_at) VALUES ('created_at', ?, ?)",
      [now.toString(), now]);
    // schema_version 反映已应用的最高版本
    await store.executeSql(
      "INSERT INTO db_meta (key, value, updated_at) VALUES ('schema_version', ?, ?) " +
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at',
      [version.toString(), now]);
    // last_migration_at 记录最近一次迁移时间
    await store.executeSql(
      "INSERT INTO db_meta (key, value, updated_at) VALUES ('last_migration_at', ?, ?) " +
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at',
      [now.toString(), now]);
  }

  /**
   * 构造迁移领域错误（不可重试，文案走通用状态键）。
   * @param detail 已脱敏的诊断详情。
   * @returns AppError。
   */
  private static buildError(detail: string): AppError {
    return {
      code: MIGRATION_FAILED_CODE,
      messageKey: MIGRATION_FAILED_MSG_KEY,
      retryable: false,
      detail: detail.length > DETAIL_MAX_LEN ? detail.substring(0, DETAIL_MAX_LEN) : detail
    };
  }

  /**
   * 从异常对象提取简短消息（迁移属结构性错误，不含用户内容/笔迹/敏感路径）。
   * @param cause 捕获到的异常。
   * @returns 简短消息字符串。
   */
  private static briefMessage(cause: Object): string {
    // BusinessError 继承自 Error，统一按 Error.message 提取结构性描述
    if (cause instanceof Error) {
      return cause.message;
    }
    return String(cause);
  }
}
