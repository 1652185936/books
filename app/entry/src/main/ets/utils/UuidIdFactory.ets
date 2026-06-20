/**
 * 内部主键生成器生产实现（P1-4）。以 `@kit.ArkTS` 的 `util.generateRandomUUID` 产出唯一 ID，
 * 供导入落库（`ContentMapper` / `ImportIndexer`）为 books/chapters/sections/... 生成 TEXT 主键。
 *
 * `ContentMapper` 仅依赖纯接口 `IdFactory`（不触 `@ohos.*`，可单测）；本文件是其 SDK 侧适配。
 * 未编译验证（缺 HarmonyOS SDK）：`util.generateRandomUUID` 形态以 API 12 为准。
 */
import { util } from '@kit.ArkTS';
import { IdFactory } from '../services/import/ContentMapper';

/**
 * 基于随机 UUID 的主键生成器。
 */
export class UuidIdFactory implements IdFactory {
  /**
   * 生成一个新的随机 UUID 字符串（带连字符的标准形式）。
   * @returns UUID 字符串。
   */
  newId(): string {
    // 生成随机 UUID（true=带连字符标准格式）
    return util.generateRandomUUID(true);
  }
}
