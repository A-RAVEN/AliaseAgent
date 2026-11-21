// 全局技能目录的发现、校验汇总与注入文本（change `add-skill-mechanism`
// 任务 2.1 / 2.2 / 3.2）。
//
// 职责边界（design D1 / D8）：
//   - 扫描 `<主目录>/.aliasagent/skills/`（主目录解析与 `config_service.dart` 的
//     `configDir` 同源，也就是 C++ 侧 `spill.cpp` 的 `home_dir()` 那一份）里每个
//     **真实子目录**的 `SKILL.md`，按 `skill_frontmatter.dart` 的规范六字段校验；
//   - 生效集合与失败清单都留在本进程的单例里：Agent 每轮装配（含子 Agent，走同一个
//     `AgentFactory.create` 路径）读的就是这一份，没有第二份副本；
//   - 失败原因**汇总成一行一句话**给界面提示用（`failureNotice`），同时逐条进日志 —
//     不静默跳过（规范「SKILL.md 元数据校验」）。
//
// 扫描时机（change `refresh-skill-catalog-each-turn` design D1/D2）：启动一次 + **每轮
// 请求装配前增量刷新**。每次只比对目录清单与每个 `SKILL.md` 的 `(mtime, size)` 指纹，
// 只有新增 / 指纹变化 / 消失的条目才重读全文并重新校验；指纹未变的条目（含校验失败的
// 条目）直接复用上轮缓存，不重读、不重新解析、不重新校验。因此技能内容的变更**下一条
// 消息即生效**（无需重启），而同一轮请求内视图一致：装配之后、本轮工具循环中途的文件
// 改动要到下一轮装配才反映。
//
// 已知检测盲区（design D1，如实登记，不是缺陷）：**同修改时间且同大小的覆盖写**不会被
// 增量探测发现 —— 与产品既有 `edit_file` 版本检查同款限制，已写进
// `Docs/user-guide/skills.md` 的已知限制节。实测补充：Windows 上 Dart 的
// `FileStat.modified` 只有**整秒**精度（同一秒内两次写盘得到的 mtime 完全相同），
// 所以"同修改时间"在 Windows 上实际等价于"同一秒内 + 同大小"；人工编辑（两次保存
// 相隔远大于一秒）不受影响。
library;

import 'dart:io';

import 'package:meta/meta.dart';

import '../config_service.dart';
import '../logging.dart';
import 'skill_frontmatter.dart';

/// `load_skill` 的工具名（不进 `ToolCatalog.kBaseToolNames`，见 design D9）。
const String kLoadSkillToolName = 'load_skill';

/// `load_skill` 的工具定义（任务 3.2：常量住技能服务侧，`lib/main.dart` 的 base 表
/// 注册同一份；每轮装配再由 `Agent.toolDefinitions` 追加，保证模板没有列它也照常交付）。
const Map<String, dynamic> kLoadSkillToolDefinition = {
  // 这里写字符串字面量（而不是 `kLoadSkillToolName`）：用户文档一致性守卫
  // （`test/unit/user_docs_test.dart`）从工具定义源码里抽工具名那一行的字符串来核对
  // "文档提到的工具名在代码里真实存在"，常量引用会让它抽不到。两个值必须相等，
  // 由 `test/unit/skill_catalog_service_test.dart` 的一条断言钉住。
  'name': 'load_skill',
  'description': 'Load a skill: its instructions, or one file inside the skill '
      'directory. Call this BEFORE following a skill listed in the system '
      'prompt. Without `file` it returns the SKILL.md instructions of that '
      'skill (frontmatter removed). With `file` it returns the full text of '
      'that file, whose path is relative to the skill directory '
      '(for example "references/REFERENCE.md"). Paths that leave the skill '
      'directory are rejected. Long content is spilled to disk: the reply '
      'shows a head/tail preview plus the omitted byte count, and the middle '
      'can be read back with read_spill.',
  'input_schema': {
    'type': 'object',
    'properties': {
      'skill': {
        'type': 'string',
        'description': 'Skill name, exactly as listed in the system prompt '
            '(lowercase letters, digits and single hyphens).',
      },
      'file': {
        'type': 'string',
        'description': 'Optional path of a file inside the skill directory, '
            'relative to it (for example "references/REFERENCE.md"). Omit it '
            'to load the SKILL.md instructions.',
      },
    },
    'required': ['skill'],
  },
};

// ---------------------------------------------------------------------------
// 创建技能简则（change `refresh-skill-catalog-each-turn` 返工 5.1，design D6）
//
// 为什么住在服务侧、搭 `promptSection` 这条通道（D6 的候选位置比对结论）：
//   - `promptSection` 每轮请求都进系统提示词 —— 模型被要求"帮我写个技能"时就有格式
//     依据（API 无状态，没有"只发一次"的系统提示词机制，成本是固定一小段）；
//   - `load_skill` 的工具描述讲的是"怎么用工具"，写技能是另一件事，塞进去会污染语义；
//   - 独立文档要模型自己去读，而模型不会无故读文件，正好 defeat 需求目的。
//
// 语言与 "Available skills…" 段一致（英文）。**每条规则的出处写在各自常量上方**；
// 与 `skill_frontmatter.dart` 的校验规则不一致即缺陷（design D6），所以三个长度上限
// 直接引用那边的常量插值，不手抄数字（`test/unit/skill_catalog_service_test.dart`
// 用双向断言钉住）。
// ---------------------------------------------------------------------------

/// 简则标题行。
///
/// **不许**出现 "Available skills" 字样：没有生效技能时它就是 `promptSection` 的第一
/// 行，而有技能时第一行必须是 "Available skills" 标题 —— 两者不能混（规范「没有技能
/// 也给出写作简则」要求无技能时不含标题与清单行，但简则要在）。
const String _kSkillGuideHeading =
    'Skill authoring guide (how to create a new skill):';

/// 简则第 1 条：技能目录位置 + 「目录名即技能名」。
///
/// **出处**：目录 `<主目录>/.aliasagent/skills/` = 本文件的 [SkillCatalogService.defaultRootPath]
/// （与 `Docs/AgentSkillsDoc.md` 第一节目录树里的 `~/.claude/skills` 同构，本产品把
/// `.claude` 换成 `.aliasagent`）；「名字必须与目录名一致」= `skill_frontmatter.dart`
/// 的 `validateSkillMd`（`rawName != directoryName` 判失败）。
const String _kSkillGuideDirectory =
    '1) Directory: create <home>/.aliasagent/skills/<skill-name>/ and put a SKILL.md '
    'inside it. The directory name IS the skill name, so it must equal the '
    'frontmatter name.';

/// 简则第 2 条：`SKILL.md` 的 frontmatter 结构。
///
/// **出处**：`skill_frontmatter.dart` 的 `splitSkillMd` 与
/// [kSkillFrontmatterDelimiter]（首行恰为独立成行的 `---`，切到下一个独立 `---` 行，
/// 之后全是正文）；`Docs/AgentSkillsDoc.md` 第一节的 frontmatter 示例。
const String _kSkillGuideShape =
    '2) SKILL.md: a frontmatter block delimited by two lines that each hold exactly '
    '---, then the Markdown instructions.';

/// 简则第 3 条：frontmatter 字段与三个长度上限。
///
/// **出处**：`skill_frontmatter.dart` 的 [kSkillNameMaxChars] /
/// [kSkillDescriptionMaxChars] / [kSkillCompatibilityMaxChars] 与 `validateSkillMd`
/// （`name` / `description` 必填；`compatibility` 可选，但提供了就要 1–500）；
/// `Docs/AgentSkillsDoc.md` 第一节字段表（"1–64" / "1–1024" / "若提供则 1–500"）。
/// 三个数字用常量插值 —— 手抄数字会与校验悄悄漂移（design D6：不一致即缺陷）。
const String _kSkillGuideFields =
    '3) Frontmatter fields: name (required, 1-$kSkillNameMaxChars chars, lowercase '
    'letters and digits separated by single hyphens, no leading or trailing '
    'hyphen, no double hyphen, must equal the directory name); description '
    '(required, 1-$kSkillDescriptionMaxChars chars, non-empty, what it does and '
    'when to use it); compatibility (optional, 1-$kSkillCompatibilityMaxChars '
    'chars when present).';

/// 简则第 4 条：附属子目录约定 + 按相对路径读附属文件。
///
/// **出处**：`Docs/AgentSkillsDoc.md` 第一节目录树与「可选目录约定」
/// （`scripts/` / `references/` / `assets/`）；读取方式 = [kLoadSkillToolDefinition]
/// 里 `file` 参数的口径（相对技能目录的路径）。
const String _kSkillGuideSubdirs =
    '4) Optional subdirectories: references/ for documents, scripts/ for code, '
    'assets/ for templates and data; load_skill reads a file by a path relative '
    'to the skill directory.';

/// 简则第 5 条：写好之后什么时候生效。
///
/// **出处**：本 change 的 `specs/skills/spec.md`「生效时机」与 design D2（每轮装配前
/// 增量刷新 ⇒ 下一条消息即生效，无需重启）；`Docs/user-guide/skills.md` 同口径。
const String _kSkillGuideTiming =
    '5) A skill you write takes effect on your next message; no restart is needed.';

/// 简则第 6 条：校验失败时用户与模型都能看到原因。
///
/// **出处**：`skill_frontmatter.dart` 的 `SkillValidation.failure`（原因含具体数值）
/// 经本文件的 [SkillLoadFailure.line] 汇总成界面提示（`failureNotice`），不静默跳过。
const String _kSkillGuideFailure =
    '6) If a skill fails validation the app shows the reason on screen; fix the '
    'file and it takes effect on the next message.';

/// 注入系统提示词的**创建技能简则**：六条规则按固定顺序、每条一行。
///
/// 有生效技能时它接在目录清单之后；没有生效技能时它就是 `promptSection` 整段
/// （见 [SkillCatalogService.promptSection]）。静态文本，不随对话增长。
const String kSkillAuthoringGuide = '$_kSkillGuideHeading\n'
    '$_kSkillGuideDirectory\n'
    '$_kSkillGuideShape\n'
    '$_kSkillGuideFields\n'
    '$_kSkillGuideSubdirs\n'
    '$_kSkillGuideTiming\n'
    '$_kSkillGuideFailure';

/// 一个未生效的技能：目录名、校验失败原因、给界面看的整行提示。
class SkillLoadFailure {
  const SkillLoadFailure({
    required this.name,
    required this.reason,
    required this.path,
  });

  /// 技能目录名（技能的身份；`name` 与目录名不一致时按目录名报）。
  final String name;

  /// 失败原因（来自 `validateSkillMd`，含具体数值，例如 "name 超过 64 字符（实际 65）"）。
  final String reason;

  /// 该技能 `SKILL.md` 的绝对路径（日志与排错用）。
  final String path;

  /// 给界面/日志的一行话：技能名 + 原因。
  String get line => '技能 "$name" 未生效：$reason';
}

/// 一个候选技能目录的增量缓存条目（design D1）：`SKILL.md` 的指纹 + 上一轮算好的
/// 结果（生效条目**或**失败条目）。
///
/// 指纹 = `(修改时间, 文件大小)` 两个数（`Docs` 先例：`edit_file` 的版本检查同样只看
/// 这两个数）。`SKILL.md` 不存在时两个都为 null —— 那是"这个目录暂时不是一个技能"的
/// 指纹，新增文件后 stat 会给出真实指纹，于是下一轮被重读。
class _CachedSkill {
  const _CachedSkill({
    required this.mtimeMicros,
    required this.size,
    this.name,
    this.description,
    this.failure,
  });

  /// `SKILL.md` 的修改时间（微秒）与大小；两者都为 null 表示文件不存在。
  final int? mtimeMicros;
  final int? size;

  /// 生效条目的 frontmatter 名字与 description（[failure] 为 null 时非空）。
  final String? name;
  final String? description;

  /// 失败条目（[name] 为 null 时非空）。
  final SkillLoadFailure? failure;

  /// 指纹是否与这一轮 stat 到的两个数完全一致（一致就复用本条目）。
  bool matches(int? mtimeMicros, int? size) =>
      this.mtimeMicros == mtimeMicros && this.size == size;
}

/// 进程级技能目录服务（`ToolCatalog.instance` 单例同形）。
class SkillCatalogService {
  SkillCatalogService._();

  /// 进程内唯一一份技能目录。
  static final SkillCatalogService instance = SkillCatalogService._();

  Map<String, String> _active = <String, String>{};
  List<SkillLoadFailure> _failures = <SkillLoadFailure>[];
  String? _rootError;
  String? _rootPath;
  bool _scanned = false;

  /// 增量缓存：技能目录名 → 指纹 + 上一轮的结果（design D1）。
  Map<String, _CachedSkill> _cache = <String, _CachedSkill>{};

  /// 最近一次 [scan] 实际**重读并重新校验**的 `SKILL.md` 个数（design D4）。
  ///
  /// 用途只有一个：让"指纹未变的文件不被重读"这条语义**可被测试证明**（磁盘不动时
  /// 再扫必须为 0）。生产逻辑不许读它 —— 所以标了 `@visibleForTesting`，读它的只有
  /// `test/` 下的用例。
  @visibleForTesting
  int lastScanReReadCount = 0;

  /// 测试注入：把扫描根换掉（生产恒为 null，取 [defaultRootPath]）。
  ///
  /// 存在的理由：启动扫描发生在界面初始化链里，widget 用例要能用一个**临时目录**摆出
  /// "有失败技能"与"没有技能目录"两种现场 —— 否则用例会去读用户主目录里的真实技能
  /// 目录，结果随机器而变。与 C++ 侧 `skill_tool::set_root_for_tests` 同形。
  /// 推荐用 [setRootForTests] 设置它（传 null 恢复默认根）。
  static String? rootPathOverrideForTests;

  /// 测试钩子：把扫描根换成 [root]；传 null 恢复默认根（与 C++ 侧
  /// `skill_tool::set_root_for_tests` 同形）。
  ///
  /// 存在的理由：`scan()` 现在**每轮装配前都会调用**（design D2），而生产调用不传
  /// `rootPath`，所以用例必须让"缺省根"本身指向临时目录 —— 只给一次 `scan(rootPath:)`
  /// 传参已经不够了（下一轮会被真实的缺省根覆盖）。
  void setRootForTests(String? root) {
    rootPathOverrideForTests = root;
  }

  /// 技能根目录的缺省位置：`<主目录>/.aliasagent/skills`。
  ///
  /// 主目录与 `ConfigService.configDir` 同源（Windows 取 `USERPROFILE`），也就是
  /// C++ 侧 `spill.cpp` 的 `home_dir()` 那一份 —— 两侧不能算出两个不同的家目录。
  static String get defaultRootPath =>
      '${ConfigService.configDir}${Platform.pathSeparator}skills';

  /// 最近一次扫描用的技能根目录（未扫描时为 null）。
  String? get rootPath => _rootPath;

  /// 是否已经扫描过（启动初始化链或首轮请求装配把扫描置位）。
  bool get hasScanned => _scanned;

  /// 生效技能：名字 → description（只读，按名字字典序）。
  Map<String, String> get activeSkills => Map<String, String>.unmodifiable(_active);

  /// 生效技能名（按字典序，注入顺序就是它）。
  List<String> get activeSkillNames => List<String>.unmodifiable(_active.keys);

  /// 未生效技能清单（一行一条，含原因）。
  List<SkillLoadFailure> get failures =>
      List<SkillLoadFailure>.unmodifiable(_failures);

  /// 技能根整体不可读（路径存在但不是目录、或列不出来）的汇总提示。
  String? get rootError => _rootError;

  /// 给界面的提示行（每个失败技能一行；根不可读时另有汇总行）。没有失败时为 null。
  ///
  /// 与 `ToolListMigration.notices` 同形的"字符串提示"：由既有提示通道显示，
  /// 不新建任何界面（用户明令）。
  String? get failureNotice {
    final lines = noticeLines;
    if (lines.isEmpty) return null;
    return lines.join('\n');
  }

  /// 与 [failureNotice] 同内容的逐条形式（启动时逐条写日志用）。
  List<String> get noticeLines {
    final lines = <String>[];
    final rootError = _rootError;
    if (rootError != null) lines.add(rootError);
    for (final failure in _failures) {
      lines.add(failure.line);
    }
    return lines;
  }

  /// 某个技能是否生效。
  bool isActive(String name) => _active.containsKey(name);

  /// 某个技能没生效的原因（生效或根本没这个目录时为 null）。
  String? failureReasonFor(String name) {
    for (final failure in _failures) {
      if (failure.name == name) return failure.reason;
    }
    return null;
  }

  /// 注入系统提示词的技能段（`add-skill-mechanism` 任务 2.2；返工 5.1 改造）。
  ///
  /// - **有生效技能**：`Available skills…` 标题 + 每个技能一行 `- <name>: <description>`
  ///   （按名字字典序）+ 空行 + **创建技能简则**，全部在同一段文本里；
  /// - **没有生效技能**：只返回创建技能简则（**不再返回空串**）—— 没有 "Available
  ///   skills" 标题、没有 `- ` 清单行，不留空悬句子（规范「没有技能也给出写作简则」）。
  ///
  /// `description` 原样使用，不截断不改写（规范硬限已在校验处把关）。简则内容见
  /// [kSkillAuthoringGuide]（design D6：与校验规则不一致即缺陷）。
  String get promptSection {
    final sb = StringBuffer();
    if (_active.isNotEmpty) {
      sb.write('Available skills (load one with load_skill(skill) before following '
          'its instructions; load_skill also reads files inside the skill '
          'directory):');
      for (final entry in _active.entries) {
        sb.write('\n- ${entry.key}: ${entry.value}');
      }
      // 清单与简则之间空一行：清单是"有哪些"，简则是"怎么写"，分开读得清。
      sb.write('\n\n');
    }
    sb.write(kSkillAuthoringGuide);
    return sb.toString();
  }

  /// 增量刷新技能根：重建生效集合、失败清单与根错误，并更新指纹缓存。
  ///
  /// 规则（规范「技能目录的存放与发现」）：
  ///   - 技能根**不存在** ⇒ 正常状态：静默、零提示；
  ///   - 技能根**存在但不是目录**、或列不出来 ⇒ 一条"技能目录不可读"汇总提示；
  ///   - 子项是文件而不是目录 ⇒ 忽略；
  ///   - 子目录里的 `SKILL.md` 缺失或校验失败 ⇒ 记一行失败清单并排除出生效集合。
  ///
  /// **增量语义（design D1）**：目录里每个候选先 `statSync` 取 `(修改时间, 大小)` 两个
  /// 数；指纹与缓存一致就**原样复用**上轮结果（生效条目与失败条目都一样），只有新增 /
  /// 指纹变化 / 消失的条目才重读全文并重新校验。删掉的条目直接从缓存里消失。
  ///
  /// [rootPath] 只给测试用（生产不传，取 [rootPathOverrideForTests] 或
  /// [defaultRootPath]）。
  Future<void> scan({String? rootPath}) async {
    final stopwatch = Stopwatch()..start();
    final root = rootPath ?? rootPathOverrideForTests ?? defaultRootPath;
    if (_rootPath != null && _rootPath != root) {
      // 换根（测试钩子或显式 rootPath）时不能跨根复用指纹：目录名相同也是另一份内容。
      _cache = <String, _CachedSkill>{};
    }
    _rootPath = root;
    _scanned = true;
    lastScanReReadCount = 0;

    final active = <String, String>{};
    final failures = <SkillLoadFailure>[];
    String? rootError;
    var entries = const <FileSystemEntity>[];

    final type = FileSystemEntity.typeSync(root, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      // 首次用户没有技能目录是默认状态：静默。缓存里的条目已全部消失。
      _cache = <String, _CachedSkill>{};
    } else if (type != FileSystemEntityType.directory) {
      rootError = '技能目录不可读：$root（该路径存在但不是目录）';
      _cache = <String, _CachedSkill>{};
    } else {
      // 同步 IO：一轮只列一个小目录 + 每技能两个元数据数，不读内容；全量重读只发生在
      // 指纹变化的条目上。同步也是为了让 widget 用例能在 `testWidgets` 的 FakeAsync 区里
      // 得到确定结果（真实异步 I/O 的完成事件在该区里不会被投递）。
      try {
        entries = Directory(root).listSync(followLinks: false);
      } catch (e) {
        rootError = '技能目录不可读：$root（$e）';
        _cache = <String, _CachedSkill>{};
        entries = const <FileSystemEntity>[];
      }
    }

    // 新一轮的缓存只装"这一轮目录里真实存在的候选"：消失的条目自然不再被复用。
    final nextCache = <String, _CachedSkill>{};
    for (final entry in entries) {
      // 只有真实子目录才是候选技能；文件与符号链接都忽略（design Non-Goal：
      // 首版不支持 symlink 技能目录）。
      if (entry is! Directory) continue;
      final directoryName = _basename(entry.path);
      final skillFile = File('${entry.path}${Platform.pathSeparator}SKILL.md');

      FileStat? stat;
      Object? statError;
      try {
        stat = skillFile.statSync();
      } catch (e) {
        statError = e;
      }
      final mtimeMicros = stat?.modified.microsecondsSinceEpoch;
      final size = stat?.size;

      final cached = _cache[directoryName];
      final _CachedSkill current =
          (cached != null && cached.matches(mtimeMicros, size))
              ? cached // 指纹未变 ⇒ 复用上轮结果（含失败条目：坏文件不反复重读）
              : _readAndValidate(
                  directoryName: directoryName,
                  skillFile: skillFile,
                  mtimeMicros: mtimeMicros,
                  size: size,
                  statError: statError,
                );
      nextCache[directoryName] = current;

      final failure = current.failure;
      if (failure != null) {
        failures.add(failure);
      } else {
        active[current.name!] = current.description!;
      }
    }
    _cache = nextCache;

    final names = active.keys.toList()..sort();
    _active = <String, String>{for (final name in names) name: active[name]!};
    failures.sort((a, b) => a.name.compareTo(b.name));
    _failures = failures;
    _rootError = rootError;

    stopwatch.stop();
    // 实测值只记录、不断言阈值（design D4：无合法来源不发明上限）。
    debugPrint('[AliasAgent] 技能目录增量刷新：根=$root 生效=${_active.length} '
        '失败=${_failures.length} 重读=$lastScanReReadCount 个文件，'
        '耗时 ${stopwatch.elapsedMilliseconds} ms');
  }

  /// 读一份 `SKILL.md` 并校验，产出缓存条目（design D1）。
  ///
  /// 只有真的对文件内容做了工作的分支才累加 [lastScanReReadCount]：`SKILL.md` 不存在
  /// 时只有一次 stat，没有读也没有校验，不计入。
  _CachedSkill _readAndValidate({
    required String directoryName,
    required File skillFile,
    required int? mtimeMicros,
    required int? size,
    required Object? statError,
  }) {
    if (mtimeMicros == null) {
      return _CachedSkill(
        mtimeMicros: null,
        size: null,
        failure: SkillLoadFailure(
          name: directoryName,
          reason: '读不到 SKILL.md（$statError）',
          path: skillFile.path,
        ),
      );
    }
    lastScanReReadCount++;
    final String raw;
    try {
      raw = skillFile.readAsStringSync();
    } catch (e) {
      return _CachedSkill(
        mtimeMicros: mtimeMicros,
        size: size,
        failure: SkillLoadFailure(
          name: directoryName,
          reason: '读不到 SKILL.md（$e）',
          path: skillFile.path,
        ),
      );
    }
    final result = validateSkillMd(raw: raw, directoryName: directoryName);
    if (!result.ok) {
      return _CachedSkill(
        mtimeMicros: mtimeMicros,
        size: size,
        failure: SkillLoadFailure(
          name: directoryName,
          reason: result.error!,
          path: skillFile.path,
        ),
      );
    }
    return _CachedSkill(
      mtimeMicros: mtimeMicros,
      size: size,
      name: result.fields!.name,
      description: result.fields!.description,
    );
  }

  /// 测试用：清空扫描结果与指纹缓存（不动磁盘）。
  void resetForTests() {
    _active = <String, String>{};
    _failures = <SkillLoadFailure>[];
    _rootError = null;
    _rootPath = null;
    _scanned = false;
    _cache = <String, _CachedSkill>{};
    lastScanReReadCount = 0;
  }

  static String _basename(String path) {
    var end = path.length;
    while (end > 0 &&
        (path[end - 1] == '/' || path[end - 1] == '\\')) {
      end--;
    }
    var start = end;
    while (start > 0 && path[start - 1] != '/' && path[start - 1] != '\\') {
      start--;
    }
    return path.substring(start, end);
  }
}
