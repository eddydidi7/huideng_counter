import 'package:flutter/material.dart';

class NotePinnedTitle extends StatelessWidget {
  const NotePinnedTitle({
    super.key,
    required this.child,
    required this.pinned,
    this.label = '已置顶',
  });
  final Widget child;
  final bool pinned;
  final String label;

  @override
  Widget build(BuildContext context) => pinned
      ? Row(
          children: [
            Tooltip(
              message: label,
              child: Icon(
                Icons.push_pin,
                size: 14,
                semanticLabel: label,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(child: child),
          ],
        )
      : child;
}

class NoteGrid extends StatelessWidget {
  const NoteGrid({super.key, required this.count, required this.builder});
  final int count;
  final IndexedWidgetBuilder builder;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final height = ((constraints.maxHeight - 16 - 18) / 4).clamp(
        112.0 * scale,
        double.infinity,
      );
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisExtent: height,
          crossAxisSpacing: 6,
          mainAxisSpacing: 6,
        ),
        itemCount: count,
        itemBuilder: builder,
      );
    },
  );
}

class NoteGridCard extends StatelessWidget {
  const NoteGridCard({
    super.key,
    required this.title,
    required this.summary,
    required this.date,
    required this.menu,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.pinned = false,
    this.favorite = false,
    this.favorite2 = false,
    this.failed = false,
  });
  final Widget title, menu;
  final String summary, date;
  final VoidCallback? onTap, onLongPress;
  final bool selected;
  final bool pinned, favorite, favorite2, failed;
  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 4, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: DefaultTextStyle.merge(
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                    child: NotePinnedTitle(pinned: pinned, child: title),
                  ),
                ),
                if (selected)
                  const Padding(
                    padding: EdgeInsetsDirectional.only(end: 8),
                    child: Icon(Icons.check_circle),
                  )
                else
                  SizedBox(width: 40, height: 44, child: menu),
              ],
            ),
            Expanded(
              child: ClipRect(
                child: Text(
                  summary,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    date,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                if (favorite) const Icon(Icons.star_outline, size: 12),
                if (favorite2) const Text('2★', style: TextStyle(fontSize: 12)),
                if (failed)
                  const Tooltip(
                    message: '同步失败 · 菜单中重试',
                    child: Icon(Icons.cloud_off_outlined, size: 12),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
