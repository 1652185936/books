import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { MigrationRunner, SqlAssetLoader } from './MigrationRunner';

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
