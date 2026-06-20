/**
 * 设置 DTO 契约（《04-接口与DTO契约》§10，F12 / R-053）。
 * 键与值类型与 LLD §3.24 user_settings 第一版键一致；set 必须按 SettingsValueMap 与 §3.24 做键级校验后才落库，
 * 校验失败抛可转 AppError 的领域错误且不写库（04 §12 规则8）。
 *
 * 未编译验证（缺 HarmonyOS SDK）：get/set 沿用 04 的泛型索引访问返回类型 SettingsValueMap[K]。
 * 若 ArkTS 严格模式不支持索引访问类型（且不支持方法重载），将在 F12 实现期按 ArkTS 等价形式调整，
 * 并先在《已知冲突与裁决记录》登记冲突；本轮不擅自降级语义。
 */

/** 设置键。 */
export type SettingsKey =
  | 'handwriting.penColor'
  | 'handwriting.penWidth'
  | 'recognition.failureAction'
  | 'review.dailyGoal'
  | 'reading.fontScale'
  | 'wrongbook.masteryStreak';

/** 键到值类型映射（与 LLD §3.24 一致）。 */
export interface SettingsValueMap {
  /** 笔色 #RRGGBB。 */
  'handwriting.penColor': string;
  /** 笔宽 0.5..20。 */
  'handwriting.penWidth': number;
  /** 识别失败动作。 */
  'recognition.failureAction': 'retry' | 'rewrite';
  /** 每日复习目标 1..500。 */
  'review.dailyGoal': number;
  /** 阅读字号缩放 0.8..1.6。 */
  'reading.fontScale': number;
  /** 错题掌握连对阈值 1..10。 */
  'wrongbook.masteryStreak': number;
}

/** 设置服务契约。 */
export interface SettingsService {
  /**
   * 取设置值。
   * @param key 设置键
   * @returns 该键对应类型的值
   */
  get<K extends SettingsKey>(key: K): Promise<SettingsValueMap[K]>;
  /**
   * 取全部设置。
   * @returns 全键值映射
   */
  getAll(): Promise<SettingsValueMap>;
  /**
   * 写设置值（键级校验，越界/非法拒绝且不写库）。
   * @param key 设置键
   * @param value 该键对应类型的值
   */
  set<K extends SettingsKey>(key: K, value: SettingsValueMap[K]): Promise<void>;
}
