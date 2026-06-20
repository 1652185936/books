/**
 * P-F02 导入选择页（LLD §6.2，路由 `import/select`）。
 *
 * 「选择文件 → 预检查 → 开始校验」垂直切片的 UI 终点：组合 `ImportStepper` / `FilePickerCard` /
 * `SelectedFileRow`，由 `ImportSelectVM` 驱动有限状态（未选择/已选择/空间不足/类型错误/复制中）。
 *
 * 页面约束（§6.2）：
 * - 仅单文件：`DocumentViewPicker` 限选 1 个，只取首个 URI；
 * - 按钮防重复点击：复制中禁用「选择/重新选择/开始校验」，并由 VM 拦截非「已选择」态的二次 create；
 * - 不展示绝对路径：仅经 `SelectedFileRow` 展示脱敏文件名/大小，原 URI 只在内存供 create 使用，不入日志（CLAUDE.md §5）。
 *
 * 跳转：create 成功得 `jobId` 后 `pathStack.pushPathByName('import/validate', { jobId })`（RouteName.IMPORT_VALIDATE，
 * route_map.json 已注册，无需改路由表）。
 *
 * 装配：本页在 `onReady` 用 `getContext` 惰性装配 Database + 端口适配器 + ImportService + VM（无全局 DI 容器，
 * 不改 DI/注册文件）。下方端口生产适配器依赖 HarmonyOS SDK。
 *
 * 未编译验证（缺 HarmonyOS SDK）：`@ohos.file.picker` DocumentViewPicker、`@ohos.file.fs` stat、
 * `@ohos.file.statvfs`、`@kit.CryptoArchitectureKit` SHA-256、URI 持久化授权、ArkUI 组件均以 API 12 为准；
 * 本页 UI 与适配器尚未在真机/SDK 编译验证。
 */
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer, util } from '@kit.ArkTS';
import { statvfs } from '@kit.CoreFileKit';
import { Id } from '../../domain/entities/common';
import { AppError } from '../../domain/entities/common';
import { AppErrors, DB_WRITE_FAILED } from '../../utils/AppErrors';
import { RouteName, ImportValidateParams } from '../../utils/Routes';
import { Database } from '../../database/Database';
import { ImportJobRepository } from '../../repositories/ImportJobRepository';
import { UuidIdFactory } from '../../utils/UuidIdFactory';
import { ImportFs, StagingArea } from '../../services/import/ImportStaging';
import { ImportLifecycle, UriPermissionPort } from '../../services/import/ImportLifecycle';
import { ImportService, UriHasher, UriPersistPort } from '../../services/ImportService';
import { SourceProbePort, SourceFileMeta, FreeSpaceProbePort, StorageProbe } from '../../services/StorageProbe';
import { ImportSelectVM, ImportSelectState, ImportSelectStatus } from '../../viewmodels/ImportSelectVM';
import { ImportStepper, ImportStep } from '../../components/import/ImportStepper';
import { FilePickerCard } from '../../components/import/FilePickerCard';
import { SelectedFileRow } from '../../components/import/SelectedFileRow';

/**
 * P-F02 导入选择页路由构建函数（route_map.json → `import/select`，LLD §6.2）。
 * @returns 无（构建 NavDestination）
 */
@Builder
export function ImportSelectPageBuilder(): void {
  ImportSelectPage();
}

// ===========================================================================
// 端口生产适配器（页面装配的一部分；依赖 HarmonyOS SDK，未编译验证）
// ===========================================================================

/**
 * 来源文件探测适配器：经 `@ohos.file.fs` 读取大小，从 URI 末段取脱敏文件名（不外泄完整 URI）。
 */
class FsSourceProbe implements SourceProbePort {
  /**
   * 探测来源文件脱敏元信息。
   * @param sourceUri 来源文件 URI。
   * @returns 脱敏文件名与字节大小。
   */
  async probeSource(sourceUri: string): Promise<SourceFileMeta> {
    // 仅取 URI 末段作为展示文件名（去查询串），不保留目录/原 URI
    const noQuery: string = sourceUri.split('?')[0];
    const segments: string[] = noQuery.split('/');
    const displayName: string = decodeURIComponent(segments[segments.length - 1]);
    // 以只读方式打开并 stat 取大小，结束即关闭
    const file: fileIo.File = await fileIo.open(sourceUri, fileIo.OpenMode.READ_ONLY);
    try {
      const info: fileIo.Stat = await fileIo.stat(file.fd);
      return { displayName, sizeBytes: info.size };
    } finally {
      await fileIo.close(file.fd);
    }
  }
}

/**
 * 暂存盘可用空间探测适配器：对暂存父目录 `statvfs` 取可用字节。
 */
class StatvfsFreeSpaceProbe implements FreeSpaceProbePort {
  /** 暂存目录绝对路径（context.tempDir）。 */
  private readonly tempDir: string;

  /**
   * @param tempDir 运行期临时目录绝对路径。
   */
  constructor(tempDir: string) {
    this.tempDir = tempDir;
  }

  /**
   * 取暂存盘可用字节数。
   * @returns 可用字节数。
   */
  freeBytes(): Promise<number> {
    return statvfs.getFreeSize(this.tempDir);
  }
}

/**
 * URI 哈希适配器：SHA-256 折算来源 URI（仅存哈希，§3.22）。
 */
class CryptoUriHasher implements UriHasher {
  /**
   * 计算 URI 的十六进制 SHA-256（小写）。
   * @param sourceUri 来源文件 URI。
   * @returns URI 哈希。
   */
  async hashUri(sourceUri: string): Promise<string> {
    // SHA-256 摘要器
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    // UTF-8 字节缓冲
    const bytes: Uint8Array = new Uint8Array(buffer.from(sourceUri, 'utf-8').buffer);
    await md.update({ data: bytes });
    const digest: cryptoFramework.DataBlob = await md.digest();
    // 十六进制小写
    return CryptoUriHasher.toHex(digest.data);
  }

  /**
   * 字节缓冲转十六进制小写字符串。
   * @param data 字节缓冲。
   * @returns 十六进制字符串。
   */
  private static toHex(data: Uint8Array): string {
    // 逐字节补零拼接
    let hex: string = '';
    for (let i: number = 0; i < data.length; i++) {
      const part: string = data[i].toString(16);
      hex += part.length === 1 ? `0${part}` : part;
    }
    return hex;
  }
}

/**
 * 持久化 URI 授权适配器（最佳努力占位）。
 * 注：HarmonyOS 通过 `picker` 选中的文件 URI 在临时授权窗口内可读；持久化授权能力随 SDK 版本而定，
 * 此处保留端口语义、实现为安全 no-op（不抛错，不泄露 URI），待 SDK 接线时补齐持久化能力。
 */
class NoopUriPersist implements UriPersistPort, UriPermissionPort {
  /**
   * 持久化授权（占位 no-op）。
   * @param sourceUri 来源 URI（不记录）。
   * @returns 完成的 Promise。
   */
  persist(sourceUri: string): Promise<void> {
    return Promise.resolve();
  }

  /**
   * 释放授权（占位 no-op）。
   * @param sourceUriHash 来源 URI 哈希（不记录）。
   * @returns 完成的 Promise。
   */
  release(sourceUriHash: string): Promise<void> {
    return Promise.resolve();
  }
}

/**
 * 最小文件系统适配器（取消时清理暂存目录用，复用既有 `ImportFs` 端口）。
 * F02 阶段尚无解压写入，cancel 仅需删除 `temp/import/<jobId>`；其余方法 SDK 接线后由 F03+ 补齐。
 */
class FsImportFs implements ImportFs {
  /**
   * 路径是否存在。
   * @param path 绝对路径。
   * @returns 存在返回 true。
   */
  exists(path: string): Promise<boolean> {
    return fileIo.access(path);
  }

  /**
   * 递归创建目录。
   * @param path 目录绝对路径。
   * @returns 完成的 Promise。
   */
  mkdirs(path: string): Promise<void> {
    return fileIo.mkdir(path, true);
  }

  /**
   * 递归删除（不存在视为成功）。
   * @param path 绝对路径。
   * @returns 完成的 Promise。
   */
  async remove(path: string): Promise<void> {
    // 不存在直接成功（幂等清理）
    if (await fileIo.access(path)) {
      await fileIo.rmdir(path);
    }
  }

  /**
   * 原子移动（F02 未用，占位待 F03+）。
   * @param from 源路径。
   * @param to 目标路径。
   * @returns 完成的 Promise。
   */
  move(from: string, to: string): Promise<void> {
    return fileIo.moveFile(from, to);
  }

  /**
   * 读取文本（F02 未用，占位待 F03+）。
   * @param path 文件绝对路径。
   * @returns 文本内容。
   */
  readText(path: string): Promise<string> {
    return fileIo.readText(path);
  }

  /**
   * 读取字节（F02 未用，占位待 F03+）。
   * @param path 文件绝对路径。
   * @returns 字节缓冲。
   */
  async readBytes(path: string): Promise<Uint8Array> {
    const content: ArrayBuffer = await fileIo.readText(path) as unknown as ArrayBuffer;
    return new Uint8Array(content);
  }

  /**
   * 递归枚举文件（F02 未用，占位待 F03+）。
   * @param root 目录绝对路径。
   * @returns 空数组（占位）。
   */
  listFilesRecursive(root: string): Promise<string[]> {
    return Promise.resolve([]);
  }
}

// ===========================================================================
// 页面
// ===========================================================================

/**
 * P-F02 导入选择页。
 */
@Component
export struct ImportSelectPage {
  /** 本页导航栈（onReady 经 NavDestinationContext 取得，用于跳转校验页）。 */
  private pathStack: NavPathStack | null = null;
  /** 选择页 ViewModel（onReady 惰性装配）。 */
  private vm: ImportSelectVM | null = null;
  /** 可观察状态快照（VM 监听器同步刷新）。 */
  @State vmState: ImportSelectState = { status: ImportSelectStatus.Idle, fileName: '', fileSize: 0 };
  /** 装配是否就绪（未就绪时禁用选择，避免空指针）。 */
  @State ready: boolean = false;

  /**
   * 惰性装配依赖：Database + 仓储 + 端口适配器 + ImportService + VM（无全局 DI 容器，不改注册文件）。
   * @returns 完成的 Promise。
   */
  private async setup(): Promise<void> {
    // 应用上下文（提供沙箱目录与 rawfile）
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    // 运行期临时目录（暂存父目录）
    const tempDir: string = context.tempDir;
    // 数据库（已完成迁移）
    const database: Database = await Database.open(context);
    // 导入任务仓储（状态机持久化边界）
    const jobRepo: ImportJobRepository = new ImportJobRepository(database);
    // 端口适配器（SDK 侧）
    const fs: FsImportFs = new FsImportFs();
    const uriPort: NoopUriPersist = new NoopUriPersist();
    // 生命周期编排器（cancel 委托其 cancel）
    const lifecycle: ImportLifecycle = new ImportLifecycle(jobRepo, fs, tempDir, uriPort);
    // 导入服务（create/cancel 编排）
    const importService: ImportService = new ImportService(
      jobRepo, lifecycle, new UuidIdFactory(), new FsSourceProbe(), new CryptoUriHasher(), uriPort);
    // 选择页 VM（注入探测端口 + 空间判定）
    const vm: ImportSelectVM = new ImportSelectVM(
      importService, new FsSourceProbe(), new StatvfsFreeSpaceProbe(tempDir), new StorageProbe());
    // 注册状态监听器，把 VM 状态同步到 @State
    vm.setListener((state: ImportSelectState): void => {
      this.vmState = state;
    });
    this.vm = vm;
    this.vmState = vm.getState();
    this.ready = true;
  }

  /**
   * 发起系统文件选择（`DocumentViewPicker`，限单文件、限 ZIP 扩展），把首个 URI 交给 VM 预检查。
   * @returns 完成的 Promise。
   */
  private async pickFile(): Promise<void> {
    // 装配未就绪/复制中：忽略（防重复点击）
    if (!this.ready || this.vm === null || this.vmState.status === ImportSelectStatus.Copying) {
      return;
    }
    try {
      // 文档选择器：限选 1 个、过滤 .zip（深度校验在 P-F03 内核）
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.studybook.zip', '.zip'];
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const uris: string[] = await documentPicker.select(options);
      // 用户取消或空选：保持当前态
      if (uris.length === 0) {
        return;
      }
      // 仅取首个（单文件约束）
      await this.vm.onFileSelected(uris[0]);
    } catch (cause) {
      // 选择器异常：切错误态（归一 AppError，不泄露 URI）
      this.vmState = {
        status: ImportSelectStatus.Idle,
        fileName: '',
        fileSize: 0,
        error: AppErrors.from(cause, DB_WRITE_FAILED)
      };
    }
  }

  /**
   * 「开始校验」：调用 VM 创建任务，成功得 jobId 后跳校验页。
   * @returns 完成的 Promise。
   */
  private async startValidation(): Promise<void> {
    if (this.vm === null || this.pathStack === null) {
      return;
    }
    // 创建任务（VM 内防重复点击）；取系统时钟作为 started_at
    const jobId: Id | undefined = await this.vm.startValidation(Date.now());
    if (jobId !== undefined) {
      // 跳校验页（携带 jobId；route_map 已注册 import/validate）
      const params: ImportValidateParams = { jobId };
      this.pathStack.pushPathByName(RouteName.IMPORT_VALIDATE, params);
    }
  }

  /**
   * 计算步骤指示器当前步序号（未选择=0，已选择/异常=1，复制中=2）。
   * @returns 当前步序号。
   */
  private currentStep(): number {
    // 已进入创建=校验步；已选择/类型错误/空间不足=预检查步；未选择=选择步
    if (this.vmState.status === ImportSelectStatus.Copying) {
      return ImportStep.Validate;
    }
    if (this.vmState.status === ImportSelectStatus.Idle) {
      return ImportStep.Pick;
    }
    return ImportStep.Precheck;
  }

  /**
   * 渲染当前状态下的内容主体（未选择 → 选择卡；其余 → 已选行 + 状态提示 + 主操作）。
   * @returns 无（@Builder 子树）。
   */
  @Builder
  contentBody() {
    if (this.vmState.status === ImportSelectStatus.Idle) {
      // 未选择：仅展示选择卡（含可能的上一次错误提示）
      FilePickerCard({ onPick: (): Promise<void> => this.pickFile(), disabled: !this.ready })
      if (this.vmState.error !== undefined) {
        this.errorHint(this.vmState.error)
      }
    } else {
      // 已选择/类型错误/空间不足/复制中：展示已选文件行
      SelectedFileRow({
        fileName: this.vmState.fileName,
        fileSize: this.vmState.fileSize,
        canReselect: this.vmState.status !== ImportSelectStatus.Copying,
        onReselect: (): Promise<void> => this.pickFile()
      })

      // 类型错误 / 空间不足：展示阻断提示，隐藏「开始校验」
      if (this.vmState.status === ImportSelectStatus.WrongType && this.vmState.error !== undefined) {
        this.errorHint(this.vmState.error)
      } else if (this.vmState.status === ImportSelectStatus.InsufficientSpace && this.vmState.error !== undefined) {
        this.errorHint(this.vmState.error)
      } else if (this.vmState.status === ImportSelectStatus.Selected) {
        // 已选择：展示「开始校验」主操作
        Button($r('app.string.import_start_button'))
          .width(220)
          .height(56)
          .fontSize(17)
          .backgroundColor('#C03B3B')
          .fontColor(Color.White)
          .margin({ top: 12 })
          .onClick((): Promise<void> => this.startValidation())
        // 创建失败（带 error）补充提示
        if (this.vmState.error !== undefined) {
          this.errorHint(this.vmState.error)
        }
      } else if (this.vmState.status === ImportSelectStatus.Copying) {
        // 复制中：进度提示 + 禁用态（按钮防重复点击）
        Row({ space: 8 }) {
          LoadingProgress().width(24).height(24).color('#C03B3B')
          Text($r('app.string.import_copying_hint')).fontSize(15).fontColor('#6B7075')
        }
        .margin({ top: 12 })
        .justifyContent(FlexAlign.Center)
      }
    }
  }

  /**
   * 渲染错误/警告提示行（取错误码对应资源键文案，琥珀/红按 UI 约束，文字+图标）。
   * @param error 领域错误。
   * @returns 无（@Builder 子树）。
   */
  @Builder
  errorHint(error: AppError) {
    Row({ space: 6 }) {
      // 状态标记（文字代替图标，避免新增图标资源）
      Text('!')
        .width(20)
        .height(20)
        .borderRadius(10)
        .textAlign(TextAlign.Center)
        .fontSize(13)
        .fontColor(Color.White)
        .backgroundColor(error.retryable ? '#E6A23C' : '#C03B3B')
      // 文案：按 messageKey 物理资源名解析（§3.14A 桥接）
      Text($r(`app.string.${AppErrors.physicalKeyFor(error.messageKey)}`))
        .fontSize(14)
        .fontColor(error.retryable ? '#B8860B' : '#C03B3B')
    }
    .margin({ top: 12 })
    .justifyContent(FlexAlign.Center)
  }

  build() {
    NavDestination() {
      Column({ space: 16 }) {
        // 步骤指示器
        ImportStepper({ current: this.currentStep() })
        // 状态化内容主体
        this.contentBody()
      }
      .width('100%')
      .height('100%')
      .padding({ left: 24, right: 24, top: 16, bottom: 24 })
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Start)
    }
    .title($r('app.string.route_title_import_select'))
    .onReady((ctx: NavDestinationContext): void => {
      // 取本页导航栈用于跳转
      this.pathStack = ctx.pathStack;
      // 惰性装配（失败时保持未就绪，禁用选择）
      this.setup().catch((): void => {
        this.ready = false;
      });
    })
  }
}
