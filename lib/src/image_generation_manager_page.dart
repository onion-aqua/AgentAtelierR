import 'dart:io';

import 'package:flutter/material.dart';

import 'app_localization.dart';
import 'glass_ui.dart';
import 'image_generation_store.dart';

/// Persistent history and status page for image-generation tasks.
class ImageGenerationManagerPage extends StatefulWidget {
  const ImageGenerationManagerPage({
    super.key,
    required this.store,
    this.onRetry,
    this.onDelete,
    this.onClose,
    this.language = AppLanguage.chinese,
    this.liquidGlass = false,
  });

  final ImageGenerationStore store;
  final Future<void> Function(ImageGenerationTask task)? onRetry;
  final Future<void> Function(ImageGenerationTask task)? onDelete;
  final VoidCallback? onClose;
  final AppLanguage language;
  final bool liquidGlass;

  @override
  State<ImageGenerationManagerPage> createState() =>
      _ImageGenerationManagerPageState();
}

class _ImageGenerationManagerPageState
    extends State<ImageGenerationManagerPage> {
  final Set<String> _busyTaskIds = <String>{};
  bool _loading = true;
  String? _pageError;

  AppLanguage get _language => widget.language;
  bool get _liquidGlass =>
      GlassStyleScope.resolve(context, fallback: widget.liquidGlass);

  String _t(String zh, String en, String ja) => _language.text(zh, en, ja);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ImageGenerationManagerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      _busyTaskIds.clear();
      _loading = true;
      _pageError = null;
      _load();
    }
  }

  Future<void> _load() async {
    final store = widget.store;
    try {
      await store.load();
      await store.markAllCompletedSeen();
      if (!mounted || store != widget.store) return;
      setState(() {
        _loading = false;
        _pageError = null;
      });
    } on Object catch (error) {
      if (!mounted || store != widget.store) return;
      setState(() {
        _loading = false;
        _pageError = _t(
          '无法读取生图记录：$error',
          'Could not load image history: $error',
          '画像生成履歴を読み込めませんでした：$error',
        );
      });
    }
  }

  Future<void> _retry(ImageGenerationTask task) async {
    if (_busyTaskIds.contains(task.id)) return;
    setState(() {
      _busyTaskIds.add(task.id);
      _pageError = null;
    });
    try {
      if (task.outcomeUnknown) {
        final confirmed = await _confirmUnknownOutcomeRetry(task);
        if (confirmed != true || !mounted) return;
        await widget.store.retry(task.id, allowUnknownOutcome: true);
      }
      final callback = widget.onRetry;
      if (callback == null) {
        if (!task.outcomeUnknown) await widget.store.retry(task.id);
      } else {
        await callback(widget.store.taskById(task.id) ?? task);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _pageError = _t(
            '无法重新生成：$error',
            'Could not retry: $error',
            '再生成を開始できませんでした：$error',
          );
        });
      }
    } finally {
      if (mounted) setState(() => _busyTaskIds.remove(task.id));
    }
  }

  Future<bool?> _confirmUnknownOutcomeRetry(ImageGenerationTask task) =>
      showDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (dialogContext) => AlertDialog(
          key: const ValueKey('image-generation-unknown-retry-dialog'),
          backgroundColor: Theme.of(dialogContext).colorScheme.surface,
          surfaceTintColor: Colors.transparent,
          title: Text(_t('生成结果未知', 'Generation result unknown', '生成結果が不明です')),
          content: Text(
            _t(
              '上一次请求可能已在服务端生成或计费。继续操作可能重复计费，将重新提交生成。',
              'The previous request may already have completed or been billed. Continuing may charge you again and will submit a new generation.',
              '前回のリクエストは完了または課金済みの可能性があります。続行すると重複課金される可能性があり、新しく生成を送信します。',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(_t('取消', 'Cancel', 'キャンセル')),
            ),
            FilledButton(
              key: ValueKey('image-generation-confirm-unknown-${task.id}'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(_t('确认并重新提交', 'Submit again', '確認して再送信')),
            ),
          ],
        ),
      );

  Future<void> _delete(ImageGenerationTask task) async {
    if (_busyTaskIds.contains(task.id) || task.isActive) return;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Theme.of(dialogContext).colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        title: Text(_t('删除这条生图记录？', 'Delete this image?', 'この画像を削除しますか？')),
        content: Text(
          task.hasImage
              ? _t(
                  '图片文件和对应的生图记录都会从本机删除。',
                  'The local image file and its history entry will be deleted.',
                  '端末内の画像ファイルと履歴を削除します。',
                )
              : _t(
                  '这条任务记录将从本机删除。',
                  'This task entry will be deleted from this device.',
                  'このタスク履歴を端末から削除します。',
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(_t('取消', 'Cancel', 'キャンセル')),
          ),
          FilledButton(
            key: const ValueKey('image-generation-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(_t('删除', 'Delete', '削除')),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() {
      _busyTaskIds.add(task.id);
      _pageError = null;
    });
    try {
      final callback = widget.onDelete;
      if (callback == null) {
        await widget.store.delete(task.id);
      } else {
        await callback(task);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _pageError = _t(
            '删除失败：$error',
            'Could not delete: $error',
            '削除できませんでした：$error',
          );
        });
      }
    } finally {
      if (mounted) setState(() => _busyTaskIds.remove(task.id));
    }
  }

  Future<void> _showImage(ImageGenerationTask task) async {
    final path = task.localPath;
    if (!task.hasImage || path == null) return;
    await widget.store.markSeen(task.id);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      useRootNavigator: false,
      barrierColor: Colors.black87,
      builder: (dialogContext) => Dialog.fullscreen(
        key: ValueKey('image-generation-viewer-${task.id}'),
        backgroundColor: Colors.black,
        child: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: .75,
                  maxScale: 5,
                  child: Center(
                    child: Image.file(
                      File(path),
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) =>
                          _brokenImage(
                            context,
                            foregroundColor: Colors.white70,
                          ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 6,
                left: 6,
                child: IconButton.filledTonal(
                  key: const ValueKey('image-generation-viewer-close'),
                  tooltip: _t('关闭', 'Close', '閉じる'),
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
              Positioned(
                left: 18,
                right: 18,
                bottom: 16,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .64),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      task.prompt,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.store,
      builder: (context, _) {
        final colors = Theme.of(context).colorScheme;
        final tasks = widget.store.tasks;
        return PopScope(
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) widget.onClose?.call();
          },
          child: GlassPageSurface(
            liquidGlass: _liquidGlass,
            child: Scaffold(
              key: const ValueKey('image-generation-manager-page'),
              backgroundColor: Colors.transparent,
              appBar: AppBar(
                backgroundColor: glassPageHeaderColor(context),
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0,
                leading: IconButton(
                  key: const ValueKey('image-generation-manager-back'),
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                title: Text(
                  _t('生图管理', 'Generated images', '画像生成管理'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                actions: [
                  if (widget.store.activeCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Center(
                        child: Semantics(
                          label: _t(
                            '${widget.store.activeCount} 个任务生成中',
                            '${widget.store.activeCount} task(s) generating',
                            '${widget.store.activeCount} 件を生成中',
                          ),
                          child: SizedBox.square(
                            dimension: 22,
                            child: CircularProgressIndicator(
                              key: const ValueKey(
                                'image-generation-manager-progress',
                              ),
                              strokeWidth: 2.4,
                              color: colors.primary,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              body: SafeArea(
                top: false,
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(
                          key: ValueKey('image-generation-manager-loading'),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: CustomScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          slivers: [
                            if (_pageError != null)
                              SliverToBoxAdapter(child: _errorBanner(colors)),
                            if (tasks.isEmpty)
                              SliverFillRemaining(
                                hasScrollBody: false,
                                child: _emptyState(colors),
                              )
                            else ...[
                              SliverToBoxAdapter(
                                child: _summary(tasks, colors),
                              ),
                              SliverPadding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  12,
                                  24,
                                ),
                                sliver: SliverList.separated(
                                  itemCount: tasks.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(height: 10),
                                  itemBuilder: (context, index) =>
                                      _taskCard(tasks[index], colors),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _summary(List<ImageGenerationTask> tasks, ColorScheme colors) {
    final completed = tasks
        .where((task) => task.status == ImageGenerationTaskStatus.completed)
        .length;
    final failed = tasks
        .where(
          (task) =>
              task.status == ImageGenerationTaskStatus.failed &&
              !task.outcomeUnknown,
        )
        .length;
    final unknown = tasks
        .where(
          (task) =>
              task.status == ImageGenerationTaskStatus.failed &&
              task.outcomeUnknown,
        )
        .length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          _summaryChip(
            Icons.collections_outlined,
            _t(
              '${tasks.length} 条记录',
              '${tasks.length} tasks',
              '${tasks.length} 件',
            ),
            colors.primary,
          ),
          if (widget.store.activeCount > 0)
            _summaryChip(
              Icons.autorenew_rounded,
              _t(
                '${widget.store.activeCount} 个生成中',
                '${widget.store.activeCount} active',
                '${widget.store.activeCount} 件生成中',
              ),
              colors.tertiary,
            ),
          if (completed > 0)
            _summaryChip(
              Icons.check_circle_outline_rounded,
              _t('$completed 个已完成', '$completed completed', '$completed 件完了'),
              colors.primary,
            ),
          if (failed > 0)
            _summaryChip(
              Icons.error_outline_rounded,
              _t('$failed 个失败', '$failed failed', '$failed 件失敗'),
              colors.error,
            ),
          if (unknown > 0)
            _summaryChip(
              Icons.help_outline_rounded,
              _t('$unknown 个结果未知', '$unknown unknown', '$unknown 件結果不明'),
              colors.tertiary,
            ),
        ],
      ),
    );
  }

  Widget _summaryChip(IconData icon, String label, Color color) => Chip(
    visualDensity: VisualDensity.compact,
    avatar: Icon(icon, size: 17, color: color),
    label: Text(label),
  );

  Widget _taskCard(ImageGenerationTask task, ColorScheme colors) {
    final busy = _busyTaskIds.contains(task.id);
    final thumbnail = SizedBox(
      width: 116,
      height: 116,
      child: _thumbnail(task, colors),
    );
    final details = Expanded(child: _taskDetails(task, colors, busy));
    return GlassContentCard(
      liquidGlass: _liquidGlass,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 390) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(alignment: Alignment.centerLeft, child: thumbnail),
                  const SizedBox(height: 10),
                  _taskDetails(task, colors, busy),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [thumbnail, const SizedBox(width: 12), details],
            );
          },
        ),
      ),
    );
  }

  Widget _thumbnail(ImageGenerationTask task, ColorScheme colors) {
    final path = task.localPath;
    if (task.hasImage && path != null) {
      return Semantics(
        image: true,
        button: true,
        label: _t('查看生成图片', 'View generated image', '生成画像を表示'),
        child: Material(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('image-generation-preview-${task.id}'),
            onTap: () => _showImage(task),
            child: Image.file(
              File(path),
              fit: BoxFit.cover,
              cacheWidth: 480,
              errorBuilder: (context, error, stackTrace) =>
                  _brokenImage(context),
            ),
          ),
        ),
      );
    }
    final (icon, color) = task.outcomeUnknown
        ? (Icons.help_outline_rounded, colors.tertiary)
        : switch (task.status) {
            ImageGenerationTaskStatus.queued => (
              Icons.hourglass_top_rounded,
              colors.primary,
            ),
            ImageGenerationTaskStatus.generating => (
              Icons.auto_awesome_rounded,
              colors.tertiary,
            ),
            ImageGenerationTaskStatus.failed => (
              Icons.broken_image_outlined,
              colors.error,
            ),
            ImageGenerationTaskStatus.cancelled => (
              Icons.cancel_outlined,
              colors.onSurfaceVariant,
            ),
            ImageGenerationTaskStatus.completed => (
              Icons.image_not_supported_outlined,
              colors.error,
            ),
          };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(
        child: task.isActive
            ? Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox.square(
                    dimension: 48,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: color,
                    ),
                  ),
                  Icon(icon, color: color, size: 24),
                ],
              )
            : Icon(icon, color: color, size: 38),
      ),
    );
  }

  Widget _taskDetails(ImageGenerationTask task, ColorScheme colors, bool busy) {
    final canRetry =
        task.status == ImageGenerationTaskStatus.failed ||
        task.status == ImageGenerationTaskStatus.cancelled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _statusPill(task, colors),
            const Spacer(),
            Text(
              _formatTime(task.createdAt.toLocal()),
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SelectableText(
          task.prompt,
          maxLines: 4,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 7),
        Text(
          [
            if (task.model?.trim().isNotEmpty == true) task.model!.trim(),
            task.protocol,
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11),
        ),
        if (task.error?.trim().isNotEmpty == true) ...[
          const SizedBox(height: 6),
          Text(
            task.error!.trim(),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.error, fontSize: 12),
          ),
        ],
        if (task.outcomeUnknown) ...[
          const SizedBox(height: 6),
          Text(
            _t(
              '远端可能已经完成或计费；确认前不会重新提交。',
              'The provider may already have completed or billed this request. It will not be submitted again without confirmation.',
              'サービス側で完了または課金済みの可能性があります。確認なしでは再送信しません。',
            ),
            style: TextStyle(color: colors.tertiary, fontSize: 12),
          ),
        ],
        const SizedBox(height: 7),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            if (task.hasImage)
              TextButton.icon(
                key: ValueKey('image-generation-view-${task.id}'),
                onPressed: busy ? null : () => _showImage(task),
                icon: const Icon(Icons.open_in_full_rounded, size: 18),
                label: Text(_t('查看', 'View', '表示')),
              ),
            if (canRetry)
              TextButton.icon(
                key: ValueKey('image-generation-retry-${task.id}'),
                onPressed: busy ? null : () => _retry(task),
                icon: busy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 18),
                label: Text(_t('重试', 'Retry', '再試行')),
              ),
            TextButton.icon(
              key: ValueKey('image-generation-delete-${task.id}'),
              onPressed: busy || task.isActive ? null : () => _delete(task),
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: Text(_t('删除', 'Delete', '削除')),
            ),
          ],
        ),
      ],
    );
  }

  Widget _statusPill(ImageGenerationTask task, ColorScheme colors) {
    final (label, icon, color) = task.outcomeUnknown
        ? (
            _t('结果未知', 'Result unknown', '結果不明'),
            Icons.help_rounded,
            colors.tertiary,
          )
        : switch (task.status) {
            ImageGenerationTaskStatus.queued => (
              _t('等待中', 'Queued', '待機中'),
              Icons.schedule_rounded,
              colors.primary,
            ),
            ImageGenerationTaskStatus.generating => (
              _t('生成中', 'Generating', '生成中'),
              Icons.auto_awesome_rounded,
              colors.tertiary,
            ),
            ImageGenerationTaskStatus.completed => (
              _t('已完成', 'Completed', '完了'),
              Icons.check_circle_rounded,
              colors.primary,
            ),
            ImageGenerationTaskStatus.failed => (
              _t('失败', 'Failed', '失敗'),
              Icons.error_rounded,
              colors.error,
            ),
            ImageGenerationTaskStatus.cancelled => (
              _t('已取消', 'Cancelled', 'キャンセル済み'),
              Icons.cancel_rounded,
              colors.onSurfaceVariant,
            ),
          };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(ColorScheme colors) => Center(
    child: Padding(
      padding: const EdgeInsets.all(30),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.image_search_rounded,
            size: 62,
            color: colors.onSurfaceVariant.withValues(alpha: .66),
          ),
          const SizedBox(height: 14),
          Text(
            _t('还没有生图记录', 'No generated images yet', '生成画像はまだありません'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 7),
          Text(
            _t(
              '在主对话中明确提出“帮我生成一张图片”等请求，任务和结果会显示在这里。',
              'Ask explicitly for an image in the main chat. Its task and result will appear here.',
              'メインチャットで画像生成を明確に依頼すると、タスクと結果がここに表示されます。',
            ),
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    ),
  );

  Widget _errorBanner(ColorScheme colors) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
    child: Material(
      key: const ValueKey('image-generation-manager-error'),
      color: colors.errorContainer.withValues(alpha: .88),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: colors.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _pageError!,
                style: TextStyle(color: colors.onErrorContainer),
              ),
            ),
            IconButton(
              tooltip: _t('关闭提示', 'Dismiss', '閉じる'),
              onPressed: () => setState(() => _pageError = null),
              icon: Icon(Icons.close_rounded, color: colors.onErrorContainer),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _brokenImage(BuildContext context, {Color? foregroundColor}) =>
      ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.broken_image_outlined,
                color:
                    foregroundColor ??
                    Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 6),
              Text(
                _t('图片无法读取', 'Image unavailable', '画像を読み込めません'),
                style: TextStyle(
                  color:
                      foregroundColor ??
                      Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      );

  String _formatTime(DateTime value) {
    String two(int part) => part.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }
}
