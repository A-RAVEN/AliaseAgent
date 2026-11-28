// 工作路径（工作区）的**纯逻辑**：输入规范化、校验与系统提示段常量
// （change `custom-workspace` design D4 / D5）。
//
// 这里是全产品唯一一套路径规则：`session.create` / `session.setWorkspace` /
// `group.create` / `group.setWorkspace` / `Agent.ensureContext` /
// `GroupService.ensureGroupContext` 全部调同一个 [workspaceProblem]，不写第二套。
//
// 本文件**不引入任何上下限数字**（design D14）：校验只有布尔判断，没有超时 / 重试 /
// 批大小。工作区是「默认根 + 软围栏」，不是沙箱；提示段如实写命令工具没有沙箱。
import 'dart:io';

import 'package:path/path.dart' as p;

/// 系统提示词里工作区段的标题（change `custom-workspace` design D5）。
///
/// 取自代码常量而不是手写字符串：系统提示注入、测试断言、用户文档都指向这一份。
const String kWorkspacePromptHeading = '当前工作区（工作路径）';

/// 「此电脑」虚拟根（change `custom-workspace` 返工任务 12.11）。
///
/// Windows 上盘符根（`C:\`）的上一级是它：`workspace.listDirs('@drives')` 返回本机
/// 逻辑盘作为 `directories`，web 面包屑据此显示「此电脑」并允许切换其它盘。
/// 它不是真实目录：`isDirectory=false`，不能被 `setWorkspace` 选成工作路径；
/// POSIX 没有盘符概念，不提供这一层（`/` 的 parent 仍是 `null`）。
const String kWorkspaceDrivesRoot = '@drives';

/// 枚举本机逻辑盘（仅 Windows；POSIX 返回空列表）。
///
/// 遍历 `A:`~`Z:` + `Directory.existsSync()`，不引新依赖。断开的网络盘 / 无权限的
/// 盘符不是可进入目标，跳过（不静默把它们当成空盘展示）。
List<String> windowsDriveRoots() {
  if (!Platform.isWindows) return const <String>[];
  final roots = <String>[];
  for (var code = 0x41; code <= 0x5A; code += 1) {
    final root = '${String.fromCharCode(code)}:\\';
    try {
      if (Directory(root).existsSync()) roots.add(root);
    } on FileSystemException {
      // 断开的网络盘 / 无权限：不作为可进入目标。
    }
  }
  return roots;
}

/// 是否是 Windows 盘符根（`C:\` / `C:/`；不含盘符相对路径 `C:`）。
bool _isWindowsDriveRoot(String path) =>
    RegExp(r'^[A-Za-z]:[\\/]*$').hasMatch(path);

/// 规范化用户输入的工作路径：去首尾空白 → **去掉一对匹配的双引号** → 折叠 `..` 与
/// 重复分隔符（保留用户的分隔符风格）。
///
/// 去掉双引号是因为 Windows Explorer 的「复制为路径」会带引号（design D4）；
/// 只去掉**成对**的引号：只有一侧引号的输入按字面处理，不猜用户意思。
String stripWorkspaceInput(String raw) {
  var text = raw.trim();
  if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
    text = text.substring(1, text.length - 1).trim();
  }
  if (text.isEmpty) return '';
  return p.normalize(text);
}

/// 校验一个**已经规范化**（或来自界面 / RPC）的工作路径；合法返回 `null`，否则返回
/// 一句可归因原因（空 / 非绝对 / 不存在 / 不是目录）。
///
/// 四类原因各自可区分：调用方把这句话原样交给用户与 RPC 错误消息，不做二次改写。
String? workspaceProblem(String path) {
  if (path.trim().isEmpty) {
    return '工作路径为空：请给出一个已存在的绝对目录';
  }
  if (!p.isAbsolute(path)) {
    return '工作路径「$path」不是绝对路径：请给出完整路径（如 C:\\work\\project）';
  }
  if (!FileSystemEntity.isDirectorySync(path)) {
    if (FileSystemEntity.isFileSync(path)) {
      return '工作路径「$path」存在但不是目录（是一个文件）：请改成一个目录';
    }
    return '工作路径「$path」不存在：请改成一个已存在的绝对目录';
  }
  return null;
}

/// 系统提示词里的工作区段（正常形态）。
///
/// 说明三件事：相对路径以它为根、文件工具越界会被拒绝、`run_command` 的缺省工作目录
/// 是它且**命令本身没有沙箱、以用户自己的权限执行、运行后不可撤销**（design D5 / D14：
/// 如实告知，不是缺陷声明）。最后一句说明工作路径可能被切换、每轮以此处为准。
///
/// **只追加**：调用方把它拼在既有系统提示词之后，不替换模板提示词（`Agent.send`）。
/// 段落**刻意不用 `- ` 开头的列表**：既有测试把「以 `- ` 开头的行」当作技能清单条目
/// （`skill_hot_refresh_test`），工作区段混进列表会污染那条判据。
String workspacePromptSection(String path) => '''
$kWorkspacePromptHeading：$path

相对路径一律以该目录为根解析；文件工具越出该目录的路径会被拒绝（Access denied: path outside workspace）。
`run_command` 的缺省工作目录就是它；命令本身没有沙箱，以你自己的权限执行，可以访问该目录之外的位置，运行后不可撤销。它不是安全边界。
工作路径可能被用户切换，每一轮都以此处给出的值为准。''';

/// 系统提示词里的工作区段（读不到 / 为空时的形态）。
///
/// **不省略整段、不伪造目录**：写明「当前没有可用工作区」与原因，并说明此时相对路径
/// 没有根、文件工具对绝对路径不设界（design D5）。调用方同时留一行日志点名句柄。
String workspaceUnavailablePromptSection(String reason) =>
    '''$kWorkspacePromptHeading：当前没有可用工作区（原因：$reason）。

相对路径没有可解析的根；文件工具对绝对路径不设界（等于没有默认目录）。
命令工具仍然没有沙箱、以你自己的权限执行、运行后不可撤销。
请让用户在主界面设置一个存在的工作路径，或改用绝对路径。''';

/// 工作路径不可用（不存在 / 不是目录 / 读取不到）。
///
/// 字段都保留下来供调用方归因：RPC 层据此回 `-32602`（消息含路径与出路），Flutter
/// 侧据此在界面顶部显示错误（不崩、不静默回落缺省目录）。
class WorkspaceUnavailableException implements Exception {
  const WorkspaceUnavailableException({
    required this.path,
    required this.reason,
    this.sessionId,
  });

  /// 出问题的设置值（规范化后的输入；读不到时为原始句柄侧值）。
  final String path;

  /// 可归因原因（空 / 非绝对 / 不存在 / 不是目录 / sidecar 读取失败）。
  final String reason;

  /// 相关会话 id（组会话时是组 id；读不到时可为 null）。
  final String? sessionId;

  /// 给用户 / RPC 错误的完整句子：含路径、原因与「改到已存在的目录」的出路。
  @override
  String toString() =>
      '工作路径「$path」不可用（$reason）。'
      '${sessionId == null ? '' : '会话「$sessionId」的'}工作区没有生效：'
      '请把它改到一个已存在且可写的目录，或用绝对路径继续。';
}

/// 文件夹选择对话框里的一层子目录（`workspace.listDirs` 的 `directories` 元素）。
///
/// 名字与绝对路径分开给：名字用于列表显示，路径用于下一次列举 / 最终写进
/// `sessions.workspace`（不要求前端自己拼分隔符 —— 分隔符风格由核心决定）。
class WorkspaceDirEntry {
  const WorkspaceDirEntry({required this.name, required this.path});

  final String name;
  final String path;

  Map<String, dynamic> toJson() => {'name': name, 'path': path};
}

/// `workspace.listDirs` 的一次目录列举结果（文件夹选择对话框的一层）。
class WorkspaceDirListing {
  const WorkspaceDirListing({
    required this.path,
    required this.parent,
    required this.directories,
    this.isDirectory = true,
  });

  /// 规范化后的绝对路径（对话里的「当前目录」）；「此电脑」虚拟根是 [kWorkspaceDrivesRoot]。
  final String path;

  /// 上级绝对路径；文件系统根（`C:\` / `/` / `\\server\share`）为 `null`，
  /// 界面据此禁用「上级」。Windows 盘符根的上一级是 [kWorkspaceDrivesRoot]。
  final String? parent;

  /// 只含**子目录**（不列文件），已按名字排序。
  final List<WorkspaceDirEntry> directories;

  /// 这一层是否是真实目录。`false` 只用于「此电脑」虚拟根：界面据此禁用
  /// 「选择此目录」，避免把 `@drives` 这种 sentinel 写进工作路径。
  final bool isDirectory;

  Map<String, dynamic> toJson() => {
        'path': path,
        'parent': parent,
        'directories': [for (final entry in directories) entry.toJson()],
        // 成功回包：路径合法可列举。真实目录 isDirectory=true；「此电脑」虚拟根
        // 不是目录，显式 false（不让前端把它当工作路径提交）。
        'exists': true,
        'isDirectory': isDirectory,
      };
}

/// 列举 [rawPath] 下的**子目录**（文件夹选择对话框的数据源）。
///
/// - 输入先经 [stripWorkspaceInput]（去首尾空白 / 去掉成对双引号 / 折叠 `..`）；
/// - 省略 / 只有空白 ⇒ [defaultDir]（生产 = `ConfigService.homeDir`，测试注入临时目录）；
/// - [rawPath] 等于 [kWorkspaceDrivesRoot] ⇒ 返回「此电脑」虚拟根（仅 Windows）：
///   列出本机逻辑盘（`C:\` / `D:\`…），`isDirectory=false`，不能当工作路径提交；
/// - **只列子目录、不列文件**（用户选的是工作目录，不是文件）；
/// - 按名字排序（忽略大小写的字典序，同名不同大小写时按原样兜底，输出稳定）；
/// - [WorkspaceDirListing.parent] 用 `p.dirname` 算：普通目录是上级；Windows 盘符根
///   是 [kWorkspaceDrivesRoot]；POSIX 根 / UNC 共享根为 `null`。
///
/// 路径不存在 / 不是目录 / 读不到 ⇒ 抛 [WorkspaceUnavailableException]（可归因），
/// **不静默返回空列表** —— 界面要能告诉用户为什么打不开这个目录。
///
/// [driveRoots] 只用于测试注入（固定盘符夹具）；生产不传 ⇒ [windowsDriveRoots]。
WorkspaceDirListing listWorkspaceDirectories(
  String? rawPath, {
  required String defaultDir,
  List<String>? driveRoots,
}) {
  final stripped = stripWorkspaceInput(rawPath ?? '');
  if (stripped == kWorkspaceDrivesRoot) {
    return _listWorkspaceDriveRoots(driveRoots: driveRoots);
  }
  final path = stripped.isEmpty ? p.normalize(defaultDir) : stripped;
  final problem = workspaceProblem(path);
  if (problem != null) {
    throw WorkspaceUnavailableException(path: path, reason: problem);
  }
  final entries = <WorkspaceDirEntry>[];
  try {
    // `followLinks: false`：枚举出的链接 / junction 再用 isDirectorySync 跟随判断，
    // 指向目录的链接（Windows junction）照样能选，坏链接自然被排除。
    for (final entity in Directory(path).listSync(followLinks: false)) {
      if (!FileSystemEntity.isDirectorySync(entity.path)) continue;
      entries.add(WorkspaceDirEntry(
        name: p.basename(entity.path),
        path: p.normalize(entity.path),
      ));
    }
  } on FileSystemException catch (e) {
    throw WorkspaceUnavailableException(
      path: path,
      reason: '目录读取失败（${e.message}）',
    );
  }
  entries.sort(_compareDirEntries);
  final parentDir = p.dirname(path);
  final String? parent;
  if (p.equals(parentDir, path)) {
    // Windows 盘符根还能「上级」到「此电脑」；POSIX 根 / UNC 共享根到顶。
    parent = _isWindowsDriveRoot(path) ? kWorkspaceDrivesRoot : null;
  } else {
    parent = p.normalize(parentDir);
  }
  return WorkspaceDirListing(
    path: p.normalize(path),
    parent: parent,
    directories: entries,
  );
}

int _compareDirEntries(WorkspaceDirEntry a, WorkspaceDirEntry b) {
  final byLower = a.name.toLowerCase().compareTo(b.name.toLowerCase());
  return byLower != 0 ? byLower : a.name.compareTo(b.name);
}

/// 「此电脑」虚拟根：列出本机逻辑盘（[driveRoots] 仅测试注入）。
WorkspaceDirListing _listWorkspaceDriveRoots({List<String>? driveRoots}) {
  final roots = driveRoots ?? windowsDriveRoots();
  if (roots.isEmpty) {
    throw WorkspaceUnavailableException(
      path: kWorkspaceDrivesRoot,
      reason: Platform.isWindows
          ? '没有发现可用的磁盘驱动器'
          : '「此电脑」只在 Windows 上可用（当前系统没有盘符概念，请直接浏览 /）',
    );
  }
  final entries = <WorkspaceDirEntry>[];
  for (final raw in roots) {
    final root = p.normalize(raw);
    final name = root.replaceAll(RegExp(r'[\\/]+$'), '');
    if (name.isEmpty) continue;
    entries.add(WorkspaceDirEntry(name: name, path: root));
  }
  entries.sort(_compareDirEntries);
  return WorkspaceDirListing(
    path: kWorkspaceDrivesRoot,
    parent: null,
    directories: entries,
    isDirectory: false,
  );
}
