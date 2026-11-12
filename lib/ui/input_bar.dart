import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/skills/skill_catalog_service.dart';
import 'slash_completion.dart';

/// `Ctrl+V` 在输入行里的意图：先试贴图，没贴到再退回文本粘贴。
///
/// 单独定义一个 Intent 才能用 `Actions` 覆盖默认的 `PasteTextIntent`
/// （默认那条把 Ctrl+V 直接当"粘贴文本"，不走我们这条判断）。
class _PasteImageShortcutIntent extends Intent {
  const _PasteImageShortcutIntent();
}

/// 输入行：输入框 +（可选的）附件 + 发送按钮。
///
/// **为什么它是公开且在 `lib/` 下**：它原来叫 `_InputBar`，是 `lib/ui/chat_area.dart`
/// 里的私有类。2026-10-18 用户把上下文占用环从顶部工具栏挪到"右下角、发送按钮附近"，
/// 而「真实上下文」那一屏里没有输入区 —— 环要两屏都在，输入行就必须提到两屏共用的位置
/// 并由 `lib/main.dart` 直接构造。私有类另一个库引用不到，所以这里改成公开类、单独成文件。
///
/// 附件（`accessory`）就是给占用环留的位置：它排在输入框与发送按钮之间，
/// 与发送按钮同一行、位于其左侧。
class InputBar extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSubmit;

  /// 工具清单是否已就绪。未就绪时发送按钮禁用并给出可见原因
  /// （不是静默排队 —— 排队在用户看来还是"发出去了"）。
  final bool toolsReady;

  /// 该会话正在切换 Agent 模板（或正在删除）。
  ///
  /// 切换中旧 Agent 对象正在退役、新实例还没建好：按钮、回车与提交入口都必须服从
  /// 这个状态，不能只禁用按钮（回车与直接调用提交入口是另外两条路径）。
  final bool switching;

  /// 排在发送按钮**左侧**的附件（今天就是上下文占用环）。
  final Widget? accessory;

  /// 已经贴进来、还没发出去的图片路径（add-image-input）。
  ///
  /// 它只参与**一条**判断：输入框没有文字时，还能不能提交。有它就能（贴一张图
  /// 就是这个用法），没它就不行。真正的缩略图渲染与移除按钮由调用方给。
  final List<String> pendingImagePaths;

  /// 点「粘贴图片」按钮时调用（读剪贴板）。传 null 就不显示这个按钮。
  final VoidCallback? onPasteImage;

  /// 点某张待发缩略图上的删除按钮时调用，参数是它在 [pendingImagePaths] 里的下标。
  final void Function(int index)? onRemoveImage;

  /// `Ctrl+V` 真正的"贴图"动作：调用方去读剪贴板，返回**是否贴到了一张图**。
  ///
  /// 返回 false 时输入行会退回普通文本粘贴（把剪贴板文本插入光标处、替换选区）——
  /// 也就是说这个快捷键不会因为加了贴图而失效。传 null 表示不接管 `Ctrl+V`。
  final Future<bool> Function()? onPasteShortcut;

  const InputBar({
    super.key,
    required this.controller,
    required this.onSubmit,
    this.toolsReady = true,
    this.switching = false,
    this.accessory,
    this.pendingImagePaths = const [],
    this.onPasteImage,
    this.onRemoveImage,
    this.onPasteShortcut,
  });

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  final _focusNode = FocusNode();

  // ---------------------------------------------------------------------------
  // 技能名补全（change `slash-command-completion`，design D1～D6）
  //
  // 接线点就在这里：Flutter 的按键分发从 primary focus（TextField 的内部节点）沿
  // 祖先上溯，本类这个 `Focus(onKeyEvent: _onKey)` 比 WidgetsApp 默认的 Shortcuts
  // 更近，所以 Tab（默认是 NextFocusIntent 焦点遍历）能在这里先被截住。
  // ---------------------------------------------------------------------------

  /// 面板的锚：`CompositedTransformTarget` 挂在输入框上（`build` 里），
  /// `CompositedTransformFollower` 在 Overlay 里贴住它。
  final _link = LayerLink();

  /// 量输入框宽度用的 key（面板宽度对齐输入框）。挂在 Target 上，量的就是输入框。
  final _fieldKey = GlobalKey();

  /// 面板的浮层条目；null = 当前没有面板（也是按键分支问的"面板可见吗"）。
  OverlayEntry? _panelEntry;

  /// 浮层从哪儿来（`didChangeDependencies` 里取一次；没有 Overlay 就没有浮层可放）。
  OverlayState? _overlay;

  /// 当前候选：每次重筛**现读** `activeSkillNames`（design D6：不缓存、不监听、
  /// 不触发扫描 —— 读到的就是最近一次 scan 的快照）。
  List<String> _candidates = const <String>[];

  /// 生效技能集合是否为空 —— 只决定提示行用哪一句文案（空目录 / 无匹配）。
  bool _catalogEmpty = true;

  /// 高亮行下标（[_candidates] 为空时无意义）。
  int _highlight = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onEditingChanged);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _overlay = Overlay.maybeOf(context);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onEditingChanged);
    _focusNode.removeListener(_onFocusChanged);
    _hidePanel();
    _focusNode.dispose();
    super.dispose();
  }

  /// 文本或光标变了：重算面板（打出空白 / 删掉 `/` / 光标离开首段都走这里）。
  void _onEditingChanged() {
    _refreshPanel();
  }

  /// 失焦即关（design D1 的硬规则）：面板是纯建议层，从不抢焦点。
  void _onFocusChanged() {
    if (!_focusNode.hasFocus) {
      _hidePanel();
      return;
    }
    _refreshPanel();
  }

  /// 重算"该不该有面板、有哪几条、哪条高亮"，据此插入 / 刷新 / 拆掉浮层。
  ///
  /// 显示条件 = design D1 四条同时成立：
  ///   ① 文本以 `/` 开头；
  ///   ② 有焦点；
  ///   ③ 光标在首段之内且是塌缩选区（`1 <= baseOffset <= 首段末`，非法/越界 ⇒ 不显示）；
  ///   ④ 首段之后没有任何文本。
  ///
  /// 任何一条不再成立就关闭 —— 这也是"接受补全不会吃掉正文"的双保险（D4）。
  void _refreshPanel() {
    if (!mounted) return;
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    final firstSegmentEnd = slashFirstSegmentEnd(text);
    final shouldShow = _focusNode.hasFocus &&
        text.isNotEmpty &&
        text.startsWith('/') &&
        selection.isValid &&
        selection.isCollapsed &&
        selection.baseOffset >= 1 &&
        selection.baseOffset <= firstSegmentEnd &&
        firstSegmentEnd == text.length;
    if (!shouldShow) {
      _hidePanel();
      return;
    }

    final names = SkillCatalogService.instance.activeSkillNames;
    final candidates = filterSkillNames(text.substring(1), names);
    final highlight =
        candidates.isEmpty ? 0 : _highlight.clamp(0, candidates.length - 1);
    final changed = !_sameNames(candidates, _candidates) ||
        _catalogEmpty != names.isEmpty ||
        highlight != _highlight;
    _candidates = candidates;
    _catalogEmpty = names.isEmpty;
    _highlight = highlight;
    final entry = _panelEntry;
    if (entry == null) {
      _insertPanel();
    } else if (changed) {
      entry.markNeedsBuild();
    }
  }

  /// 把面板插进浮层。高度上限用**实测**的输入框上方空间（不是发明的常数），
  /// 宽度对齐输入框，位置由 `buildSlashCompletionOverlay` 里那条 LayerLink 决定。
  void _insertPanel() {
    final overlay = _overlay;
    if (overlay == null) return; // 没有 Overlay 就不显示，也不拦键（行为不变）
    final entry = OverlayEntry(builder: _buildPanel);
    _panelEntry = entry;
    overlay.insert(entry);
  }

  Widget _buildPanel(BuildContext context) {
    final box = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    final width = box?.size.width ?? 0;
    // 面板浮在输入框**上方** ⇒ 可用高度 = 输入框顶边到窗口顶边的距离（实测）。
    final top = box == null ? 0.0 : box.localToGlobal(Offset.zero).dy;
    return buildSlashCompletionOverlay(
      link: _link,
      width: width,
      maxHeight: top - kSlashCompletionGap,
      candidates: _candidates,
      highlightIndex: _highlight,
      emptyCatalog: _catalogEmpty,
      onAccept: _acceptCandidate,
    );
  }

  /// 拆掉面板。连候选项与高亮一起清空 —— 关闭之后这些值没有任何意义。
  void _hidePanel() {
    _candidates = const <String>[];
    _highlight = 0;
    final entry = _panelEntry;
    _panelEntry = null;
    if (entry == null) return;
    entry.remove();
    entry.dispose();
  }

  /// 接受第 [index] 条候选（键盘 Tab/回车与鼠标点击共用这一条路，design D4）。
  ///
  /// 只做两件事：把首段替换成 `/完整技能名␣`、把光标放到插入文本之后。
  /// **不发送**（发送仍由用户显式进行）、不碰任何其它状态；其后文本原样保留
  /// （design D1④ 已经让"首段后有文本"进不来，所以今天恒为空串）。
  void _acceptCandidate(int index) {
    if (index < 0 || index >= _candidates.length) return;
    final insertion = '/${_candidates[index]} ';
    final text = widget.controller.text;
    final tail = text.substring(slashFirstSegmentEnd(text));
    widget.controller.value = TextEditingValue(
      text: '$insertion$tail',
      selection: TextSelection.collapsed(offset: insertion.length),
    );
    _hidePanel();
  }

  /// ↑/↓ 移动高亮（到头回绕，手柄式菜单的常见行为）。
  void _moveHighlight(int delta) {
    if (_candidates.isEmpty) return;
    _highlight = (_highlight + delta) % _candidates.length;
    _panelEntry?.markNeedsBuild();
  }

  /// 两个候选表是否逐项相同（只在"内容真变了"时才让浮层重建）。
  static bool _sameNames(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // 补全面板**先**截键（design D2）：这条分支必须在下面既有的 Enter→发送之前。
    // 前置条件是"面板可见且存在高亮行"：零候选（无匹配 / 空目录）一律不拦 ——
    // Enter 仍发送、Tab 仍走默认焦点遍历，面板只是提示层，不吞键。
    if (event is KeyDownEvent && _panelEntry != null && _candidates.isNotEmpty) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.tab) {
        if (HardwareKeyboard.instance.isShiftPressed) {
          _hidePanel(); // Shift+Tab = Esc：关闭，不改写
        } else {
          _acceptCandidate(_highlight); // Tab = 接受高亮行
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter) {
        if (HardwareKeyboard.instance.isShiftPressed) {
          return KeyEventResult.ignored; // Shift+Enter 仍是换行（既有行为）
        }
        // 回车改道语义（design D4）：面板可见且有高亮行时，回车是"接受补全"，
        // 不是发送。想直接发送：接受后（或 Esc 关闭后）再按一次回车。
        _acceptCandidate(_highlight);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _moveHighlight(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        _moveHighlight(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        _hidePanel();
        return KeyEventResult.handled;
      }
    }

    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        return KeyEventResult.ignored; // let TextField handle newline
      }
      // 切换中回车也不能发送：只禁用按钮挡不住这条路径。
      if (widget.switching) return KeyEventResult.handled;
      _submit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 空内容（含只有空白）不提交 —— **这条守卫住在这里**，因为输入框归它管；
  /// 这样"空输入点发送不发出去"能由 `InputBar` 自己的用例验证，而不是只靠调用方自觉。
  ///
  /// 但"空"只看文字已经不够（add-image-input）：贴了一张图、一个字没写，这条消息
  /// 是**合法**的，必须发得出去。所以判据是「没有文字**且**没有待发图片」。
  void _submit() {
    if (widget.switching) return;
    final hasText = widget.controller.text.trim().isNotEmpty;
    final hasImages = widget.pendingImagePaths.isNotEmpty;
    if (!hasText && !hasImages) return;
    widget.onSubmit();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 待发图片条：只有真的贴了图才占位，平时一点高度都不占。
          if (widget.pendingImagePaths.isNotEmpty) _buildPendingStrip(context),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                // 补全面板的锚：`CompositedTransformTarget` 只包输入框（不包整个
                // 输入行）—— 面板宽度对齐的就是输入框，design D5。
                child: CompositedTransformTarget(
                  key: _fieldKey,
                  link: _link,
                  child: _shortcutLayer(
                    Focus(
                      onKeyEvent: _onKey,
                      child: TextField(
                        controller: widget.controller,
                        focusNode: _focusNode,
                        maxLines: 5,
                        minLines: 1,
                        textInputAction: TextInputAction.newline,
                        decoration: const InputDecoration(
                          hintText: 'Type a message...',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // 环与发送按钮在这一小组里**居中对齐**：输入行整体是底对齐（`end`），而发送
              // 按钮是个比图标高的盒子 —— 直接并排放的话环会看起来偏低 14 像素（实测过）。
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (widget.onPasteImage != null) ...[
                    IconButton(
                      onPressed: widget.toolsReady ? widget.onPasteImage : null,
                      icon: const Icon(Icons.add_photo_alternate_outlined, size: 20),
                      tooltip: '粘贴图片',
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (widget.accessory != null) ...[
                    widget.accessory!,
                    const SizedBox(width: 6),
                  ],
                  IconButton.filled(
                    onPressed:
                        widget.toolsReady && !widget.switching ? _submit : null,
                    icon: const Icon(Icons.send, size: 20),
                    tooltip: widget.switching
                        ? '正在切换 Agent 模板…'
                        : (widget.toolsReady ? 'Send' : '正在准备工具…'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 把 `Ctrl+V` 映射到"先试贴图"。只有在调用方真的提供了 [InputBar.onPasteShortcut]
  /// 时才挂这一层，否则 Ctrl+V 保持按编辑器默认行为走。
  ///
  /// 为什么要用 `Shortcuts`+`Actions` 而不是 `Focus.onKeyEvent`：文本编辑的默认快捷键
  /// 是 `WidgetsApp` 那一层注册的，从焦点节点往上找，先命中谁由距离决定。放在输入框正上方
  /// 这一层才稳定压过默认的"粘贴文本"。
  Widget _shortcutLayer(Widget child) {
    if (widget.onPasteShortcut == null) return child;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyV, control: true):
            _PasteImageShortcutIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _PasteImageShortcutIntent: CallbackAction<_PasteImageShortcutIntent>(
            onInvoke: (_) {
              _pasteViaShortcut();
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }

  /// `Ctrl+V` 的实际行为：先让调用方去贴图；**没贴到就退回普通文本粘贴**，
  /// 所以这个快捷键不会因为加了贴图功能而失效。
  Future<void> _pasteViaShortcut() async {
    final shortcut = widget.onPasteShortcut;
    if (shortcut != null) {
      final attached = await shortcut();
      if (attached) return;
    }
    await _insertClipboardText();
  }

  /// 把剪贴板文本插入到光标处（有选区就替换选区）—— 与编辑器默认粘贴等价。
  Future<void> _insertClipboardText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    final current = widget.controller.text;
    final selection = widget.controller.selection;
    final valid = selection.isValid && selection.start >= 0 && selection.end >= 0;
    final start = valid ? selection.start : current.length;
    final end = valid ? selection.end : current.length;
    widget.controller.value = TextEditingValue(
      text: current.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  /// 待发图片条：每张一个缩略图 + 右上角删除按钮。
  ///
  /// 缩略图 48×48 是**布局尺寸**（不是上限/阈值）；图片读不出来（文件被删、路径
  /// 失效）时退回一个图标，不让整行抛异常。
  Widget _buildPendingStrip(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < widget.pendingImagePaths.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.file(
                        File(widget.pendingImagePaths[i]),
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          width: 48,
                          height: 48,
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(Icons.broken_image_outlined,
                              size: 24, color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                    if (widget.onRemoveImage != null)
                      Positioned(
                        top: -6,
                        right: -6,
                        child: IconButton(
                          onPressed: () => widget.onRemoveImage!(i),
                          icon: const Icon(Icons.close, size: 14),
                          tooltip: '移除这张图',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(),
                          padding: const EdgeInsets.all(2),
                          style: IconButton.styleFrom(
                            backgroundColor: theme.colorScheme.surfaceContainerHighest,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
