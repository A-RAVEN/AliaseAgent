// 技能目录服务与注入文本的单测（change `add-skill-mechanism` 任务 2.3）。
//
// 覆盖四件事（每条对应 tasks 2.1 / 2.2 的一句）：
//   ① 技能根不存在 ⇒ 零提示零报错（首次用户的默认状态，规范「没有技能目录时零打扰」）；
//   ② 混放 1 合法 + 2 非法（超长 name、无 frontmatter）⇒ 生效集合只含合法那 1 条，
//      失败清单含两条各自原因，且一行式提示里有技能名；
//   ③ 技能根路径指向一个**文件**（模拟"存在但整体不可读"）⇒ 一条"技能目录不可读"
//      汇总、生效集合为空、不抛异常；
//   ④ 生效技能按 name 字典序；注入文本含使用说明句与逐行 `- <name>: <description>`，
//      且 `description` 原样出现、不含任何省略字样（不截断不改写）。
//
// change `refresh-skill-catalog-each-turn` 任务 1.2 追加的**增量刷新**用例（第 8–13 条）：
//   ⑤ 首次扫 3 个合法技能 ⇒ `lastScanReReadCount = 3`；
//   ⑥ 磁盘不动再扫 ⇒ `= 0`、目录文本与生效集合逐字不变；
//   ⑦ 改 1 个文件的内容 ⇒ `= 1`、该条 description 换成新值（其余条目复用）；
//   ⑧ 删 1 个技能目录 ⇒ 生效集合少一条（消失的条目不重读，计数不增）；
//   ⑨ 校验失败的坏文件不动再扫 ⇒ 失败清单逐字保持、`lastScanReReadCount = 0`
//      （失败条目同样复用缓存，坏文件不反复重读）；
//   ⑩ **已知检测盲区如实测**：把文件改成**同长度**内容并把 mtime 设回原值 ⇒
//      磁盘确实变了、目录却不更新、重读计数为 0 —— 这是 spec 登记的检测盲区
//      （design D1 与 `skills.md` 限制节），不是"缺陷通过"。
//
// 返工追加（2026-11-08，design D6）的**创建技能简则**用例（本轮新增的三条，见本文件
// 末尾）：
//   ⑪ 空目录 ⇒ `promptSection` **不再为空**，只含创建简则（目录位置、技能名规则、
//      frontmatter 必填字段与上限、下一条消息生效、校验失败界面可见原因），且
//      **不含** "Available skills" 标题与 `- ` 清单行（不留空悬句子）；
//   ⑫ 有生效技能 ⇒ 标题 + 清单 + 简则同段（清单在前、简则在后）；
//   ⑬ 简则的 64 / 1024 / 500 与 `skill_frontmatter.dart` 的常量**双向**对齐
//      （简则手抄错数字、或常量改了简则没跟，都会红 —— 防简则与校验漂移）。
//
// 夹具全部在系统临时目录里造，不碰用户主目录的真实技能目录。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/skills/skill_catalog_service.dart';
import 'package:alias_agent/services/skills/skill_frontmatter.dart';

/// 一份合法 `SKILL.md`。
String validSkillMd(String name, String description) =>
    '---\nname: $name\ndescription: $description\n---\n# 正文\n';

String get _sep => Platform.pathSeparator;

void main() {
  late Directory root;

  setUp(() {
    SkillCatalogService.instance.resetForTests();
    root = Directory.systemTemp.createTempSync('skill_catalog_');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
    SkillCatalogService.instance.resetForTests();
  });

  void writeSkill(String dirName, String content, {String fileName = 'SKILL.md'}) {
    final dir = Directory('${root.path}$_sep$dirName')..createSync(recursive: true);
    File('${dir.path}$_sep$fileName').writeAsStringSync(content);
  }

  test('技能根不存在 ⇒ 零提示零报错、生效集合为空', () async {
    final missing = '${root.path}${_sep}not-created';
    await SkillCatalogService.instance.scan(rootPath: missing);

    // ignore: avoid_print
    print('[技能目录] 不存在：active=${SkillCatalogService.instance.activeSkills} '
        'failures=${SkillCatalogService.instance.failures.length} '
        'rootError=${SkillCatalogService.instance.rootError} '
        'notice=${SkillCatalogService.instance.failureNotice}');
    expect(SkillCatalogService.instance.activeSkills, isEmpty);
    expect(SkillCatalogService.instance.failures, isEmpty);
    expect(SkillCatalogService.instance.rootError, isNull);
    expect(SkillCatalogService.instance.failureNotice, isNull,
        reason: '没建技能目录是正常状态，不许出任何提示');
    // 返工 5.1 新口径（design D6）：空技能不再返回空串 —— 改为**只注创建简则**
    // （无 "Available skills" 标题、无 `- ` 清单行）。本处只钉"不再是空串"，四条
    // 关键内容与"无空悬句子"由下面「空技能目录 ⇒ promptSection 只含创建简则」专门用例
    // 逐条断言；旧断言 `isEmpty` 在新口径下必红，故按新口径改写（不是放松：同一文件
    // 里新增了更强的正向 + 负向断言）。
    expect(SkillCatalogService.instance.promptSection, contains('.aliasagent/skills/'),
        reason: '没有生效技能时仍要注入创建简则（design D6）');
  });

  test('混放 1 合法 + 2 非法 ⇒ 生效 1 条、失败两条各有原因', () async {
    final longName = 'a' * 65;
    writeSkill('pdf-tools', validSkillMd('pdf-tools', '处理 PDF：拆分与合并'));
    writeSkill(longName, validSkillMd(longName, '名字超长'));
    writeSkill('no-frontmatter', 'name: no-frontmatter\ndescription: 没有 frontmatter\n');

    await SkillCatalogService.instance.scan(rootPath: root.path);
    final service = SkillCatalogService.instance;
    // ignore: avoid_print
    print('[技能目录] 生效=${service.activeSkills}');
    for (final failure in service.failures) {
      // ignore: avoid_print
      print('[技能目录] 失败：${failure.line}（${failure.path}）');
    }
    // ignore: avoid_print
    print('[技能目录] 提示=${service.failureNotice}');

    expect(service.activeSkills.keys, ['pdf-tools']);
    expect(service.activeSkills['pdf-tools'], '处理 PDF：拆分与合并');
    expect(service.failures.length, 2);

    final longNameFailure = service.failures.firstWhere((f) => f.name == longName);
    expect(longNameFailure.reason, contains('name 超过 64 字符'));
    final noFrontmatterFailure =
        service.failures.firstWhere((f) => f.name == 'no-frontmatter');
    expect(noFrontmatterFailure.reason, contains('没有 frontmatter'));

    final notice = service.failureNotice ?? '';
    expect(notice, contains(longName), reason: '提示行要含技能名');
    expect(notice, contains('no-frontmatter'));
    expect(notice, contains('name 超过 64 字符'), reason: '提示行要含原因');
    expect(notice, contains('没有 frontmatter'));
    expect(service.isActive('no-frontmatter'), isFalse);
    expect(service.failureReasonFor('no-frontmatter'), contains('没有 frontmatter'));
    expect(service.failureReasonFor('pdf-tools'), isNull,
        reason: '生效的技能没有失败原因');
  });

  test('技能根指向一个文件（整体不可读）⇒ 汇总提示、集合为空、不抛异常', () async {
    final filePath = '${root.path}${_sep}afile.txt';
    File(filePath).writeAsStringSync('not a directory');

    await SkillCatalogService.instance.scan(rootPath: filePath);
    final service = SkillCatalogService.instance;
    // ignore: avoid_print
    print('[技能目录] 根是文件：rootError=${service.rootError} '
        'active=${service.activeSkills} notice=${service.failureNotice}');
    expect(service.activeSkills, isEmpty);
    expect(service.failures, isEmpty);
    expect(service.rootError, contains('技能目录不可读'));
    expect(service.rootError, contains(filePath));
    expect(service.failureNotice, contains('技能目录不可读'));
  });

  test('子项是文件而不是目录 ⇒ 忽略（不产生失败条目）', () async {
    File('${root.path}${_sep}loose.txt').writeAsStringSync('不是技能');
    writeSkill('real-skill', validSkillMd('real-skill', '真正的技能'));
    await SkillCatalogService.instance.scan(rootPath: root.path);

    // ignore: avoid_print
    print('[技能目录] 混放文件：active=${SkillCatalogService.instance.activeSkills.keys} '
        'failures=${SkillCatalogService.instance.failures.length}');
    expect(SkillCatalogService.instance.activeSkills.keys, ['real-skill']);
    expect(SkillCatalogService.instance.failures, isEmpty);
  });

  test('生效技能按 name 字典序，注入文本逐行且 description 原样不截断', () async {
    final longDescription = 'Z 开头的技能描述：${'x' * 300}';
    writeSkill('zebra', validSkillMd('zebra', longDescription));
    writeSkill('alpha', validSkillMd('alpha', 'A 开头的技能描述'));
    writeSkill('middle', validSkillMd('middle', 'M 开头的技能描述'));

    await SkillCatalogService.instance.scan(rootPath: root.path);
    final service = SkillCatalogService.instance;
    final section = service.promptSection;
    // ignore: avoid_print
    print('[技能目录] activeSkillNames=${service.activeSkillNames}');
    // ignore: avoid_print
    print('[技能目录] 注入文本：\n$section');

    expect(service.activeSkillNames, ['alpha', 'middle', 'zebra'],
        reason: '按 name 字典序（可测、稳定）');
    expect(section, startsWith('Available skills'));
    expect(section, contains('load_skill'));
    expect(section, contains('\n- alpha: A 开头的技能描述'));
    expect(section, contains('\n- middle: M 开头的技能描述'));
    expect(section, contains('\n- zebra: $longDescription'),
        reason: 'description 不截断不改写');
    expect(section.indexOf('- alpha:'), lessThan(section.indexOf('- middle:')));
    expect(section.indexOf('- middle:'), lessThan(section.indexOf('- zebra:')));
    // 不出现任何"省略"字样（本 change 不在目录段做任何裁剪）。
    expect(section, isNot(contains('...')));
    expect(section, isNot(contains('省略')));
    expect(section, isNot(contains('truncated')));
  });

  test('重复扫描会重建集合（先有后无 ⇒ 集合与提示一起清空）', () async {
    writeSkill('once', validSkillMd('once', '只存在一轮'));
    await SkillCatalogService.instance.scan(rootPath: root.path);
    expect(SkillCatalogService.instance.isActive('once'), isTrue);

    Directory('${root.path}${_sep}once').deleteSync(recursive: true);
    await SkillCatalogService.instance.scan(rootPath: root.path);
    // ignore: avoid_print
    print('[技能目录] 重建后：active=${SkillCatalogService.instance.activeSkills}');
    expect(SkillCatalogService.instance.activeSkills, isEmpty);
    expect(SkillCatalogService.instance.failureNotice, isNull);
  });

  // ---------------------------------------------------------------------------
  // 增量刷新（change `refresh-skill-catalog-each-turn` 任务 1.2）
  //
  // 每条都读 `lastScanReReadCount`（design D4 的测试可见计数）来证明"没重读"——只断言
  // 目录文本一样是不够的：全量重读也能得到一样的文本。
  // ---------------------------------------------------------------------------

  test('首次扫 3 个合法技能 ⇒ 重读计数=3；磁盘不动再扫 ⇒ 计数=0 且文本逐字不变',
      () async {
    writeSkill('alpha', validSkillMd('alpha', 'A 的描述'));
    writeSkill('beta', validSkillMd('beta', 'B 的描述'));
    writeSkill('gamma', validSkillMd('gamma', 'C 的描述'));

    await SkillCatalogService.instance.scan(rootPath: root.path);
    final firstSection = SkillCatalogService.instance.promptSection;
    // ignore: avoid_print
    print('[增量] 首次扫描：active=${SkillCatalogService.instance.activeSkills.keys} '
        '重读=${SkillCatalogService.instance.lastScanReReadCount}');
    expect(SkillCatalogService.instance.activeSkills.keys, ['alpha', 'beta', 'gamma']);
    expect(SkillCatalogService.instance.lastScanReReadCount, 3,
        reason: '首次扫描没有缓存可用，三个文件都要读');

    await SkillCatalogService.instance.scan(rootPath: root.path);
    // ignore: avoid_print
    print('[增量] 原样再扫：重读=${SkillCatalogService.instance.lastScanReReadCount} '
        '文本一致=${SkillCatalogService.instance.promptSection == firstSection}');
    expect(SkillCatalogService.instance.lastScanReReadCount, 0,
        reason: '磁盘没变 ⇒ 一个文件都不许重读（design D1/D4）');
    expect(SkillCatalogService.instance.promptSection, firstSection,
        reason: '目录文本与上一轮逐字相同');
    expect(SkillCatalogService.instance.activeSkills.keys, ['alpha', 'beta', 'gamma']);
  });

  test('改 1 个文件内容 ⇒ 重读计数=1，该条 description 换成新值', () async {
    writeSkill('alpha', validSkillMd('alpha', 'A 的旧描述'));
    writeSkill('beta', validSkillMd('beta', 'B 的描述'));
    writeSkill('gamma', validSkillMd('gamma', 'C 的描述'));
    await SkillCatalogService.instance.scan(rootPath: root.path);
    expect(SkillCatalogService.instance.lastScanReReadCount, 3);

    writeSkill('alpha', validSkillMd('alpha', 'A 的新描述（长了几个字）'));
    await SkillCatalogService.instance.scan(rootPath: root.path);
    final service = SkillCatalogService.instance;
    // ignore: avoid_print
    print('[增量] 改 1 个后：重读=${service.lastScanReReadCount} '
        'active=${service.activeSkills}');
    expect(service.lastScanReReadCount, 1,
        reason: '只有指纹变过的那个文件被重读（未变的两条复用缓存）');
    expect(service.activeSkills['alpha'], 'A 的新描述（长了几个字）');
    expect(service.activeSkills['beta'], 'B 的描述');
    expect(service.promptSection, contains('- alpha: A 的新描述（长了几个字）'));
    expect(service.promptSection, isNot(contains('A 的旧描述')));
  });

  test('删 1 个技能目录 ⇒ 生效集合少一条，消失的条目不计重读', () async {
    writeSkill('alpha', validSkillMd('alpha', 'A 的描述'));
    writeSkill('beta', validSkillMd('beta', 'B 的描述'));
    writeSkill('gamma', validSkillMd('gamma', 'C 的描述'));
    await SkillCatalogService.instance.scan(rootPath: root.path);
    expect(SkillCatalogService.instance.activeSkills.keys, ['alpha', 'beta', 'gamma']);

    Directory('${root.path}${_sep}beta').deleteSync(recursive: true);
    await SkillCatalogService.instance.scan(rootPath: root.path);
    final service = SkillCatalogService.instance;
    // ignore: avoid_print
    print('[增量] 删 beta 后：重读=${service.lastScanReReadCount} '
        'active=${service.activeSkills.keys}');
    expect(service.activeSkills.keys, ['alpha', 'gamma']);
    expect(service.isActive('beta'), isFalse);
    expect(service.lastScanReReadCount, 0,
        reason: '剩下的两条指纹没变；删掉的那条没有文件可读（不计重读）');
  });

  test('校验失败的坏文件不动再扫 ⇒ 失败清单保持、重读计数=0', () async {
    writeSkill('good-skill', validSkillMd('good-skill', '合法技能'));
    // 目录名合法、frontmatter 的 name 是 65 字符 ⇒ 校验失败。
    writeSkill('broken-skill', '---\nname: ${'a' * 65}\ndescription: 坏技能\n---\n# 正文\n');
    await SkillCatalogService.instance.scan(rootPath: root.path);
    final service = SkillCatalogService.instance;
    final firstLines = List<String>.from(service.noticeLines);
    expect(service.activeSkills.keys, ['good-skill']);
    expect(firstLines.length, 1);
    expect(service.lastScanReReadCount, 2, reason: '首次两条都要读（含坏文件）');

    await SkillCatalogService.instance.scan(rootPath: root.path);
    // ignore: avoid_print
    print('[增量] 坏文件不动再扫：重读=${service.lastScanReReadCount} '
        '失败清单=$firstLines / ${service.noticeLines}');
    expect(service.lastScanReReadCount, 0,
        reason: '失败条目同样复用缓存：坏文件不反复重读（design D1）');
    expect(service.noticeLines, firstLines,
        reason: '失败清单逐字保持（原因不许变成另一句）');
    expect(service.activeSkills.keys, ['good-skill']);
  });

  test('已知检测盲区：同长度内容 + 把 mtime 设回原值 ⇒ 探测不到、目录不更新', () async {
    // **这是 spec 登记的已知限制，不是本用例放宽标准**（design D1 / skills.md 限制节）：
    // 指纹只有 (mtime, size) 两个数，覆盖写如果**同时**保持这两个数就探测不到。
    // 这里如实把它测出来，钉住"盲区存在"这一事实 —— 将来若真有更强检测（路线 B 监听器），
    // 这条用例会变成红，届时按新规范改写它，而不是删掉。
    writeSkill('blind-spot', validSkillMd('blind-spot', '旧描述'));
    await SkillCatalogService.instance.scan(rootPath: root.path);
    final service = SkillCatalogService.instance;
    expect(service.activeSkills['blind-spot'], '旧描述');
    expect(service.lastScanReReadCount, 1);

    final skillFile =
        File('${root.path}${_sep}blind-spot${_sep}SKILL.md');
    final before = skillFile.statSync();
    // 同长度覆盖写：新旧描述都是 3 个汉字（UTF-8 各 3 字节），文件大小不变。
    final newContent = validSkillMd('blind-spot', '新描述');
    expect(newContent.length, skillFile.readAsStringSync().length,
        reason: '前提：新内容与旧内容的**字符数**相同（配合下面的 setLastModified）');
    skillFile.writeAsStringSync(newContent);
    skillFile.setLastModifiedSync(before.modified);

    final after = skillFile.statSync();
    // ignore: avoid_print
    print('[盲区] 覆盖写后：size ${before.size} -> ${after.size}；'
        'mtime ${before.modified.microsecondsSinceEpoch} -> '
        '${after.modified.microsecondsSinceEpoch}；'
        '磁盘正文含"新描述"=${skillFile.readAsStringSync().contains('新描述')}');
    // 前提断言：盲区的两个条件真的成立了（否则本用例测的就不是盲区）。
    expect(after.size, before.size, reason: '前提：文件大小没变');
    expect(after.modified.microsecondsSinceEpoch,
        before.modified.microsecondsSinceEpoch,
        reason: '前提：mtime 被设回原值（这一步就是盲区的构造）');
    expect(skillFile.readAsStringSync(), contains('新描述'),
        reason: '前提：磁盘上确实是新内容（不是没写进去）');

    await service.scan(rootPath: root.path);
    // ignore: avoid_print
    print('[盲区] 再扫：重读=${service.lastScanReReadCount} '
        'active=${service.activeSkills}');
    expect(service.lastScanReReadCount, 0,
        reason: '指纹没变 ⇒ 不重读（这就是盲区的成因）');
    expect(service.activeSkills['blind-spot'], '旧描述',
        reason: 'spec 登记的已知限制：同 mtime 同大小的覆盖写探测不到，目录保持旧值');
    expect(service.promptSection, isNot(contains('新描述')));
  });

  // ---------------------------------------------------------------------------
  // 创建技能简则（change `refresh-skill-catalog-each-turn` 返工 5.1 / 5.2，design D6）
  //
  // 新口径：`promptSection` **永不为空** —— 没有生效技能时只注简则（无 "Available
  // skills" 标题、无 `- ` 清单行），有技能时标题 + 清单 + 简则同段。简则的四条事实
  // 必须与 `skill_frontmatter.dart` 及用户文档一致，不一致即缺陷。
  // ---------------------------------------------------------------------------

  test('空技能目录 ⇒ promptSection 只含创建简则：四件关键事齐备、无标题无清单行',
      () async {
    // `root` 是 setUp 里新建的**空目录**（不写任何技能），正是"空目录"现场。
    await SkillCatalogService.instance.scan(rootPath: root.path);
    final service = SkillCatalogService.instance;
    final section = service.promptSection;
    // ignore: avoid_print
    print('[简则] 空目录 promptSection（${section.length} 字符）：\n$section');

    expect(service.activeSkills, isEmpty, reason: '前提：目录里确实没有生效技能');
    expect(section, isNotEmpty,
        reason: '空目录不再返回空串：要注入创建简则（design D6）');

    // 简则必含的内容（task 5.1 原文逐条对应）。
    expect(section, contains('.aliasagent/skills/'),
        reason: '① 目录位置：<主目录>/.aliasagent/skills/');
    expect(section, contains('The directory name IS the skill name'),
        reason: '② 技能名规则：目录名即技能名');
    expect(section, contains('name (required'),
        reason: '③ frontmatter 必填 name');
    expect(section, contains('description (required'),
        reason: '③ frontmatter 必填 description');
    expect(section, contains('compatibility'),
        reason: '③ compatibility 字段与其上限也要写（校验器会查它）');
    expect(section, contains('takes effect on your next message'),
        reason: '④ 写好下一条消息生效');
    expect(section, contains('shows the reason'),
        reason: '⑤ 校验失败界面可见原因（task 5.1 原文）');

    // 不留空悬句子：没有技能时不许出现目录标题与清单行。
    expect(section, isNot(contains('Available skills')),
        reason: '没有生效技能时不出 "Available skills" 标题');
    final listLines =
        section.split('\n').where((line) => line.startsWith('- ')).toList();
    // ignore: avoid_print
    print('[简则] 空目录里的 `- ` 清单行=$listLines');
    expect(listLines, isEmpty, reason: '没有生效技能时不许有 `- ` 清单行');
  });

  test('有技能 ⇒ 清单与简则同段，清单在前、简则在后', () async {
    writeSkill('alpha', validSkillMd('alpha', 'A 的描述'));
    writeSkill('beta', validSkillMd('beta', 'B 的描述'));
    await SkillCatalogService.instance.scan(rootPath: root.path);
    final section = SkillCatalogService.instance.promptSection;
    // ignore: avoid_print
    print('[简则] 有技能 promptSection：\n$section');

    expect(section, startsWith('Available skills'), reason: '有技能时标题在最前');
    expect(section, contains('\n- alpha: A 的描述'));
    expect(section, contains('\n- beta: B 的描述'));
    expect(section, contains('Skill authoring guide'),
        reason: '简则必须与目录清单同段注入（design D6：有技能=标题+清单+简则）');
    expect(section, contains('.aliasagent/skills/'),
        reason: '有技能时简则内容同样在段里');
    expect(section.indexOf('- alpha:'),
        lessThan(section.indexOf('Skill authoring guide')),
        reason: '清单在前、简则在后（清单不被简则插断）');
  });

  test('简则的 64 / 1024 / 500 与 skill_frontmatter.dart 常量双向对齐（防漂移）',
      () async {
    await SkillCatalogService.instance.scan(rootPath: root.path);
    final guide = SkillCatalogService.instance.promptSection;
    // ignore: avoid_print
    print('[简则] 上限数断言：name=$kSkillNameMaxChars '
        'description=$kSkillDescriptionMaxChars '
        'compatibility=$kSkillCompatibilityMaxChars；'
        '简则含 64=${guide.contains('1-64 chars')} '
        '含 1024=${guide.contains('1-1024 chars')} '
        '含 500=${guide.contains('1-500 chars')}');

    // 字面量方向：简则真的写出了校验器用的三个上限数。
    expect(guide, contains('1-64 chars'), reason: 'name 上限必须是 64');
    expect(guide, contains('1-1024 chars'), reason: 'description 上限必须是 1024');
    expect(guide, contains('1-500 chars'),
        reason: 'compatibility 上限必须是 500（若提供）');

    // 常量方向：三个数必须来自 `skill_frontmatter.dart` 的常量本身 —— 常量改了而
    // 简则手抄着旧数字，这一组断言就红（这就是"防简则与校验漂移"的可失败判据）。
    expect(guide, contains('1-$kSkillNameMaxChars chars'));
    expect(guide, contains('1-$kSkillDescriptionMaxChars chars'));
    expect(guide, contains('1-$kSkillCompatibilityMaxChars chars'));

    // 真相源现值（校验器真正用的限值；出处 `Docs/AgentSkillsDoc.md` 第一节字段表）。
    expect(kSkillNameMaxChars, 64);
    expect(kSkillDescriptionMaxChars, 1024);
    expect(kSkillCompatibilityMaxChars, 500);
  });

  test('技能定义常量：名字是 load_skill，参数 skill 必填、file 可选', () {
    // ignore: avoid_print
    print('[技能目录] 定义=${kLoadSkillToolDefinition['name']} '
        'schema=${kLoadSkillToolDefinition['input_schema']}');
    expect(kLoadSkillToolName, 'load_skill');
    expect(kLoadSkillToolDefinition['name'], kLoadSkillToolName);
    final schema = kLoadSkillToolDefinition['input_schema'] as Map;
    expect(schema['required'], ['skill']);
    final properties = schema['properties'] as Map;
    expect(properties.keys.toSet(), {'skill', 'file'});
  });
}
