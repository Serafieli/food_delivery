import 'dart:ui';
import 'package:flutter/material.dart';

/// Generic swipeable dish picker. Pass current filtered dishes and existing
/// dish-details builder (including modifiers) from your catalog.
class DishSwipeSheet<T> extends StatefulWidget {
  final List<T> items;
  final int initialIndex;
  final Widget Function(BuildContext context, T item, int index) builder;
  const DishSwipeSheet(
      {super.key,
      required this.items,
      required this.initialIndex,
      required this.builder});

  static Future<void> open<T>(
    BuildContext context, {
    required List<T> items,
    required int index,
    required Widget Function(BuildContext, T, int) builder,
  }) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => DishSwipeSheet<T>(
            items: items, initialIndex: index, builder: builder),
      );

  @override
  State<DishSwipeSheet<T>> createState() => _DishSwipeSheetState<T>();
}

class _DishSwipeSheetState<T> extends State<DishSwipeSheet<T>> {
  late final PageController pager;
  late int index;
  @override
  void initState() {
    super.initState();
    index = widget.initialIndex;
    pager = PageController(initialPage: index);
  }

  @override
  void dispose() {
    pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
        heightFactor: .94,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              color: const Color(0xF01E2124),
              child: SafeArea(
                  top: false,
                  child: Column(children: [
                    const SizedBox(height: 11),
                    Container(
                        width: 44,
                        height: 5,
                        decoration: BoxDecoration(
                            color: Colors.white30,
                            borderRadius: BorderRadius.circular(10))),
                    const SizedBox(height: 9),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Icon(Icons.swipe, size: 17, color: Colors.white54),
                      const SizedBox(width: 7),
                      Text('${index + 1} / ${widget.items.length}',
                          style: const TextStyle(color: Colors.white70)),
                      const Spacer(),
                      IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close)),
                    ]),
                    Expanded(
                        child: PageView.builder(
                      controller: pager,
                      itemCount: widget.items.length,
                      onPageChanged: (value) => setState(() => index = value),
                      itemBuilder: (context, idx) => KeyedSubtree(
                        key: ValueKey(idx),
                        child: widget.builder(context, widget.items[idx], idx),
                      ),
                    )),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10, top: 7),
                      child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(
                              widget.items.length.clamp(0, 12),
                              (i) => AnimatedContainer(
                                  duration: const Duration(milliseconds: 180),
                                  margin:
                                      const EdgeInsets.symmetric(horizontal: 3),
                                  width: i == index ? 19 : 5,
                                  height: 5,
                                  decoration: BoxDecoration(
                                      color: i == index
                                          ? Colors.white
                                          : Colors.white38,
                                      borderRadius:
                                          BorderRadius.circular(10))))),
                    ),
                  ])),
            ),
          ),
        ));
  }
}
