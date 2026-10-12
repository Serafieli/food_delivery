import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Локальные настройки профиля. Это НЕ платежный шлюз.
const _storage = FlutterSecureStorage();
const _bg = Color(0xFF111315);
const _panel = Color(0xFF202326);
const _accent = Color(0xFFE0E3E5);

class TokyoProfileScreen extends StatefulWidget {
  final String? telegramName;
  final Future<void> Function() onLogin;
  final Future<void> Function() onLogout;
  final int? lastOrderId;

  const TokyoProfileScreen({
    super.key,
    required this.telegramName,
    required this.onLogin,
    required this.onLogout,
    required this.lastOrderId,
  });

  @override
  State<TokyoProfileScreen> createState() => _TokyoProfileScreenState();
}

class _TokyoProfileScreenState extends State<TokyoProfileScreen> {
  String address = '';
  String payment = 'Не выбран';
  String nickname = '';
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _readPreferences();
  }

  Future<void> _readPreferences() async {
    try {
      final values = await Future.wait([
        _storage.read(key: 'profile_address'),
        _storage.read(key: 'profile_payment'),
        _storage.read(key: 'profile_nickname'),
      ]);
      if (!mounted) return;
      setState(() {
        address = values[0] ?? '';
        payment = values[1] ?? 'Не выбран';
        nickname = values[2] ?? '';
        loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _editText({
    required String title,
    required String initial,
    required String hint,
    required int maxLength,
    required Future<void> Function(String) save,
  }) async {
    final controller = TextEditingController(text: initial);
    final form = GlobalKey<FormState>();
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 26),
            decoration: const BoxDecoration(
              color: _panel,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: SafeArea(
              top: false,
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 17),
                    TextFormField(
                      controller: controller,
                      autofocus: true,
                      maxLength: maxLength,
                      maxLines: title == 'Адрес доставки' ? 2 : 1,
                      decoration: InputDecoration(hintText: hint),
                      validator: (value) =>
                          (value ?? '').trim().isEmpty ? 'Заполни поле' : null,
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton(
                        onPressed: () async {
                          if (!form.currentState!.validate()) return;
                          try {
                            await save(controller.text.trim());
                            if (sheetContext.mounted)
                              Navigator.pop(sheetContext);
                          } catch (_) {
                            if (sheetContext.mounted) {
                              ScaffoldMessenger.of(sheetContext).showSnackBar(
                                const SnackBar(
                                    content:
                                        Text('Не удалось сохранить настройку')),
                              );
                            }
                          }
                        },
                        child: const Text('Сохранить'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _paymentSheet() async {
    String selected = payment;
    final custom = TextEditingController(
      text: ![
        'Не выбран',
        'Наличными при получении',
        'Картой при получении',
        'Тестовая оплата'
      ].contains(payment)
          ? payment
          : '',
    );
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) => StatefulBuilder(
          builder: (sheetContext, refresh) => Padding(
            padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
            child: Container(
              padding: const EdgeInsets.fromLTRB(18, 17, 18, 26),
              decoration: const BoxDecoration(
                color: _panel,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Способ оплаты',
                          style: TextStyle(
                              fontSize: 23, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 5),
                      const Text('Демонстрация — деньги не списываются',
                          style: TextStyle(color: Colors.white54)),
                      const SizedBox(height: 16),
                      for (final choice in [
                        'Наличными при получении',
                        'Картой при получении',
                        'Тестовая оплата',
                        'Свой вариант',
                      ])
                        RadioListTile<String>(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(choice),
                          value: choice,
                          groupValue: ![
                            'Не выбран',
                            'Наличными при получении',
                            'Картой при получении',
                            'Тестовая оплата'
                          ].contains(selected)
                              ? 'Свой вариант'
                              : selected,
                          onChanged: (value) =>
                              refresh(() => selected = value!),
                        ),
                      if (selected == 'Свой вариант' ||
                          ![
                            'Не выбран',
                            'Наличными при получении',
                            'Картой при получении',
                            'Тестовая оплата'
                          ].contains(selected)) ...[
                        const SizedBox(height: 5),
                        TextField(
                          controller: custom,
                          maxLength: 50,
                          decoration: const InputDecoration(
                            labelText: 'Название тестового способа',
                            hintText: 'Например: Оплата при вручении',
                          ),
                        ),
                        const Text(
                            'Не вводи номер банковской карты, CVV или пароли.',
                            style:
                                TextStyle(color: Colors.white54, fontSize: 12)),
                      ],
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: FilledButton(
                          onPressed: () async {
                            final value = (selected == 'Свой вариант' ||
                                    ![
                                      'Не выбран',
                                      'Наличными при получении',
                                      'Картой при получении',
                                      'Тестовая оплата'
                                    ].contains(selected))
                                ? custom.text.trim()
                                : selected;
                            if (value.isEmpty || value == 'Не выбран') return;
                            try {
                              await _storage.write(
                                  key: 'profile_payment', value: value);
                              if (!mounted) return;
                              setState(() => payment = value);
                              if (sheetContext.mounted)
                                Navigator.pop(sheetContext);
                            } catch (_) {
                              if (sheetContext.mounted) {
                                ScaffoldMessenger.of(sheetContext).showSnackBar(
                                  const SnackBar(
                                      content: Text('Не удалось сохранить')),
                                );
                              }
                            }
                          },
                          child: const Text('Сохранить способ'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    } finally {
      custom.dispose();
    }
  }

  Widget _panelBox({required Widget child}) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: const Color(0xC924272A),
          borderRadius: BorderRadius.circular(23),
          border: Border.all(color: Colors.white.withValues(alpha: .10)),
        ),
        child: child,
      );

  Widget _option(
          IconData icon, String title, String subtitle, VoidCallback action) =>
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        leading: Container(
          width: 43,
          height: 43,
          decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .065),
              borderRadius: BorderRadius.circular(14)),
          child: Icon(icon, color: _accent, size: 22),
        ),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        subtitle: Text(subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Colors.white54)),
        trailing: const Icon(Icons.chevron_right_rounded,
            size: 22, color: Colors.white38),
        onTap: action,
      );

  @override
  Widget build(BuildContext context) {
    final telegram = widget.telegramName;
    return ColoredBox(
      color: Colors.transparent,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 25, 20, 145),
        children: [
          const Text('Профиль',
              style: TextStyle(fontSize: 29, fontWeight: FontWeight.w800)),
          const SizedBox(height: 22),
          _panelBox(
              child: Padding(
            padding: const EdgeInsets.all(19),
            child: Column(
              children: [
                const CircleAvatar(
                    radius: 37,
                    backgroundColor: Color(0xFF393D41),
                    child:
                        Icon(Icons.person_rounded, size: 36, color: _accent)),
                const SizedBox(height: 12),
                Text(telegram ?? 'Гость',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 21, fontWeight: FontWeight.w800)),
                const SizedBox(height: 5),
                Text(
                    telegram == null
                        ? 'Войди, чтобы пользоваться аккаунтом'
                        : 'Подключён Telegram',
                    style:
                        const TextStyle(fontSize: 12, color: Colors.white54)),
                const SizedBox(height: 17),
                if (telegram == null)
                  SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                          onPressed: widget.onLogin,
                          icon: const Icon(Icons.send_rounded),
                          label: const Text('Войти через Telegram')))
                else
                  SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                          onPressed: widget.onLogout,
                          child: const Text('Выйти из аккаунта'))),
              ],
            ),
          )),
          const Padding(
              padding: EdgeInsets.fromLTRB(3, 5, 0, 12),
              child: Text('Личные настройки',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
          _panelBox(
              child: Column(children: [
            _option(
                Icons.badge_outlined,
                'Как к тебе обращаться',
                nickname.isEmpty ? 'Не указано' : nickname,
                () => _editText(
                    title: 'Имя для доставки',
                    initial: nickname,
                    hint: 'Например: Алексей',
                    maxLength: 60,
                    save: (value) async {
                      await _storage.write(
                          key: 'profile_nickname', value: value);
                      if (mounted) setState(() => nickname = value);
                    })),
            const Divider(height: 1, color: Colors.white10, indent: 72),
            _option(
                Icons.location_on_outlined,
                'Адрес доставки',
                address.isEmpty ? 'Добавить адрес' : address,
                () => _editText(
                    title: 'Адрес доставки',
                    initial: address,
                    hint: 'Город, улица, дом, квартира',
                    maxLength: 180,
                    save: (value) async {
                      await _storage.write(
                          key: 'profile_address', value: value);
                      if (mounted) setState(() => address = value);
                    })),
          ])),
          const Padding(
              padding: EdgeInsets.fromLTRB(3, 5, 0, 12),
              child: Text('Оплата и заказы',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
          _panelBox(
              child: Column(children: [
            _option(Icons.account_balance_wallet_outlined, 'Способ оплаты',
                payment, _paymentSheet),
            const Divider(height: 1, color: Colors.white10, indent: 72),
            _option(
                Icons.receipt_long_outlined,
                'Мои заказы',
                widget.lastOrderId == null
                    ? 'Заказов пока нет'
                    : 'Последний заказ №${widget.lastOrderId}', () {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(widget.lastOrderId == null
                      ? 'Заказов пока нет'
                      : 'Последний заказ №${widget.lastOrderId}')));
            }),
          ])),
          _panelBox(
              child: const ListTile(
            leading: Icon(Icons.info_outline_rounded, color: _accent),
            title: Text('Tokyo Суши'),
            subtitle: Text(
                'Тестовая версия · сохранение настроек только на этом устройстве'),
          )),
          if (loading) const LinearProgressIndicator(minHeight: 2),
        ],
      ),
    );
  }
}
