import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { MigrationRunner, SqlAssetLoader } from './MigrationRunner';
import { AppErrors, DB_TRANSACTION_FAILED } from '../utils/AppErrors';

/**
 * 事务工作单元：在已开启的事务内执行写入/读取并返回结果。
 * 由 `withTransaction` 注入底层 `store`，回调内部**不得**自行 begin/commit/rollBack。
 */
export type TransactionWork<T> = (store: relationalStore.RdbStore) => Promise<T>;

/** 数据库文件名（应用沙箱内，LLD §1.3：本地关系数据）。 */
const DB_NAME: string = 'moxue.db';

/**
 * relationalStore 数据库封装（P0-3，LLD §1.1/§3）。
 *
 * 负责：打开/创建本地 RDB、开启外键约束、首启与升级时执行迁移。
 * 页面与服务通过 `getStore()` 取得底层 store，但**页面不得直接执行 SQL**（CLAUDE.md §5）；
 * 统一的 Repository 基类与事务封装在 P0-4 落地。
 *
 * 未编译验证（缺 HarmonyOS SDK）：relationalStore / resourceManager / TextDecoder API 形态
 * 以 API 12（compatibleSdkVersion 5.0.0(12)）为准，真机行为待 SDK 实测。
 */
export class Database {
  /** 底层关系数据库实例。 */
  private readonly store: relationalStore.RdbStore;

  /**
   * 私有构造，强制经 `open()` 创建（确保迁移已执行）。
   * @param store 已完成迁移的数据库实例。
   */
  private constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  /**
   * 打开（或首次创建）数据库并执行全部待应用迁移。
   * @param context 应用/Ability 上下文（提供沙箱目录与 rawfile 资源）。
   * @returns 已就绪的 Database 实例。
   * @throws AppError 迁移失败时由 MigrationRunner 抛出。
   */
  static async open(context: common.Context): Promise<Database> {
    // RDB 存储配置：S2 安全级（本地个人学习数据）
    const config: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S2
    };
    // 打开或创建数据库
    const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
    // 开启外键约束（relationalStore 默认不强制外键，须显式开启）
    await store.executeSql('PRAGMA foreign_keys = ON');
    // 基于 rawfile 的 SQL 资源加载器
    const loadAsset: SqlAssetLoader = Database.createRawfileLoader(context);
    // 执行迁移（首启建表；后续仅应用新增迁移，幂等且单调）
    await MigrationRunner.run(store, loadAsset);
    return new Database(store);
  }

  /**
   * 取得底层关系数据库实例（供 Repository 层使用）。
   * @returns relationalStore 实例。
   */
  getStore(): relationalStore.RdbStore {
    return this.store;
  }

  /**
   * 事务/可回滚封装（P0-4，LLD §8）。在单个事务内执行 `work`，成功提交、失败整体回滚。
   *
   * 约束：relationalStore 经典事务**不可重入**——同一时刻仅一个活动事务，
   * `work` 内部不得再次开启事务（嵌套调用须在同一回调内串行完成全部读写，LLD §8）。
   * 失败时统一归一为领域错误：`work` 抛出的 `AppError` 透传，其它异常包成
   * `DB_TRANSACTION_FAILED`（不输出用户内容/笔迹/敏感路径，CLAUDE.md §5）。
   *
   * @param work 事务工作单元，接收底层 store 并返回结果。
   * @returns 工作单元的返回值（事务已提交）。
   * @throws AppError 工作单元失败时抛出（事务已回滚）。
   */
  async withTransaction<T>(work: TransactionWork<T>): Promise<T> {
    this.store.beginTransaction();
    try {
      // 事务内执行的业务结果
      const result: T = await work(this.store);
      this.store.commit();
      return result;
    } catch (cause) {
      // 任一步失败整体回滚，再把异常归一为领域错误向上抛出
      this.store.rollBack();
      throw AppErrors.from(cause, DB_TRANSACTION_FAILED);
    }
  }

  /**
   * 构造从 rawfile 读取 UTF-8 SQL 文本的加载器。
   * @param context 提供 resourceManager 的上下文。
   * @returns SqlAssetLoader 闭包。
   */
  private static createRawfileLoader(context: common.Context): SqlAssetLoader {
    return (assetPath: string): string => {
      // rawfile 字节内容
      const bytes: Uint8Array = context.resourceManager.getRawFileContentSync(assetPath);
      // UTF-8 解码器（忽略 BOM）
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: false, ignoreBOM: true });
      return decoder.decodeWithStream(bytes, { stream: false });
    };
  }
}
