/**
 * 数据库迁移登记表（P0-3，LLD §1.3「所有迁移必须单调递增」）。
 *
 * 每条迁移的 DDL/DML 以 rawfile 内的 `.sql` 资源为唯一真值；本登记表只声明
 * 「版本号 → 资源路径」的有序映射。新增迁移**只能在数组末尾追加**，
 * 禁止修改或删除历史条目（CLAUDE.md §5：数据库升级只新增迁移，不删旧迁移）。
 */

/** 单条数据库迁移的描述。 */
export interface Migration {
  /** 迁移版本号（单调递增，从 1 起；与 schema_migrations.version 对应）。 */
  readonly version: number;
  /** 迁移名（用于日志与迁移表记录，不含敏感信息）。 */
  readonly name: string;
  /** rawfile 内 SQL 资源相对路径（相对 `resources/rawfile/`）。 */
  readonly assetPath: string;
}

/**
 * 全部迁移，按 `version` 升序登记。
 * V001 建立 LLD §3.3~§3.25 全部业务表与索引；元数据表（db_meta / schema_migrations）
 * 由 MigrationRunner 在迁移前以 `CREATE TABLE IF NOT EXISTS` 引导建立，不在此列。
 */
export const MIGRATIONS: Migration[] = [
  { version: 1, name: 'initial', assetPath: 'migrations/V001__initial.sql' }
];
