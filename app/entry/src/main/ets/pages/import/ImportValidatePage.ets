/**
 * P-F03 导入校验页（LLD §6.3，路由 `import/validate`）。
 *
 * 「runValidation 进度流 → 用户确认 → commit 落库」垂直切片的 UI 终点：
 * 组合 `ImportStepper` / `ValidationSummary` / `ValidationStageGrid` / `ReportDialog`，
 * 由 `ImportValidateVM` 驱动有限状态（校验中/可导入/警告/失败/导入中/完成，LLD §6.3「状态」列）。
 *
 * 页面约束（§6.3）：
 * - 进度只前进不回退（由 VM 保证 `state.progress` 单调不减）；
 * - 阻断错误隐藏「确认导入」按钮（`vm.canConfirm() === false`）；
 * - 导入中态（commit 进行中）屏蔽「取消」（`vm.isCancellable() === false`）；
 * - 完成态展示「完成」按钮，跳回书架（popToName(RouteName.BOOKSHELF)）；
 * - 来源 URI 仅在内存传递（NavPathStack param），不入日志/快照（CLAUDE.md §5）。
 *
 * 装配：`onReady` 经 `getContext` 惰性装配全套 F03 生产依赖（Database / 仓储 / 端口适配器 / ImportService /
 * ImportValidateVM），无全局 DI，不改注册文件。
 *
 * 未编译验证（缺 HarmonyOS SDK）：`@ohos.file.fs` / `@ohos.zlib` / `@kit.CryptoArchitectureKit` /
 * resourceManager rawfile / ArkUI 组件以 API 12 为准；本页 UI 与适配器尚未真机/SDK 编译验证。
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer, util } from '@kit.ArkTS';
import { AppError } from '../../domain/entities/common';
import { AppErrors, DB_WRITE_FAILED } from '../../utils/AppErrors';
import { RouteName, ImportValidateParams } from '../../utils/Routes';
import { Database } from '../../database/Database';
import { ImportJobRepository } from '../../repositories/ImportJobRepository';
import { BookContentRepository } from '../../repositories/BookContentRepository';
import { UuidIdFactory } from '../../utils/UuidIdFactory';
import { ImportFs } from '../../services/import/ImportStaging';
import { ImportLifecycle, UriPermissionPort } from '../../services/import/ImportLifecycle';
import { ImportService, SourceBytesReader, ZipExtractor, ImportValidationDeps } from '../../services/ImportService';
import { HashComputer } from '../../services/import/ChecksumVerifier';
import { SchemaProvider, BUILTIN_SCHEMA_RAWFILE, StudybookSchemaKind } from '../../services/import/StudybookSchemaCatalog';
import { JsonValue } from '../../services/import/JsonSchemaValidator';
import { SourceProbePort, SourceFileMeta } from '../../services/StorageProbe';
import { UriHasher, UriPersistPort } from '../../services/ImportService';
import {
  ImportValidateVM,
  ImportValidateState,
  ImportValidateStatus,
  VALIDATION_STAGES,
  StageMark
} from '../../viewmodels/ImportValidateVM';
import { ImportStepper, ImportStep } from '../../components/import/ImportStepper';
import { ValidationSummary } from '../../components/import/ValidationSummary';
import { ValidationStageGrid, StageItem } from '../../components/import/ValidationStageGrid';
import { ReportDialog, ValidationReport } from '../../components/import/ReportDialog';

// ===========================================================================
// 端口生产适配器（F03 独占；依赖 HarmonyOS SDK，未编译验证）
// ===========================================================================

/** 阶段标题资源键：与 `VALIDATION_STAGES` 等长同序。 */
const STAGE_TITLE_KEYS: string[] = [
  'validate_stage_zip',
  'validate_stage_manifest',
  'validate_stage_extract',
  'validate_stage_hash',
  'validate_stage_schema',
  'validate_stage_business'
];

/**
 * 来源文件探测适配器（F03 复用 F02 同类；此处仅用于 ImportService.create 之外的哈希端口）。
 */
class FsSourceProbeF03 implements SourceProbePort {
  async probeSource(sourceUri: string): Promise<SourceFileMeta> {
    const noQuery: string = sourceUri.split('?')[0];
    const segments: string[] = noQuery.split('/');
    const displayName: string = segments[segments.length - 1] || 'unknown.zip';
    try {
      const file: fileIo.File = await fileIo.open(sourceUri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = await fileIo.stat(file.fd);
      await fileIo.close(file);
      return { displayName: displayName, sizeBytes: stat.size };
    } catch (cause) {
      return { displayName: displayName, sizeBytes: -1 };
    }
  }
}

/**
 * URI 哈希适配器（SHA-256，同 F02 CryptoUriHasher 口径，此处不落库，仅满足 create 签名）。
 */
class CryptoUriHasherF03 implements UriHasher {
  async hashUri(sourceUri: string): Promise<string> {
    const bytes: Uint8Array = new Uint8Array(buffer.from(sourceUri, 'utf-8').buffer);
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    await md.update({ data: bytes });
    const digest: cryptoFramework.DataBlob = await md.digest();
    return Array.from(digest.data).map((b: number): string => b.toString(16).padStart(2, '0')).join('');
  }
}

/**
 * URI 持久化授权适配器（F03 不需要：F03 阶段来源 URI 已由 F02 持久化授权；本端口仅满足签名）。
 */
class NoopUriPersistF03 implements UriPersistPort {
  persist(_sourceUri: string): Promise<void> {
    return Promise.resolve();
  }
}

/** URI 授权释放端口（F03 页面关闭时不主动释放；释放由 lifecycle.abandon 负责）。 */
class NoopUriReleaseF03 implements UriPermissionPort {
  persist(_sourceUri: string): Promise<void> { return Promise.resolve(); }
  release(_sourceUriHash: string): Promise<void> { return Promise.resolve(); }
}

/**
 * 文件系统 ImportFs 适配器（F03 用；同 F02 FsImportFs 口径）。
 */
class FsImportFsF03 implements ImportFs {
  mkdirs(path: string): Promise<void> {
    return fileIo.mkdir(path, true);
  }
  exists(path: string): Promise<boolean> {
    return fileIo.access(path);
  }
  async remove(path: string): Promise<void> {
    // 不存在直接成功（幂等清理）
    if (!(await fileIo.access(path))) {
      return;
    }
    // 目录递归删除，文件 unlink（ImportFs.remove 语义：递归删、不存在视为成功）
    const stat: fileIo.Stat = await fileIo.stat(path);
    if (stat.isDirectory()) {
      await fileIo.rmdir(path);
    } else {
      await fileIo.unlink(path);
    }
  }
  move(from: string, to: string): Promise<void> {
    return fileIo.moveFile(from, to);
  }
  readText(path: string): Promise<string> {
    return fileIo.readText(path);
  }
  async readBytes(path: string): Promise<Uint8Array> {
    const file: fileIo.File = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
    const stat: fileIo.Stat = await fileIo.stat(file.fd);
    const ab: ArrayBuffer = new ArrayBuffer(stat.size);
    await fileIo.read(file.fd, ab);
    await fileIo.close(file);
    return new Uint8Array(ab);
  }
  async listFilesRecursive(root: string): Promise<string[]> {
    const result: string[] = [];
    const collect = async (dir: string, prefix: string): Promise<void> => {
      // 当前层条目名（fileIo.listFile 返回名称数组，非递归）
      const names: string[] = await fileIo.listFile(dir);
      for (const name of names) {
        const abs: string = `${dir}/${name}`;
        const rel: string = prefix.length > 0 ? `${prefix}/${name}` : name;
        // 按 stat 判定类型：目录下钻，文件收集相对路径
        const stat: fileIo.Stat = await fileIo.stat(abs);
        if (stat.isDirectory()) {
          await collect(abs, rel);
        } else {
          result.push(rel);
        }
      }
    };
    await collect(root, '');
    return result;
  }
}

/**
 * 来源字节读取适配器：读取来源 URI 的完整 ZIP 字节（`@ohos.file.fs` `read`）。
 */
class FsSourceBytesReader implements SourceBytesReader {
  async readSourceBytes(sourceUri: string): Promise<Uint8Array> {
    try {
      const file: fileIo.File = await fileIo.open(sourceUri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = await fileIo.stat(file.fd);
      const ab: ArrayBuffer = new ArrayBuffer(stat.size);
      await fileIo.read(file.fd, ab);
      await fileIo.close(file);
      return new Uint8Array(ab);
    } catch (cause) {
      throw AppErrors.from(cause, 'IMP-017');
    }
  }
}

/**
 * ZIP 解压适配器：把来源 ZIP 解压到暂存根目录（`@ohos.zlib`）。
 */
class OhosZipExtractor implements ZipExtractor {
  async extractTo(sourceUri: string, stagingRoot: string): Promise<string[]> {
    try {
      const options: zlib.Options = { level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION };
      await zlib.decompressFile(sourceUri, stagingRoot, options);
      const fs: FsImportFsF03 = new FsImportFsF03();
      return fs.listFilesRecursive(stagingRoot);
    } catch (cause) {
      throw AppErrors.from(cause, 'IMP-018');
    }
  }
}

/**
 * SHA-256 哈希计算适配器（`@kit.CryptoArchitectureKit`）。
 */
class CryptoHashComputer implements HashComputer {
  async sha256(data: Uint8Array): Promise<string> {
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    await md.update({ data: data });
    const digest: cryptoFramework.DataBlob = await md.digest();
    return Array.from(digest.data).map((b: number): string => b.toString(16).padStart(2, '0')).join('');
  }
}

/**
 * 内置 Schema 来源适配器（从 `resources/rawfile/schemas/` 读取应用内置可信副本；BR-002）。
 */
class RawfileSchemaProvider implements SchemaProvider {
  /** 种类 → 已解析内置 Schema 映射（由静态 load 预读 rawfile 后构造；SchemaProvider.get 为同步契约）。 */
  private readonly schemas: Record<string, JsonValue>;

  /**
   * @param schemas 预读的「种类 → 已解析 Schema」映射。
   */
  constructor(schemas: Record<string, JsonValue>) {
    this.schemas = schemas;
  }

  /**
   * 取指定种类的内置 Schema（同步，满足 `SchemaProvider` 契约）。
   * @param kind Schema 种类。
   * @returns 已解析 Schema；缺失返回 undefined。
   */
  get(kind: StudybookSchemaKind): JsonValue | undefined {
    return Object.keys(this.schemas).indexOf(kind) >= 0 ? this.schemas[kind] : undefined;
  }

  /**
   * 从 `resources/rawfile/schemas/` 预读五个应用内置可信 Schema 副本，构造 Provider（BR-002，绝不读包内 schemas/）。
   * @param context 应用上下文（提供 resourceManager）。
   * @returns 已就绪的内置 Schema Provider。
   */
  static async load(context: common.Context): Promise<RawfileSchemaProvider> {
    // 种类 → 已解析 Schema
    const map: Record<string, JsonValue> = {};
    // UTF-8 解码器
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    // 五种内置 Schema 种类
    const kinds: StudybookSchemaKind[] = ['manifest', 'book', 'chapter', 'report', 'checksums'];
    for (const kind of kinds) {
      // rawfile 相对路径（schemas/<kind>.schema.json）
      const rawPath: string = BUILTIN_SCHEMA_RAWFILE[kind];
      const bytes: Uint8Array = await context.resourceManager.getRawFileContent(rawPath);
      const text: string = decoder.decodeWithStream(bytes, { stream: false });
      map[kind] = JSON.parse(text) as JsonValue;
    }
    return new RawfileSchemaProvider(map);
  }
}

// ===========================================================================
// 页面
// ===========================================================================

/**
 * P-F03 校验页路由构建函数（route_map.json → `import/validate`，LLD §6.3）。
 * @returns 无（构建 NavDestination）
 */
@Builder
export function ImportValidatePageBuilder(): void {
  ImportValidatePage();
}

/**
 * P-F03 校验页。
 */
@Component
export struct ImportValidatePage {
  /** 导航栈（完成时 popToName 书架）。 */
  private pathStack?: NavPathStack = undefined;
  /** 校验页 ViewModel（onReady 装配后有值）。 */
  private vm?: ImportValidateVM = undefined;
  /** 可观察状态快照（VM 监听器同步刷新）。 */
  @State vmState: ImportValidateState = ImportValidatePage.emptyState();
  /** 报告弹窗控制器（「查看报告」触发）。 */
  private reportDialogCtrl: CustomDialogController = new CustomDialogController({
    builder: ReportDialog({
      report: ImportValidatePage.buildReport(ImportValidatePage.emptyState(), STAGE_TITLE_KEYS),
      onClose: () => {}
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center
  });

  /**
   * 构造「校验中」初始空状态（全 pending、进度 0）。
   * @returns 初始状态快照。
   */
  private static emptyState(): ImportValidateState {
    const marks: StageMark[] = VALIDATION_STAGES.map(
      (_s: string) => 'pending' as StageMark);
    return {
      status: ImportValidateStatus.Validating,
      progress: 0,
      stageMarks: marks,
      activeStageIndex: -1,
      warningCount: 0,
      checkedFiles: 0
    };
  }

  /**
   * 把 VM 状态快照 + 阶段标题键转换为 StageItem 数组（供 ValidationStageGrid / ReportDialog）。
   * @param state VM 状态快照。
   * @param titleKeys 阶段标题资源名数组（与 VALIDATION_STAGES 等长同序）。
   * @returns StageItem 数组。
   */
  private static buildStages(state: ImportValidateState, titleKeys: string[]): StageItem[] {
    return VALIDATION_STAGES.map((_, i: number): StageItem => ({
      titleKey: titleKeys[i] ?? 'validate_stage_zip',
      mark: state.stageMarks[i] ?? 'pending'
    }));
  }

  /**
   * 构造报告数据（供 ReportDialog）。
   * @param state VM 状态快照。
   * @param titleKeys 阶段标题资源名数组。
   * @returns 报告数据。
   */
  private static buildReport(state: ImportValidateState, titleKeys: string[]): ValidationReport {
    return {
      stages: ImportValidatePage.buildStages(state, titleKeys),
      checkedFiles: state.checkedFiles,
      totalFiles: state.totalFiles !== undefined ? state.totalFiles : -1,
      warningCount: state.warningCount,
      errorMessageName: state.error !== undefined ? AppErrors.physicalKeyFor(state.error.messageKey) : ''
    };
  }

  /**
   * 惰性装配 F03 全套依赖并启动校验：Database → 仓储 → 端口适配器 → ImportService → VM → vm.start()。
   * @param params 路由参数（jobId + sourceUri）。
   * @param pathStack 导航栈。
   * @returns 完成的 Promise（装配失败切错误态，vm.start() 在后台执行）。
   */
  private async setup(params: ImportValidateParams, pathStack: NavPathStack): Promise<void> {
    this.pathStack = pathStack;
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const tempDir: string = context.tempDir;
      const filesDir: string = context.filesDir;
      const database: Database = await Database.open(context);
      const jobRepo: ImportJobRepository = new ImportJobRepository(database);
      const contentRepo: BookContentRepository = new BookContentRepository(database);
      const fsAdapter: FsImportFsF03 = new FsImportFsF03();
      const uriPort: NoopUriReleaseF03 = new NoopUriReleaseF03();
      const lifecycle: ImportLifecycle = new ImportLifecycle(jobRepo, fsAdapter, tempDir, uriPort);
      const deps: ImportValidationDeps = {
        fs: fsAdapter,
        hasher: new CryptoHashComputer(),
        schemas: await RawfileSchemaProvider.load(context),
        contentRepo: contentRepo,
        sourceBytes: new FsSourceBytesReader(),
        extractor: new OhosZipExtractor(),
        tempDir: tempDir,
        filesDir: filesDir
      };
      const importService: ImportService = new ImportService(
        jobRepo, lifecycle, new UuidIdFactory(),
        new FsSourceProbeF03(), new CryptoUriHasherF03(), new NoopUriPersistF03(), deps);
      // 把来源 URI 绑定到 jobId（runValidation 读取字节时使用；不入日志）
      importService.bindSourceUri(params.jobId, params.sourceUri);
      const vm: ImportValidateVM = new ImportValidateVM(importService, params.jobId);
      vm.setListener((state: ImportValidateState): void => {
        this.vmState = state;
      });
      this.vm = vm;
      this.vmState = vm.getState();
      // 后台启动校验（异步；状态通过监听器驱动 @State 刷新）
      vm.start().catch((cause: Object): void => {
        void AppErrors.from(cause, DB_WRITE_FAILED);
      });
    } catch (cause) {
      const err: AppError = AppErrors.from(cause, DB_WRITE_FAILED);
      this.vmState = {
        status: ImportValidateStatus.Failed,
        progress: 0,
        stageMarks: VALIDATION_STAGES.map((_: string) => 'pending' as StageMark),
        activeStageIndex: -1,
        warningCount: 0,
        checkedFiles: 0,
        error: err
      };
    }
  }

  /**
   * 点击「确认导入」。
   */
  private async onConfirm(): Promise<void> {
    if (this.vm === undefined) {
      return;
    }
    await this.vm.confirm();
  }

  /**
   * 点击「取消」。
   */
  private async onCancel(): Promise<void> {
    if (this.vm === undefined) {
      return;
    }
    await this.vm.cancel();
    // 取消成功：弹出校验页，返回选择页
    if (this.pathStack !== undefined && this.vmState.status !== ImportValidateStatus.Validating) {
      this.pathStack.pop();
    }
  }

  /**
   * 点击「完成」：弹出至书架根页面。
   */
  private onDone(): void {
    if (this.pathStack !== undefined) {
      this.pathStack.popToName(RouteName.BOOKSHELF);
    }
  }

  /**
   * 取当前状态下「确认导入」按钮的错误消息物理键（供 ValidationSummary.errorMessageName）。
   * @returns 物理键串（空串=无错误）。
   */
  private errorMessageName(): string {
    if (this.vmState.error === undefined) {
      return '';
    }
    return AppErrors.physicalKeyFor(this.vmState.error.messageKey);
  }

  /**
   * 打开报告弹窗（「查看报告」按钮触发）。
   */
  private openReport(): void {
    this.reportDialogCtrl = new CustomDialogController({
      builder: ReportDialog({
        report: ImportValidatePage.buildReport(this.vmState, STAGE_TITLE_KEYS),
        onClose: () => {}
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: true
    });
    this.reportDialogCtrl.open();
  }

  /**
   * 操作按钮区（按状态分发：取消/查看报告/确认导入/完成）。
   */
  @Builder
  actionButtons() {
    Row({ space: 12 }) {
      // 取消（校验中/失败/可导入/警告态可取消；导入中/完成态隐藏）
      if (this.vm !== undefined && this.vm.isCancellable()) {
        Button($r('app.string.import_validate_cancel'))
          .height(48)
          .fontSize(16)
          .backgroundColor('#F2F3F5')
          .fontColor('#1F2329')
          .layoutWeight(1)
          .onClick((): Promise<void> => this.onCancel())
      }
      // 查看报告（可导入/警告/失败态可查看）
      if (this.vmState.status === ImportValidateStatus.Importable
        || this.vmState.status === ImportValidateStatus.Warning
        || this.vmState.status === ImportValidateStatus.Failed) {
        Button($r('app.string.import_validate_view_report'))
          .height(48)
          .fontSize(16)
          .backgroundColor('#E8EAED')
          .fontColor('#1F2329')
          .layoutWeight(1)
          .onClick(() => { this.openReport(); })
      }
      // 确认导入（可导入/警告态，阻断错误隐藏；§6.3 页面约束）
      if (this.vm !== undefined && this.vm.canConfirm()) {
        Button($r('app.string.import_validate_confirm'))
          .height(48)
          .fontSize(16)
          .backgroundColor('#C03B3B')
          .fontColor(Color.White)
          .layoutWeight(1)
          .onClick((): Promise<void> => this.onConfirm())
      }
      // 导入中：禁用占位（防重复点击）
      if (this.vmState.status === ImportValidateStatus.Importing) {
        Row({ space: 8 }) {
          LoadingProgress().width(24).height(24).color('#C03B3B')
          Text($r('app.string.state_loading'))
            .fontSize(15)
            .fontColor('#6B7075')
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
      // 完成：跳回书架
      if (this.vmState.status === ImportValidateStatus.Completed) {
        Button($r('app.string.import_validate_done'))
          .height(48)
          .fontSize(16)
          .backgroundColor('#2BA471')
          .fontColor(Color.White)
          .layoutWeight(1)
          .onClick(() => { this.onDone(); })
      }
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 16, bottom: 16 })
  }

  build() {
    NavDestination() {
      Column() {
        // 步骤指示器（第 3 步：开始校验）
        ImportStepper({ current: ImportStep.Validate })
          .padding({ left: 24, right: 24, top: 16, bottom: 8 })

        // 主内容区（可滚动：校验阶段多时不遮操作区）
        Scroll() {
          Column({ space: 16 }) {
            // 状态摘要（进度条 + 状态文案 + 文件计数 + 警告/错误提示）
            ValidationSummary({
              status: this.vmState.status,
              progress: this.vmState.progress,
              warningCount: this.vmState.warningCount,
              checkedFiles: this.vmState.checkedFiles,
              totalFiles: this.vmState.totalFiles !== undefined ? this.vmState.totalFiles : -1,
              errorMessageName: this.errorMessageName(),
              errorRetryable: this.vmState.error !== undefined && (this.vmState.error.retryable === true)
            })

            // 阶段网格（六校验阶段进度标记；进度只前进不回退，§6.3）
            ValidationStageGrid({
              stages: ImportValidatePage.buildStages(this.vmState, STAGE_TITLE_KEYS)
            })
          }
          .width('100%')
          .padding({ left: 24, right: 24 })
        }
        .layoutWeight(1)
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)

        // 操作按钮区（固定在底部）
        this.actionButtons()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.White)
    }
    .title($r('app.string.route_title_import_validate'))
    .onReady((ctx: NavDestinationContext) => {
      const params: ImportValidateParams = ctx.pathInfo.param as ImportValidateParams;
      this.setup(params, ctx.pathStack);
    })
  }
}
