import { BookSummary, BookListQuery } from '../domain/entities/content';
import { BooksRepository } from '../repositories/BooksRepository';
import { AppError } from '../domain/entities/common';
import { AppErrors, DB_QUERY_FAILED } from '../utils/AppErrors';

/** 书架页 UI 状态机四态（LLD §6.1「状态：空书架、正常、导入中、书籍损坏」+ 通用加载/错误）。 */
export type BookshelfState = 'loading' | 'content' | 'empty' | 'error';

/** 书架排序方式（与 `BookListQuery.sort` 同集合，便于 UI 段按钮绑定）。 */
export type BookshelfSort = BookListQuery['sort'];

/**
 * 书架 ViewModel（F01，LLD §6.1）。
 *
 * 职责：编排 `BooksRepository.list` 的异步取数，维护 `loading/content/empty/error` 状态机，
 * 暴露排序与关键字过滤，并在并发刷新时以「世代号」丢弃过期回包（避免旧请求覆盖新结果）。
 * 不直接执行 SQL（CLAUDE.md §5），仅依赖 `BooksRepository`。
 *
 * 取消语义：HarmonyOS Promise 无原生 abort，这里以 `loadGeneration` 世代号实现「逻辑取消」——
 * 关键字/排序变更会自增世代号，过期回包据此被丢弃，满足「所有异步有 loading/success/error/取消状态」。
 */
@Observed
export class BookshelfVM {
  /** 当前 UI 状态（驱动页面四态切换）。 */
  state: BookshelfState = 'loading';
  /** 当前书架书籍列表（content 态下渲染）。 */
  books: BookSummary[] = [];
  /** 当前错误（error 态下用 `messageKey` 取文案展示），无错误时为 undefined。 */
  error?: AppError;
  /** 当前排序方式（默认最近打开）。 */
  sort: BookshelfSort = 'last-opened';
  /** 当前关键字过滤（去空白后参与查询；空串表示不过滤）。 */
  keyword: string = '';
  /** 是否包含损坏书（默认 true：书架需展示「书籍损坏」态以便用户处理，LLD §6.1）。 */
  includeBroken: boolean = true;

  /** 数据仓储（构造注入，便于测试替身）。 */
  private readonly repo: BooksRepository;
  /** 加载世代号：每次刷新自增，过期回包据此丢弃（逻辑取消）。 */
  private loadGeneration: number = 0;

  /**
   * 构造书架 ViewModel。
   * @param repo 书籍仓储（已就绪）。
   */
  constructor(repo: BooksRepository) {
    this.repo = repo;
  }

  /**
   * 首次加载（进入书架页时调用）。等价于以当前排序/关键字执行一次刷新。
   * @returns 加载完成的 Promise（状态已落到 content/empty/error）。
   */
  async load(): Promise<void> {
    await this.refresh();
  }

  /**
   * 按当前 `sort`/`keyword`/`includeBroken` 刷新书架列表，并维护状态机。
   *
   * 进入即置 `loading`；成功后按结果空否落 `content`/`empty`；失败落 `error` 并保留可重试的领域错误。
   * 以世代号丢弃过期回包：刷新前自增世代号，回包时若世代号已变更则直接返回（逻辑取消）。
   * @returns 刷新完成的 Promise。
   */
  async refresh(): Promise<void> {
    // 本次刷新的世代号（回包时据此判断是否已被更新请求取代）
    const generation: number = ++this.loadGeneration;
    // 进入加载态，清空上一轮错误
    this.state = 'loading';
    this.error = undefined;
    // 组装查询参数（关键字去空白后非空才下传）
    const trimmedKeyword: string = this.keyword.trim();
    const query: BookListQuery = {
      sort: this.sort,
      includeBroken: this.includeBroken
    };
    if (trimmedKeyword.length > 0) {
      query.keyword = trimmedKeyword;
    }
    try {
      // 仓储返回的书籍摘要列表
      const result: BookSummary[] = await this.repo.list(query);
      if (generation !== this.loadGeneration) {
        // 已有更新的刷新请求发出，丢弃本次过期回包（逻辑取消）
        return;
      }
      this.books = result;
      // 空结果区分「无书」与「有书」：空列表落 empty 态展示空书架引导
      this.state = result.length > 0 ? 'content' : 'empty';
    } catch (cause) {
      if (generation !== this.loadGeneration) {
        // 过期回包的异常同样丢弃，不污染当前状态
        return;
      }
      // 归一为领域错误并落 error 态（不抛裸字符串，04 §1）
      this.error = AppErrors.from(cause, DB_QUERY_FAILED);
      this.books = [];
      this.state = 'error';
    }
  }

  /**
   * 切换排序方式并刷新（与当前值相同则不重复请求）。
   * @param sort 目标排序方式。
   * @returns 刷新完成的 Promise（无变化时立即 resolve）。
   */
  async changeSort(sort: BookshelfSort): Promise<void> {
    if (this.sort === sort) {
      // 排序未变，避免无谓刷新
      return;
    }
    this.sort = sort;
    await this.refresh();
  }

  /**
   * 设置关键字并刷新（去空白后与当前值相同则不重复请求）。
   * @param keyword 新关键字（可含首尾空白，内部去空白比较）。
   * @returns 刷新完成的 Promise（无变化时立即 resolve）。
   */
  async setKeyword(keyword: string): Promise<void> {
    // 归一后的新关键字
    const next: string = keyword.trim();
    if (next === this.keyword.trim()) {
      // 关键字实质未变，避免抖动刷新
      return;
    }
    this.keyword = keyword;
    await this.refresh();
  }

  /**
   * 重试（error 态下「重试」按钮触发）：以当前参数重新刷新。
   * @returns 刷新完成的 Promise。
   */
  async retry(): Promise<void> {
    await this.refresh();
  }

  /**
   * 是否存在损坏书（content 态下用于决定是否展示「部分书籍损坏」横幅，LLD §6.1）。
   * @returns 列表中存在 status='broken' 的书时为 true。
   */
  hasBrokenBook(): boolean {
    // 任一书状态为 broken 即返回 true
    return this.books.some((book: BookSummary): boolean => book.status === 'broken');
  }
}
