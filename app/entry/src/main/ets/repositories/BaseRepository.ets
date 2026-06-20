import { relationalStore } from '@kit.ArkData';
import { Database, TransactionWork } from '../database/Database';
import { AppError } from '../domain/entities/common';
import { AppErrors, DB_QUERY_FAILED } from '../utils/AppErrors';

/**
 * 结果集行映射器：把游标当前行映射为领域对象。
 * 映射器只读取当前行（不得移动游标/关闭结果集），由 `queryList`/`querySingle` 负责遍历与释放。
 */
export type RowMapper<T> = (cursor: relationalStore.ResultSet) => T;

/**
 * Repository 基类（P0-4，CLAUDE.md §5 / LLD §7、§8）。
 *
 * 统一约定：
 * - **页面与 ViewModel 不得直接执行 SQL**，一律经 Repository；底层 `store` 仅对子类
 *   （Repository / DAO）`protected` 可见，不向上层暴露。
 * - 读取统一经 `queryList`/`querySingle`：内部保证 `ResultSet` 在 `finally` 中关闭，
 *   避免游标泄漏；任何查询异常归一为 `DB_QUERY_FAILED` 领域错误（不抛裸字符串，04 §1）。
 * - 写入若涉及多表/多步，必须经 `runInTransaction` 在单个事务内完成（可回滚，LLD §8）。
 *
 * 未编译验证（缺 HarmonyOS SDK）：relationalStore `querySql`/`ResultSet` API 以 API 12 为准。
 */
export abstract class BaseRepository {
  /** 数据库封装（持有底层 store 与事务能力）。 */
  private readonly database: Database;

  /**
   * @param database 已完成迁移、就绪的数据库封装。
   */
  protected constructor(database: Database) {
    this.database = database;
  }

  /**
   * 取得底层关系数据库实例（仅供子类 DAO 做 insert/update/delete 等写入）。
   * @returns relationalStore 实例。
   */
  protected get store(): relationalStore.RdbStore {
    return this.database.getStore();
  }

  /**
   * 在单个事务内执行写入工作单元（成功提交、失败回滚，委托 `Database.withTransaction`）。
   * @param work 事务工作单元。
   * @returns 工作单元返回值。
   * @throws AppError 失败时抛出（事务已回滚）。
   */
  protected runInTransaction<T>(work: TransactionWork<T>): Promise<T> {
    return this.database.withTransaction(work);
  }

  /**
   * 执行查询并把每一行经 `mapper` 映射为领域对象列表，结束后释放结果集。
   * @param sql 查询语句（参数用 `?` 占位）。
   * @param mapper 行映射器。
   * @param bindArgs 绑定参数，默认空数组。
   * @returns 领域对象数组。
   * @throws AppError 查询或映射失败时抛出 `DB_QUERY_FAILED`。
   */
  protected async queryList<T>(
    sql: string, mapper: RowMapper<T>, bindArgs: relationalStore.ValueType[] = []): Promise<T[]> {
    try {
      // 查询结果集（须在 finally 中关闭）
      const resultSet: relationalStore.ResultSet = await this.store.querySql(sql, bindArgs);
      // 累积映射结果
      const rows: T[] = [];
      try {
        while (resultSet.goToNextRow()) {
          rows.push(mapper(resultSet));
        }
      } finally {
        resultSet.close();
      }
      return rows;
    } catch (cause) {
      throw AppErrors.from(cause, DB_QUERY_FAILED);
    }
  }

  /**
   * 执行查询并返回首行映射结果；无结果时返回 `undefined`，结束后释放结果集。
   * @param sql 查询语句（参数用 `?` 占位）。
   * @param mapper 行映射器。
   * @param bindArgs 绑定参数，默认空数组。
   * @returns 首行领域对象或 `undefined`。
   * @throws AppError 查询或映射失败时抛出 `DB_QUERY_FAILED`。
   */
  protected async querySingle<T>(
    sql: string, mapper: RowMapper<T>, bindArgs: relationalStore.ValueType[] = []): Promise<T | undefined> {
    try {
      // 查询结果集（须在 finally 中关闭）
      const resultSet: relationalStore.ResultSet = await this.store.querySql(sql, bindArgs);
      try {
        if (resultSet.goToFirstRow()) {
          return mapper(resultSet);
        }
        return undefined;
      } finally {
        resultSet.close();
      }
    } catch (cause) {
      throw AppErrors.from(cause, DB_QUERY_FAILED);
    }
  }

  /**
   * 把任意异常归一为领域错误（供子类在自定义流程中复用）。
   * @param cause 捕获到的异常。
   * @param fallbackCode 非 AppError 时使用的兜底错误码。
   * @returns AppError。
   */
  protected wrapError(cause: Object | null | undefined, fallbackCode: string): AppError {
    return AppErrors.from(cause, fallbackCode);
  }
}
