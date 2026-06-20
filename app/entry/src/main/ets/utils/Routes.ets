/**
 * 路由名常量、路由参数类型与参数归一化（LLD §6 各页面路由 / §6.13 路由参数约定 R-061）。
 *
 * 作为应用 Navigation 路由表的「逻辑真值」：`route_map.json`（系统路由表）以此处 `RouteName`
 * 字面量为 `name` 注册各 NavDestination；各页面以此处 `*Params` 接口约束 `pushPathByName` 的
 * 入参与 `onReady` 取参。本模块为纯逻辑（不依赖 ArkUI），§6.13 的缺省/非法兜底语义集中于此，便于单测。
 */

/** 进入练习页（P-F06/P-F07）的来源标识（§6.13）：决定「返回」回到章节还是错题本。 */
export type ExerciseFrom = 'chapter' | 'wrongbook';

/** 学习统计页（P-F11）时间范围（§6.13）。 */
export type StatisticsRange = 'day' | 'week' | 'month';

/** `from` 缺省值：由章节讲解/目录进入，「返回」回到该章节（§6.13）。 */
export const DEFAULT_EXERCISE_FROM: ExerciseFrom = 'chapter';

/** `range` 缺省值：按周聚合（§6.11 / §6.13）。 */
export const DEFAULT_STATISTICS_RANGE: StatisticsRange = 'week';

/**
 * 路由名常量。值与 LLD §6 路由 token 一致，并作为 `route_map.json` 的 `name`。
 * 含 path 参数的路由（catalog/lesson/exercise/importValidate）其参数走 `pushPathByName` 的 param 对象，不拼进 name。
 */
export class RouteName {
  /** P-F01 书架页（Navigation 根内容，非 NavDestination，§6.1）。 */
  static readonly BOOKSHELF: string = 'bookshelf';
  /** P-F02 导入选择页（§6.2）。 */
  static readonly IMPORT_SELECT: string = 'import/select';
  /** P-F03 校验页（param: jobId，§6.3）。 */
  static readonly IMPORT_VALIDATE: string = 'import/validate';
  /** P-F04 书籍目录页（param: bookId，§6.4）。 */
  static readonly CATALOG: string = 'book';
  /** P-F05 章节讲解页（param: bookId/chapterId/section?，§6.5）。 */
  static readonly LESSON: string = 'lesson';
  /** P-F06/P-F07 手写练习与识别判分页（param: bookId/chapterId/exerciseId/from?，§6.6/§6.7）。 */
  static readonly EXERCISE: string = 'exercise';
  /** P-F09 复习页（param: bookId?，§6.9）。 */
  static readonly REVIEW: string = 'review';
  /** P-F10 错题本页（param: bookId?，§6.10）。 */
  static readonly WRONGBOOK: string = 'wrongbook';
  /** P-F11 学习统计页（param: bookId?/range?，§6.11）。 */
  static readonly STATISTICS: string = 'statistics';
  /** P-F12 设置与数据页（param: section?，§6.12）。 */
  static readonly SETTINGS: string = 'settings';
}

/** P-F03 校验页参数（§6.3）。 */
export interface ImportValidateParams {
  /** 导入任务 ID（import_jobs.id）。 */
  jobId: string;
}

/** P-F04 目录页参数（§6.4）。 */
export interface CatalogParams {
  /** 书籍内部主键。 */
  bookId: string;
}

/** P-F05 章节讲解页参数（§6.5）。 */
export interface LessonParams {
  /** 书籍内部主键。 */
  bookId: string;
  /** 章节内部主键。 */
  chapterId: string;
  /** 可选小节 ID；缺省进入 sections 下标 0 或恢复 last_section_id（§6.5 R-034）。 */
  section?: string;
}

/** P-F06/P-F07 练习页参数（§6.6/§6.7）。 */
export interface ExerciseParams {
  /** 书籍内部主键。 */
  bookId: string;
  /** 章节内部主键。 */
  chapterId: string;
  /** 练习内部主键。 */
  exerciseId: string;
  /** 进入来源；缺省按 'chapter' 处理（§6.13）。 */
  from?: ExerciseFrom;
}

/** P-F09 复习页参数（§6.9）。 */
export interface ReviewParams {
  /** 可选书籍主键；缺省 = 全部书籍聚合（§6.13）。 */
  bookId?: string;
}

/** P-F10 错题本页参数（§6.10）。 */
export interface WrongBookParams {
  /** 可选书籍主键；缺省 = 全部书籍聚合（§6.13）。 */
  bookId?: string;
}

/** P-F11 学习统计页参数（§6.11）。 */
export interface StatisticsParams {
  /** 可选书籍主键；缺省 = 全部书籍聚合（§6.13）。 */
  bookId?: string;
  /** 时间范围；缺省/非法回退 'week'（§6.13）。 */
  range?: StatisticsRange;
}

/** P-F12 设置页参数（§6.12）。 */
export interface SettingsParams {
  /** 设置分区标识；缺省进入默认分区。 */
  section?: string;
}

/**
 * 归一化练习来源标识。缺省或非法值回退 'chapter'（§6.13）。
 * @param from 原始来源字符串（可能来自深链，未必合法）
 * @returns 合法的 ExerciseFrom
 */
export function normalizeExerciseFrom(from?: string): ExerciseFrom {
  // 仅 'wrongbook' 走错题本返回栈，其余（含缺省/非法）按章节来源处理
  return from === 'wrongbook' ? 'wrongbook' : DEFAULT_EXERCISE_FROM;
}

/**
 * 归一化统计时间范围。缺省或非法值回退 'week'，不取空数据（§6.13）。
 * @param range 原始范围字符串（可能来自深链）
 * @returns 合法的 StatisticsRange
 */
export function normalizeStatisticsRange(range?: string): StatisticsRange {
  // 合法集合 day/week/month；其余一律回退 week
  return range === 'day' || range === 'month' ? range : DEFAULT_STATISTICS_RANGE;
}

/**
 * 归一化可选 bookId。空串/纯空白视为缺省（= 全部书籍聚合，§6.13）。
 * @param bookId 原始 bookId（可能为空串）
 * @returns 去空白后的 bookId；缺省返回 undefined
 */
export function normalizeOptionalBookId(bookId?: string): string | undefined {
  // 省略 = 全部书籍聚合：空串/纯空白等价于未传
  const trimmed: string = (bookId ?? '').trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

/** 路由表条目：路由名 → 标题资源键。 */
export interface RouteTableEntry {
  /** 路由名（= route_map.json 的 name）。 */
  name: string;
  /** 标题字符串资源名（element/string.json）。 */
  titleKey: string;
}

/**
 * 应用路由表（LLD §6）。`BOOKSHELF` 为 Navigation 根内容，其余为 `route_map.json` 注册的 NavDestination。
 * 标题资源键集中于此，作为占位页标题取值的单一来源，避免散落硬编码（CLAUDE.md §5）。
 */
export const ROUTE_TABLE: RouteTableEntry[] = [
  { name: RouteName.BOOKSHELF, titleKey: 'route_title_bookshelf' },
  { name: RouteName.IMPORT_SELECT, titleKey: 'route_title_import_select' },
  { name: RouteName.IMPORT_VALIDATE, titleKey: 'route_title_import_validate' },
  { name: RouteName.CATALOG, titleKey: 'route_title_catalog' },
  { name: RouteName.LESSON, titleKey: 'route_title_lesson' },
  { name: RouteName.EXERCISE, titleKey: 'route_title_exercise' },
  { name: RouteName.REVIEW, titleKey: 'route_title_review' },
  { name: RouteName.WRONGBOOK, titleKey: 'route_title_wrongbook' },
  { name: RouteName.STATISTICS, titleKey: 'route_title_statistics' },
  { name: RouteName.SETTINGS, titleKey: 'route_title_settings' },
];
