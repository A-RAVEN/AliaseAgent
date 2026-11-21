// 工具目录播种与条件注册的**共享实现**（change `web-ui-core-shim` 任务 2.1）。
//
// 这段逻辑原来只住在 `lib/main.dart` 的 `_initSearchAndTools()` 里。无头核心没有
// Flutter UI，但仍必须完成同样的注册（基础工具 + load_skill schema、浏览器可用性
// 探测、ensureSearchInfra/getSearchProviders 门控），否则 `ToolCatalog` 为空，
// `AgentFactory.resolveCandidate` 会对默认模板抛 `UnknownToolsException`。
//
// 抽取只搬家不改行为：Flutter 侧与无头侧调用同一个函数；两侧各自负责自己的
// “就绪”信号（Flutter 的 `_toolsReadyCompleter` / 无头的发送门禁）与界面提示。
import 'dart:convert';

import '../models/app_config.dart';
import 'agent_type_registry.dart';
import 'logging.dart';
import 'provider_resolver.dart';
import 'sidecar_bridge.dart';
import 'skills/skill_catalog_service.dart';
import 'tool_catalog.dart';

/// 工具播种完成后的可观察结果。
class ToolBootstrapResult {
  /// 浏览器运行时是否可用（决定 browser_* 四件套是否注册）。
  final bool browserAvailable;

  /// 条件注册的搜索 provider 名（空 = 没注册 web_search / web_fetch）。
  final List<String> searchProviderNames;

  /// 技能目录失败提示的逐条形式（启动时逐条写日志用）。
  final List<String> skillNoticeLines;

  /// 技能目录失败提示的汇总一句（界面/无头日志上屏用）；null = 无失败。
  final String? skillFailureNotice;

  const ToolBootstrapResult({
    required this.browserAvailable,
    required this.searchProviderNames,
    required this.skillNoticeLines,
    required this.skillFailureNotice,
  });
}

/// 播种工具目录并做条件注册。**调用方负责**“什么时候算就绪”：
/// 返回后目录里已经是这一轮该有的全部工具。
Future<ToolBootstrapResult> initSearchAndTools({
  required AppConfig config,
  required ISidecar sidecar,
  required AgentTypeRegistry templates,
  required ProviderResolver? Function() providerResolver,
}) async {
    final base = <String, Map<String, dynamic>>{
      'read_file': const {
        'name': 'read_file',
        'description': 'Read the contents of a file within the workspace. '
            'Returns the file content with 1-indexed line numbers (cat -n format). '
            'Files over 2000 lines are truncated; use offset/limit to read more.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Path to the file relative to the workspace root.',
            },
            'offset': {
              'type': 'integer',
              'description': 'Start line number (1-indexed). Default: 1.',
            },
            'limit': {
              'type': 'integer',
              'description': 'Number of lines to read. Default: 2000, max: 2000.',
            },
          },
          'required': ['path'],
        },
      },
      'write_file': const {
        'name': 'write_file',
        'description': 'Create or overwrite a file in the workspace. '
            'Use this for creating new files or complete rewrites. '
            'The response indicates whether the file was created or overwritten.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'File path relative to workspace root.',
            },
            'content': {
              'type': 'string',
              'description': 'Complete file content to write.',
            },
          },
          'required': ['path', 'content'],
        },
      },
      'edit_file': const {
        'name': 'edit_file',
        'description': 'Edit a file by replacing text. Accepts a batch of '
            'replacement pairs in one call. You MUST read the file first to get '
            'the exact old_text. Each old_text must match exactly (whitespace '
            'differences are auto-normalized) and must not be empty. If an '
            'old_text matches multiple locations and its replace_all is false, '
            'the whole request is rejected — add more context to make it unique '
            'or set replace_all:true. All pairs are validated against the '
            'original content first; if any pair fails, no changes are applied. '
            'Overlapping edits are rejected. Up to 100 pairs per call.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'File path relative to workspace root.',
            },
            'edits': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'old_text': {
                    'type': 'string',
                    'description': 'Exact text to find and replace. Must not be empty.',
                  },
                  'new_text': {
                    'type': 'string',
                    'description': 'Replacement text. May be empty to delete text.',
                  },
                  'replace_all': {
                    'type': 'boolean',
                    'default': false,
                    'description': 'Replace all occurrences instead of just the first.',
                  },
                },
                'required': ['old_text', 'new_text'],
              },
              'description': 'Replacement pairs. At least one required; max 100.',
            },
          },
          'required': ['path', 'edits'],
        },
      },
      'list_dir': const {
        'name': 'list_dir',
        'description': 'List the contents of a directory within the workspace.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Path to the directory relative to the workspace root.',
            },
          },
          'required': ['path'],
        },
      },
      'get_current_time': const {
        'name': 'get_current_time',
        'description': 'Get the current date, time, and timezone. Use this when you need to know the actual current time for time-sensitive queries.',
        'input_schema': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
      'glob_file': const {
        'name': 'glob_file',
        'description': 'Find files within the workspace matching a glob pattern '
            '(gitignore-style: supports *, **, ?, and ! negation). '
            'Returns workspace-relative paths, one per line, limited to '
            'max_results (default 200). Use this when you need to discover '
            'which files exist before reading or searching them.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'pattern': {
              'type': 'string',
              'description': 'Glob pattern relative to the workspace root, e.g. "lib/**/*.dart".',
            },
            'max_results': {
              'type': 'integer',
              'minimum': 1,
              'default': 200,
              'description': 'Maximum number of paths to return.',
            },
          },
          'required': ['pattern'],
        },
      },
      'grep_file': const {
        'name': 'grep_file',
        'description': 'Search file contents within the workspace using a '
            'regular expression. Returns matches as "path:line: text", with '
            'workspace-relative paths, limited to max_results (default 100). '
            'Supports an optional glob filter and case-insensitive search. '
            'Note: when glob is non-empty it overrides gitignore rules — files '
            'matching the glob are searched even if they would otherwise be ignored.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'pattern': {
              'type': 'string',
              'description': 'Regular expression to search for.',
            },
            'glob': {
              'type': 'string',
              'description': 'Optional glob restricting which files are searched '
                  '(e.g. "sidecar/src/*.cpp"). When set, it overrides gitignore rules.',
            },
            'ignore_case': {
              'type': 'boolean',
              'default': false,
              'description': 'Case-insensitive search.',
            },
            'max_results': {
              'type': 'integer',
              'minimum': 1,
              'default': 100,
              'description': 'Maximum number of matches to return.',
            },
          },
          'required': ['pattern'],
        },
      },
      // 图片工具（add-image-input）：无条件注册。模型能不能收图由 `input_modalities`
      // 决定 —— 关着的时候调用这个工具会**直接失败并说清原因**（见 `_executeTool`），
      // 比"工具不存在"更容易让模型改口。
      'read_image': const {
        'name': 'read_image',
        'description': 'Read a PNG/JPEG/GIF/WebP image file inside the workspace '
            'and return the image itself so you can look at it. Large images are '
            'downscaled by the provider automatically; do not install image '
            'libraries or create thumbnails to inspect an image. The result also '
            'names the file path, media type, pixel size and byte size.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Path to the image file relative to the workspace root.',
            },
          },
          'required': ['path'],
        },
      },
      // Command tool (add-command-tool): 无条件可用（与 read_file / grep_file 一样，
      // 不挂在搜索服务或浏览器栈的可用性判断下）。命令**真的在本机执行** —— 用
      // 用户自己的权限跑，能改动工作区里的文件，没有沙箱；说明文字里必须写明这一点。
      'run_command': const {
        'name': 'run_command',
        'description': 'Run one PowerShell command on this machine and get its '
            'exit code, stdout and stderr. The command really runs with the '
            "user's own permissions and can modify files under the workspace; "
            'there is no sandbox and it cannot be approved or undone after the '
            'fact. Dialect is PowerShell: use native paths (C:\\...) and read '
            'environment variables with \$env:NAME. Each call is a fresh '
            'process — pass workdir instead of using cd. A non-zero exit code '
            'is NOT a tool failure: it is reported in the result so you can read '
            'it. The full output is always written to a spill file first; when it '
            'is long, you get a head+tail preview (1000 characters each by '
            'default) plus the file path as `ref` — read any byte range back with '
            'the read_spill tool.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'command': {
              'type': 'string',
              'description': 'The PowerShell command to run.',
            },
            'workdir': {
              'type': 'string',
              'description': 'Working directory for this command. Defaults to the '
                  'workspace; a relative path is resolved against it. A path '
                  'outside the workspace is refused.',
            },
            'timeout_ms': {
              'type': 'integer',
              'minimum': 1,
              'description': 'Timeout in milliseconds for this command. Defaults '
                  'to 120000 (2 minutes) and is capped at 600000 (10 minutes).',
            },
          },
          'required': ['command'],
        },
      },
      // Spill 读回（spill-large-tool-output）：长输出被截成头尾预览后，模型用这条
      // 按字节把中间段取回来。只认 spill 根目录里的引用（C++ 侧校验），不是通用
      // 文件读取器 —— 读文件请用 read_file。
      'read_spill': const {
        'name': 'read_spill',
        'description': 'Read a byte range back out of a spill file that a previous '
            'tool result pointed at (the `ref` field). Use it when a tool result '
            'says bytes were omitted. Only files under the app spill directory are '
            'readable; anything else is refused. Offsets and limits are BYTES, not '
            'characters — a range that cuts a multi-byte character in half is '
            'refused instead of returning half a character.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'ref': {
              'type': 'string',
              'description': 'The `ref` reported by the tool result (the spill '
                  'file path).',
            },
            'offset': {
              'type': 'integer',
              'minimum': 0,
              'description': 'Byte offset to start at. Defaults to 0.',
            },
            'limit': {
              'type': 'integer',
              'minimum': 1,
              'description': 'How many bytes to return. Defaults to twice the '
                  'configured preview length (2000 bytes by default).',
            },
          },
          'required': ['ref'],
        },
      },
      // 一次性子 Agent（add-spawn-subagent-tool）：同步等待子 Agent 整轮结束，
      // 只把最终结论作为工具结果送回父对话。子 Agent 看不到父对话，第一版也不能
      // 再嵌套创建下一层；这些限制必须写在说明里，模型才知道任务要自带背景。
      'spawn_subagent': const {
        'name': 'spawn_subagent',
        'description': 'Create a one-shot sub-agent with its own context, message '
            'history and metering; give it one complete task and wait for its final '
            'answer. The sub-agent CANNOT see this conversation, so put every '
            'necessary background detail and file path into `task`. It inherits the '
            'current workspace. Only its final answer comes back to you: its '
            'intermediate messages, thinking and tool output stay in its own '
            'history and are never added to this conversation. Ask it for a '
            'self-contained conclusion; do not rely on its read_spill references '
            '(its context is destroyed when it finishes) — anything that must '
            'persist should be written into the workspace. Omit `agent_type` to use '
            "this agent's own template. The call runs synchronously: it waits until "
            'the sub-agent finishes, so it does not run in parallel with other tool '
            'calls. A sub-agent cannot create another sub-agent.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'task': {
              'type': 'string',
              'description': 'The complete, self-contained task for the sub-agent. '
                  'Include the background it needs; it cannot see this conversation.',
            },
            'agent_type': {
              'type': 'string',
              'description': 'Optional Agent template name for the sub-agent. '
                  "Defaults to this agent's own template.",
            },
          },
          'required': ['task'],
        },
      },
      // 技能加载工具（change `add-skill-mechanism` 任务 3.2）：定义常量住在技能
      // 服务侧（`skill_catalog_service.dart`），这里在**同步段**与 `spawn_subagent`
      // 同处注册进目录 —— 这样模板显式列 `load_skill` 时 `resolve` 找得到，不会抛
      // `UnknownToolsException`。它**不**进 `ToolCatalog.kBaseToolNames`（保持 11 项）、
      // 不写进任何模板的工具清单、不改动任何用户配置；每轮装配由
      // `Agent.toolDefinitions` 无条件追加（design D4/D9）。
      kLoadSkillToolName: kLoadSkillToolDefinition,
    };

    // Assign the base tool set SYNCHRONOUSLY before the browser-availability await
    // so _toolDefs is never uninitialized (a message sent while the probe is still
    // pending reads a valid, if browser-less, tool set).
    ToolCatalog.instance.seed(base);

    // Browser tool (add-browser-tool): declare OUTSIDE the hasProviders gate so a
    // browser-runtime probe decides it, independent of search-provider availability
    // (design Decision 6 / spec "Graceful degradation / declaration gating"). When
    // the browser stack (Playwright + Edge/Chromium) is unavailable, the tools are
    // simply absent — never a silent placeholder. Mutates _toolDefs (== base ref).
    bool browserAvailable = false;
    try {
      final probeJson = await sidecar.browserAvailable();
      final parsed = jsonDecode(probeJson);
      if (parsed is Map) browserAvailable = parsed['available'] == true;
    } catch (e) {
      debugPrint('[AliasAgent] browser_available probe failed: $e');
    }
    if (browserAvailable) {
      base['browser_navigate'] = const {
        'name': 'browser_navigate',
        'description': 'Navigate a user-visible browser to a URL and return a text '
            'snapshot of the page. Drives a persistent headed browser session; '
            'multi-step (navigate/click/type/snapshot) share one session.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'url': {
              'type': 'string',
              'description': 'The URL to navigate to.',
            },
          },
          'required': ['url'],
        },
      };
      base['browser_click'] = const {
        'name': 'browser_click',
        'description': 'Click an element in the browser and return a text snapshot '
            'of the page.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'selector': {
              'type': 'string',
              'description': 'CSS selector of the element to click.',
            },
          },
          'required': ['selector'],
        },
      };
      base['browser_type'] = const {
        'name': 'browser_type',
        'description': 'Enter text into a field in the browser and return a text '
            'snapshot of the page.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'selector': {
              'type': 'string',
              'description': 'CSS selector of the field.',
            },
            'text': {
              'type': 'string',
              'description': 'The text to enter.',
            },
          },
          'required': ['selector', 'text'],
        },
      };
      base['browser_snapshot'] = const {
        'name': 'browser_snapshot',
        'description': 'Return a fresh text snapshot of the current browser page '
            '(re-read live, not a cached copy).',
        'input_schema': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      };
    }

    // Initialize search infra from config (task 8.2)
    try {
      final searchConfig = config.search;
      // 把**会话模型当前 provider 的地址与密钥**一起交下去（add-deepseek-web-search
      // 任务 3.4）。C++ 侧只在"地址确实指向 DeepSeek 且 search.deepseek 段存在"
      // 时才允许回落到它，`search.deepseek` 里自己写了的以自己写的为准；地址不是
      // DeepSeek 时那一侧直接报告不可用、不发任何请求（安全边界，见 design 决策 D2）。
      // 字段名：`session_model.{base_url,api_key}`。
      final mergedSearch = <String, dynamic>{
        if (searchConfig != null) ...searchConfig,
      };
      final activeAgent = templates.lookup('general');
      final sessionProvider =
          activeAgent == null ? null : providerResolver()?.resolve(activeAgent.provider);
      if (sessionProvider != null) {
        mergedSearch['session_model'] = <String, dynamic>{
          'base_url': sessionProvider.baseUrl.isNotEmpty
              ? sessionProvider.baseUrl
              : 'https://api.anthropic.com',
          'api_key': sessionProvider.apiKey,
        };
      }
      final searchJson = mergedSearch.isEmpty ? '{}' : jsonEncode(mergedSearch);
      sidecar.ensureSearchInfra(searchJson);
    } catch (e) {
      debugPrint('[AliasAgent] Search infra init failed: $e');
    }

    // Query configured providers (task 8.6)
    List<dynamic> providers = [];
    try {
      final providersJson = sidecar.getSearchProviders();
      final parsed = jsonDecode(providersJson);
      if (parsed is List) providers = parsed;
    } catch (e) {
      debugPrint('[AliasAgent] get_search_providers failed: $e');
    }

    final hasProviders = providers.isNotEmpty;

    // Conditionally add web_search (task 8.3, 8.6)
    if (hasProviders) {
      final providerNames = providers.map((p) => (p as Map<String, dynamic>)['name'] as String).toList();
      final providerList = providerNames.join(', ');
      final descriptions = StringBuffer('Search the web using available providers.\n\nAvailable: ');
      for (final p in providers) {
        final name = (p as Map<String, dynamic>)['name'] as String;
        final desc = p['description'] as String? ?? '';
        descriptions.write('\n- $name: $desc');
      }

      base['web_search'] = {
        'name': 'web_search',
        'description': descriptions.toString(),
        'input_schema': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'The search query.',
            },
            'providers': {
              'type': 'array',
              'items': {'type': 'string', 'enum': providerNames},
              'default': <String>[],
              'description': 'Which search providers to use. Empty = use all configured providers ($providerList).',
            },
            'depth': {
              'type': 'string',
              'enum': ['basic', 'deep'],
              'default': 'basic',
              'description': 'basic = snippets only (fast). deep = full page extraction (higher latency).',
            },
            'max_results': {
              'type': 'integer',
              'minimum': 1,
              'maximum': 10,
              'default': 5,
            },
          },
          'required': ['query'],
        },
      };

      // Task 8.4: Add web_fetch tool definition
      base['web_fetch'] = const {
        'name': 'web_fetch',
        'description': 'Fetch a web page and return clean, structured content. '
            'Use this to get full article text when search snippets are insufficient.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'url': {
              'type': 'string',
              'description': 'The URL of the web page to fetch.',
            },
          },
          'required': ['url'],
        },
      };
    }

    ToolCatalog.instance.seed(base);


    // 技能目录扫描（change `add-skill-mechanism` 任务 6.2）：在调用方置“工具就绪”前
    // 完成一次（纯本地小目录读，延后可忽略）。约定：
    //   - 没有技能目录 = 首次用户的默认状态 ⇒ 静默（零提示、零日志噪音）；
    //   - 有技能但校验失败 / 技能目录整体不可读 ⇒ 逐条写日志 **并** 汇总成一句上屏
    //     提示（复用 `toolMigrationNotice` 同形的字符串提示通道，不新建任何界面）；
    //   - 扫描自身抛异常也不许挡住启动：给一条可见提示后继续初始化工具。
    final noticeLines = <String>[];
    String? failureNotice;
    try {
      await SkillCatalogService.instance.scan();
      noticeLines.addAll(SkillCatalogService.instance.noticeLines);
      failureNotice = SkillCatalogService.instance.failureNotice;
    } catch (e) {
      final line = '技能目录扫描失败：$e';
      noticeLines.add(line);
      failureNotice = line;
    }

    return ToolBootstrapResult(
      browserAvailable: browserAvailable,
      searchProviderNames: <String>[
        for (final provider in providers)
          if (provider is Map && provider['name'] is String)
            provider['name'] as String,
      ],
      skillNoticeLines: List<String>.unmodifiable(noticeLines),
      skillFailureNotice: failureNotice,
    );
}