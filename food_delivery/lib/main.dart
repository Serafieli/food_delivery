import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'auth_screen.dart';
import 'profile_screen.dart';
import 'dish_swipe_sheet.dart';

const apiBase = String.fromEnvironment('API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000');
const violet = Color(0xFFE0E3E5);
const background = Color(0xFF111315);

String tgMoney(int n) => '$n ₸';
String imageAddress(String s) => s.startsWith('/') ? '$apiBase$s' : s;

void main() => runApp(const TokyoApp());

class TokyoApp extends StatelessWidget {
  const TokyoApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Tokyo Суши',
      theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: background,
          colorScheme: ColorScheme.fromSeed(
              seedColor: violet, brightness: Brightness.dark)),
      home: const TokyoHome());
}

class Dish {
  final int id, category, price;
  final String name, description, image;
  final bool hit;
  Dish(Map<String, dynamic> j)
      : id = j['id'],
        category = j['category_id'],
        price = j['price'],
        name = j['name'],
        description = j['description'] ?? '',
        image = j['image_url'] ?? '',
        hit = j['is_hit'] == 1 || j['is_hit'] == true;
}

class CartItem {
  final Dish dish;
  final List<int> options;
  final String optionsLabel;
  final int unitPrice;
  int quantity;
  CartItem(this.dish, this.options, this.optionsLabel, this.unitPrice,
      this.quantity);
  String get key => '${dish.id}:${options.join(',')}';
}

class FoodPhoto extends StatelessWidget {
  final Dish dish;
  const FoodPhoto(this.dish, {super.key});
  @override
  Widget build(BuildContext context) => dish.image.isEmpty
      ? const ColoredBox(
          color: Color(0xFF292D30),
          child: Center(
              child: Icon(Icons.ramen_dining_rounded, color: violet, size: 43)))
      : Image.network(imageAddress(dish.image),
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (_, error, stack) => const ColoredBox(
              color: Color(0xFF292D30),
              child: Icon(Icons.image_not_supported_outlined)));
}

class TokyoHome extends StatefulWidget {
  const TokyoHome({super.key});
  @override
  State<TokyoHome> createState() => _TokyoHomeState();
}

class _TokyoHomeState extends State<TokyoHome> {
  final pager = PageController();
  Timer? timer;
  int tab = 0, hitIndex = 0;
  int? selectedCategory;
  bool loading = true, showingStory = false;
  String? error, accountPhone;
  List<Dish> dishes = [];
  List<Map<String, dynamic>> categories = [];
  final favorites = <int>{};
  final cart = <CartItem>[];
  int? lastOrder;

  List<Dish> get hits => dishes.where((e) => e.hit).toList();
  List<Dish> get visible => selectedCategory == null
      ? dishes
      : dishes.where((e) => e.category == selectedCategory).toList();
  int get cartTotal => cart.fold(0, (a, e) => a + e.unitPrice * e.quantity);
  int get cartCount => cart.fold(0, (a, e) => a + e.quantity);

  @override
  void initState() {
    super.initState();
    fetchCatalog();
    loadAccount();
    timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted ||
          tab != 0 ||
          showingStory ||
          hits.length < 2 ||
          !pager.hasClients) return;
      pager.animateToPage((hitIndex + 1) % hits.length,
          duration: const Duration(milliseconds: 330),
          curve: Curves.easeOutCubic);
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    pager.dispose();
    super.dispose();
  }

  Future<void> loadAccount() async {
    final token = await authStorage.read(key: 'tokyo_token');
    if (token == null) return;
    try {
      final r = await http.get(Uri.parse('$apiBase/api/auth/me'),
          headers: {'Authorization': 'Bearer $token'});
      if (r.statusCode == 200 && mounted) {
        setState(() => accountPhone = jsonDecode(r.body)['display_name']);
      } else if (r.statusCode == 401) {
        await authStorage.delete(key: 'tokyo_token');
      }
    } catch (_) {
      /* Can display cached signed-in status after network reconnect. */
    }
  }

  Future<void> fetchCatalog() async {
    if (mounted)
      setState(() {
        loading = true;
        error = null;
      });
    try {
      final r = await Future.wait([
        http
            .get(Uri.parse('$apiBase/api/categories'))
            .timeout(const Duration(seconds: 12)),
        http
            .get(Uri.parse('$apiBase/api/products'))
            .timeout(const Duration(seconds: 12)),
      ]);
      if (r.any((e) => e.statusCode != 200))
        throw Exception('Сервер недоступен');
      final cats = (jsonDecode(utf8.decode(r[0].bodyBytes)) as List)
          .cast<Map<String, dynamic>>();
      final list = (jsonDecode(utf8.decode(r[1].bodyBytes)) as List)
          .map((e) => Dish(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() {
        categories = cats;
        dishes = list;
        loading = false;
        hitIndex = 0;
      });
      if (pager.hasClients) pager.jumpToPage(0);
    } catch (_) {
      if (mounted)
        setState(() {
          loading = false;
          error = 'Не удалось загрузить каталог';
        });
    }
  }

  void toggleFavorite(Dish d) => setState(() {
        if (!favorites.add(d.id)) favorites.remove(d.id);
      });

  Future<void> openDishAt(List<Dish> list, int index) async {
    if (list.isEmpty) return;
    await DishSwipeSheet.open<Dish>(
      context,
      items: list,
      index: index,
      builder: (_, dish, idx) => DishDetail(
        key: ValueKey(dish.id),
        dish: dish,
        onAdd: (options, labels, price, count) {
          final ids = [...options]..sort();
          final key = '${dish.id}:${ids.join(',')}';
          setState(() {
            final existing = cart.where((e) => e.key == key).firstOrNull;
            if (existing == null) {
              cart.add(CartItem(dish, ids, labels, price, count));
            } else {
              existing.quantity += count;
            }
          });
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              duration: Duration(milliseconds: 850),
              content: Text('Добавлено в корзину')));
        },
      ),
    );
  }

  Future<void> showStory(int initial) async {
    showingStory = true;
    final selected = await Navigator.push<Dish>(
        context,
        MaterialPageRoute(
            builder: (_) => HitStories(items: [...hits], index: initial)));
    showingStory = false;
    if (mounted && selected != null) {
      final list = visible;
      final index = list.indexWhere((d) => d.id == selected.id);
      await openDishAt(index >= 0 ? list : dishes,
          index >= 0 ? index : dishes.indexWhere((d) => d.id == selected.id));
    }
  }

  Widget banner() {
    if (hits.isEmpty)
      return const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: GlassBox(
              child: SizedBox(
                  height: 140,
                  child:
                      Center(child: Text('Добавь первый хит через админку')))));
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: SizedBox(
            height: 220,
            child: ClipRRect(
                borderRadius: BorderRadius.circular(25),
                child: Stack(children: [
                  PageView.builder(
                      controller: pager,
                      itemCount: hits.length,
                      onPageChanged: (i) => setState(() => hitIndex = i),
                      itemBuilder: (_, i) => GestureDetector(
                          onTap: () => showStory(i),
                          child: Stack(fit: StackFit.expand, children: [
                            FoodPhoto(hits[i]),
                            const DecoratedBox(
                                decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                  Colors.transparent,
                                  Color(0xC0000000)
                                ]))),
                            Positioned(
                                left: 12,
                                right: 12,
                                bottom: 26,
                                child: Align(
                                    alignment: Alignment.bottomLeft,
                                    child: GlassBox(
                                        child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                          Text(hits[i].name,
                                              style: const TextStyle(
                                                  fontSize: 17,
                                                  fontWeight: FontWeight.bold)),
                                          Text(tgMoney(hits[i].price),
                                              style: const TextStyle(
                                                  color: violet))
                                        ]))))
                          ]))),
                  Positioned(
                      bottom: 10,
                      left: 0,
                      right: 0,
                      child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(
                              hits.length,
                              (i) => AnimatedContainer(
                                  duration: const Duration(milliseconds: 230),
                                  margin:
                                      const EdgeInsets.symmetric(horizontal: 3),
                                  width: i == hitIndex ? 19 : 6,
                                  height: 5,
                                  decoration: BoxDecoration(
                                      color: i == hitIndex
                                          ? Colors.white
                                          : Colors.white38,
                                      borderRadius:
                                          BorderRadius.circular(5)))))),
                ]))));
  }

  Widget menu() => RefreshIndicator(
      onRefresh: fetchCatalog,
      child: ListView(padding: const EdgeInsets.only(bottom: 160), children: [
        const Padding(
            padding: EdgeInsets.fromLTRB(20, 28, 20, 8),
            child: Text('Tokyo Суши',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 29))),
        const Header('Хиты'),
        if (loading)
          const Center(child: CircularProgressIndicator())
        else if (error != null)
          Padding(
              padding: const EdgeInsets.all(20),
              child: FilledButton(
                  onPressed: fetchCatalog, child: Text('$error — повторить')))
        else ...[
          banner(),
          const Header('Меню'),
          SizedBox(
              height: 49,
              child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: [
                    chip(null, 'Все'),
                    for (final c in categories)
                      chip(c['id'] as int, c['name'] as String),
                  ])),
          const SizedBox(height: 14),
          for (var i = 0; i < visible.length; i++) dishCard(visible[i], i),
          if (visible.isEmpty)
            const Padding(
                padding: EdgeInsets.all(28),
                child:
                    Text('Здесь пока нет блюд', textAlign: TextAlign.center)),
        ],
      ]));

  Widget chip(int? id, String text) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
          label: Text(text),
          showCheckmark: false,
          selected: selectedCategory == id,
          onSelected: (_) => setState(() => selectedCategory = id)));

  Widget dishCard(Dish d, int index) => Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
      child: GlassBox(
          child: InkWell(
              onTap: () => openDishAt(visible, index),
              child: Row(children: [
                ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child:
                        SizedBox(width: 92, height: 92, child: FoodPhoto(d))),
                const SizedBox(width: 13),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(d.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      if (d.description.isNotEmpty)
                        Text(d.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white60)),
                      const SizedBox(height: 8),
                      Text(tgMoney(d.price),
                          style: const TextStyle(color: violet)),
                    ])),
                Column(children: [
                  IconButton(
                      onPressed: () => toggleFavorite(d),
                      icon: Icon(
                          favorites.contains(d.id)
                              ? Icons.favorite
                              : Icons.favorite_border,
                          color: violet)),
                  IconButton(
                      onPressed: () => openDishAt(visible, index),
                      icon: const Icon(Icons.add_circle, color: violet))
                ]),
              ]))));

  void sheet(String title, Widget Function(StateSetter refresh) build) =>
      showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (ctx) => StatefulBuilder(
              builder: (ctx, refresh) => FractionallySizedBox(
                  heightFactor: .86,
                  child: Container(
                      decoration: const BoxDecoration(
                          color: Color(0xF3212427),
                          borderRadius:
                              BorderRadius.vertical(top: Radius.circular(28))),
                      child: SafeArea(
                          top: false,
                          child: Column(children: [
                            const SizedBox(height: 12),
                            const Icon(Icons.horizontal_rule,
                                color: Colors.white38, size: 35),
                            Padding(
                                padding: const EdgeInsets.all(16),
                                child: Text(title,
                                    style: const TextStyle(
                                        fontSize: 25,
                                        fontWeight: FontWeight.bold))),
                            Expanded(child: build(refresh)),
                          ]))))));

  void showFavorites() => sheet(
      'Любимое',
      (refresh) => ListView(
          padding: const EdgeInsets.all(18),
          children: dishes
              .where((d) => favorites.contains(d.id))
              .map((d) => GlassBox(
                  child: ListTile(
                      title: Text(d.name),
                      subtitle: Text(tgMoney(d.price)),
                      leading: SizedBox(width: 48, child: FoodPhoto(d)),
                      onTap: () {
                        Navigator.pop(context);
                        openDishAt(dishes, dishes.indexOf(d));
                      },
                      trailing: IconButton(
                          onPressed: () {
                            toggleFavorite(d);
                            refresh(() {});
                          },
                          icon: const Icon(Icons.favorite, color: violet)))))
              .toList()));

  void showOrders() => sheet(
      'Заказы',
      (_) => Center(
          child: Text(lastOrder == null
              ? 'Оформленных заказов пока нет'
              : 'Последний заказ №$lastOrder')));

  void showCart() => sheet(
      'Корзина',
      (refresh) => ListView(padding: const EdgeInsets.all(18), children: [
            for (final item in [...cart])
              GlassBox(
                  child: ListTile(
                      title: Text(item.dish.name),
                      subtitle: Text(
                          '${item.optionsLabel}\n${tgMoney(item.unitPrice)}'),
                      isThreeLine: item.optionsLabel.isNotEmpty,
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                            icon: const Icon(Icons.remove),
                            onPressed: () {
                              setState(() {
                                item.quantity--;
                                if (item.quantity <= 0) cart.remove(item);
                              });
                              refresh(() {});
                            }),
                        Text('${item.quantity}'),
                        IconButton(
                            icon: const Icon(Icons.add),
                            onPressed: () {
                              setState(() => item.quantity++);
                              refresh(() {});
                            }),
                      ]))),
            const SizedBox(height: 15),
            Text('Итого: ${tgMoney(cartTotal)}',
                style: const TextStyle(fontSize: 22)),
            const SizedBox(height: 15),
            if (cart.isNotEmpty)
              FilledButton(
                  onPressed: () => checkoutDialog(),
                  child: const Text('Оформить заказ')),
          ]));

  Future<void> checkoutDialog() async {
    final name = TextEditingController();
    final phone = TextEditingController(text: '+7');
    final address = TextEditingController();
    final form = GlobalKey<FormState>();
    try {
      await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
                title: const Text('Оформить заказ'),
                content: Form(
                    key: form,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      for (final e in [
                        (name, 'Имя'),
                        (phone, 'Телефон'),
                        (address, 'Адрес')
                      ])
                        TextFormField(
                            controller: e.$1,
                            decoration: InputDecoration(labelText: e.$2),
                            validator: (v) => (v ?? '').trim().length < 5
                                ? 'Заполните поле'
                                : null),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Отмена')),
                  FilledButton(
                      onPressed: () async {
                        if (!form.currentState!.validate()) return;
                        try {
                          final r =
                              await http.post(Uri.parse('$apiBase/api/orders'),
                                  headers: {'Content-Type': 'application/json'},
                                  body: jsonEncode({
                                    'customer_name': name.text,
                                    'phone': phone.text,
                                    'address': address.text,
                                    'items': cart
                                        .map((e) => {
                                              'product_id': e.dish.id,
                                              'quantity': e.quantity,
                                              'option_ids': e.options
                                            })
                                        .toList(),
                                  }));
                          if (r.statusCode != 201)
                            throw Exception('Ошибка отправки заказа');
                          if (!mounted) return;
                          setState(() {
                            lastOrder = jsonDecode(r.body)['id'];
                            cart.clear();
                          });
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('Заказ успешно отправлен')));
                          }
                        } catch (_) {
                          if (ctx.mounted)
                            ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                    content:
                                        Text('Не удалось отправить заказ')));
                        }
                      },
                      child: const Text('Подтвердить'))
                ],
              ));
    } finally {
      name.dispose();
      phone.dispose();
      address.dispose();
    }
  }

  Future<void> _login() async {
    final verified = await AuthSheet.open(context, apiBase);
    if (mounted && verified != null) {
      setState(() => accountPhone = verified);
    }
  }

  Future<void> _logout() async {
    final token = await authStorage.read(key: 'tokyo_token');
    if (token != null) {
      try {
        await http.post(Uri.parse('$apiBase/api/auth/logout'),
            headers: {'Authorization': 'Bearer $token'});
      } catch (_) {}
    }
    await authStorage.delete(key: 'tokyo_token');
    if (mounted) setState(() => accountPhone = null);
  }

  Widget profile() => TokyoProfileScreen(
        telegramName: accountPhone,
        lastOrderId: lastOrder,
        onLogin: _login,
        onLogout: _logout,
      );

  Widget navIcon(IconData icon, int idx, VoidCallback action) => Expanded(
      child: InkWell(
          onTap: action,
          child: SizedBox(
              height: 56,
              child: Center(
                  child: AnimatedScale(
                      scale: tab == idx ? 1.1 : 1,
                      duration: const Duration(milliseconds: 160),
                      child: Icon(icon,
                          size: 29,
                          color: tab == idx ? violet : Colors.white70))))));

  @override
  Widget build(BuildContext context) => Scaffold(
      extendBody: true,
      body: Stack(children: [
        const Positioned.fill(
            child: DecoratedBox(
                decoration: BoxDecoration(
                    gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
              Color(0xFF24282B),
              background,
              Color(0xFF0C0D0F)
            ])))),
        SafeArea(
            bottom: false,
            child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: KeyedSubtree(
                    key: ValueKey(tab), child: tab == 3 ? profile() : menu()))),
        if (tab == 0 && cartCount > 0)
          Positioned(
              left: 20,
              right: 20,
              bottom: MediaQuery.paddingOf(context).bottom + 95,
              child: FilledButton(
                  onPressed: showCart,
                  child: Text('Корзина · $cartCount · ${tgMoney(cartTotal)}'))),
        Positioned(
            left: 25,
            right: 25,
            bottom: MediaQuery.paddingOf(context).bottom + 14,
            child: ClipRRect(
                borderRadius: BorderRadius.circular(34),
                child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(
                            color: const Color(0xB82D3134),
                            borderRadius: BorderRadius.circular(34),
                            border: Border.all(color: Colors.white24)),
                        child: Row(children: [
                          navIcon(Icons.restaurant_menu_rounded, 0,
                              () => setState(() => tab = 0)),
                          navIcon(Icons.receipt_long_outlined, 1, showOrders),
                          navIcon(
                              Icons.favorite_border_rounded, 2, showFavorites),
                          navIcon(Icons.person_outline_rounded, 3,
                              () => setState(() => tab = 3)),
                        ]))))),
      ]));
}

class DishDetail extends StatefulWidget {
  final Dish dish;
  final void Function(List<int>, String, int, int) onAdd;
  const DishDetail({super.key, required this.dish, required this.onAdd});
  @override
  State<DishDetail> createState() => _DishDetailState();
}

class _DishDetailState extends State<DishDetail> {
  List<Map<String, dynamic>>? groups;
  final selected = <int>{};
  int quantity = 1;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final r = await http
          .get(Uri.parse('$apiBase/api/products/${widget.dish.id}/modifiers'));
      if (r.statusCode != 200) throw Exception('Нельзя загрузить дополнения');
      if (mounted)
        setState(() =>
            groups = (jsonDecode(r.body) as List).cast<Map<String, dynamic>>());
    } catch (_) {
      if (mounted)
        setState(() => error = 'Ошибка дополнений. Попробуй ещё раз.');
    }
  }

  @override
  Widget build(BuildContext context) {
    int extra = 0;
    bool valid = true;
    final names = <String>[];
    for (final g in groups ?? <Map<String, dynamic>>[]) {
      final options = (g['options'] as List).cast<Map<String, dynamic>>();
      final chosen = options.where((o) => selected.contains(o['id'])).toList();
      if (chosen.length < g['min_select'] || chosen.length > g['max_select'])
        valid = false;
      for (final o in chosen) {
        extra += o['price'] as int;
        names.add(o['name'] as String);
      }
    }
    return Column(children: [
      Expanded(
          child: ListView(
              padding: const EdgeInsets.fromLTRB(19, 0, 19, 10),
              children: [
            ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: SizedBox(height: 285, child: FoodPhoto(widget.dish))),
            const SizedBox(height: 17),
            Text(widget.dish.name,
                style:
                    const TextStyle(fontSize: 25, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(tgMoney(widget.dish.price),
                style: const TextStyle(fontSize: 20, color: violet)),
            if (widget.dish.description.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(widget.dish.description,
                      style: const TextStyle(color: Colors.white70))),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.redAccent)),
            if (groups == null && error == null)
              const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator())),
            for (final group in groups ?? <Map<String, dynamic>>[]) ...[
              const SizedBox(height: 22),
              Text(
                  '${group['name']}  ·  ${group['min_select'] == 0 ? 'Необязательно' : 'Обязательно'}',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.bold)),
              for (final o
                  in (group['options'] as List).cast<Map<String, dynamic>>())
                CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(o['name'] as String),
                    subtitle: Text('+${tgMoney(o['price'] as int)}'),
                    value: selected.contains(o['id']),
                    activeColor: violet,
                    onChanged: (v) => setState(() {
                          if (v == true) {
                            final inGroup = (group['options'] as List)
                                .where((e) => selected.contains(e['id']))
                                .length;
                            if (inGroup >= group['max_select']) return;
                            selected.add(o['id'] as int);
                          } else {
                            selected.remove(o['id']);
                          }
                        })),
            ],
          ])),
      Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
          child: Row(children: [
            IconButton(
                onPressed:
                    quantity > 1 ? () => setState(() => quantity--) : null,
                icon: const Icon(Icons.remove_circle_outline)),
            Text('$quantity'),
            IconButton(
                onPressed:
                    quantity < 50 ? () => setState(() => quantity++) : null,
                icon: const Icon(Icons.add_circle_outline)),
            const Spacer(),
            Text(tgMoney((widget.dish.price + extra) * quantity),
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
          ])),
      Padding(
          padding: const EdgeInsets.fromLTRB(19, 0, 19, 15),
          child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                  onPressed: groups == null || !valid
                      ? null
                      : () {
                          widget.onAdd(selected.toList(), names.join(', '),
                              widget.dish.price + extra, quantity);
                        },
                  child: const Text('Добавить в корзину')))),
    ]);
  }
}

class HitStories extends StatefulWidget {
  final List<Dish> items;
  final int index;
  const HitStories({super.key, required this.items, required this.index});
  @override
  State<HitStories> createState() => _HitStoriesState();
}

class _HitStoriesState extends State<HitStories> {
  late final PageController pager;
  late int index;
  Timer? timer;
  double progress = 0;
  double down = 0;
  @override
  void initState() {
    super.initState();
    index = widget.index;
    pager = PageController(initialPage: index);
    timer = Timer.periodic(const Duration(milliseconds: 40), (_) {
      if (!mounted) return;
      setState(() => progress += .02);
      if (progress >= 1) next();
    });
  }

  void next() {
    if (index + 1 >= widget.items.length) {
      Navigator.pop(context);
      return;
    }
    pager.animateToPage(index + 1,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  void previous() {
    if (index == 0) {
      setState(() => progress = 0);
      return;
    }
    pager.animateToPage(index - 1,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  @override
  void dispose() {
    timer?.cancel();
    pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
          onVerticalDragStart: (_) => down = 0,
          onVerticalDragUpdate: (d) => down += d.delta.dy,
          onVerticalDragEnd: (_) {
            if (down > 100) Navigator.pop(context);
          },
          child: Stack(children: [
            Positioned.fill(
                child: PageView.builder(
                    controller: pager,
                    itemCount: widget.items.length,
                    onPageChanged: (v) => setState(() {
                          index = v;
                          progress = 0;
                        }),
                    itemBuilder: (_, i) => FoodPhoto(widget.items[i]))),
            const Positioned.fill(
                child: IgnorePointer(
                    child: DecoratedBox(
                        decoration: BoxDecoration(
                            gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                  Color(0xA0000000),
                  Colors.transparent,
                  Color(0xD9000000)
                ]))))),
            Positioned(
                top: MediaQuery.paddingOf(context).top + 12,
                left: 12,
                right: 12,
                child: Row(
                    children: List.generate(
                        widget.items.length,
                        (i) => Expanded(
                            child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 2),
                                child: LinearProgressIndicator(
                                    value: i < index
                                        ? 1
                                        : i == index
                                            ? progress.clamp(0, 1)
                                            : 0,
                                    minHeight: 3,
                                    color: Colors.white,
                                    backgroundColor: Colors.white38)))))),
            Positioned(
                top: MediaQuery.paddingOf(context).top + 28,
                left: 16,
                right: 10,
                child: Row(children: [
                  const Text('Tokyo Суши',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close))
                ])),
            Positioned.fill(
                child: Row(children: [
              Expanded(
                  child: GestureDetector(
                      behavior: HitTestBehavior.translucent, onTap: previous)),
              Expanded(
                  child: GestureDetector(
                      behavior: HitTestBehavior.translucent, onTap: next))
            ])),
            Positioned(
                bottom: MediaQuery.paddingOf(context).bottom + 20,
                left: 20,
                right: 20,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      GlassBox(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(widget.items[index].name,
                                style: const TextStyle(
                                    fontSize: 23, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            Text(tgMoney(widget.items[index].price)),
                          ])),
                      const SizedBox(height: 12),
                      FilledButton(
                          onPressed: () =>
                              Navigator.pop(context, widget.items[index]),
                          child: const Text('Выбрать блюдо')),
                    ])),
          ])));
}

class GlassBox extends StatelessWidget {
  final Widget child;
  const GlassBox({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white12)),
      child: child);
}

class Header extends StatelessWidget {
  final String label;
  const Header(this.label, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 25, 20, 15),
      child: Text(label,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 22)));
}
