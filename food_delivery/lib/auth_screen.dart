import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:lottie/lottie.dart';
import 'package:url_launcher/url_launcher.dart';

const authStorage = FlutterSecureStorage();
const _botUrl = 'https://t.me/tokyodeltest_bot?start=login';
const _accent = Color(0xFFE0E3E5);

class AuthSheet extends StatefulWidget {
  final String apiBase;
  const AuthSheet({super.key, required this.apiBase});

  static Future<String?> open(BuildContext context, String apiBase) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => AuthSheet(apiBase: apiBase),
    );
  }

  @override
  State<AuthSheet> createState() => _AuthSheetState();
}

class _AuthSheetState extends State<AuthSheet> {
  final code = TextEditingController();
  bool accepted = false;
  bool busy = false;
  bool success = false;
  String? error;

  @override
  void initState() {
    super.initState();
    code.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    code.removeListener(_changed);
    code.dispose();
    super.dispose();
  }

  Future<void> openBot() async {
    if (!accepted) return;
    try {
      final ok = await launchUrl(Uri.parse(_botUrl),
          mode: LaunchMode.externalApplication);
      if (!ok) throw Exception('Telegram не открылся');
    } catch (_) {
      if (mounted) setState(() => error = 'Не удалось открыть Telegram');
    }
  }

  Future<void> paste() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final matches =
          RegExp(r'(?<!\d)\d{6}(?!\d)').allMatches(data?.text ?? '').toList();
      if (matches.length != 1) throw Exception('Скопируй 6 цифр из бота');
      final text = matches.single.group(0)!;
      code.value = TextEditingValue(
          text: text, selection: TextSelection.collapsed(offset: text.length));
      if (mounted) {
        setState(() => error = null);
        FocusScope.of(context).unfocus();
      }
    } catch (_) {
      if (mounted) setState(() => error = 'В буфере нет шестизначного кода');
    }
  }

  Future<void> verify() async {
    if (busy || !accepted || code.text.length != 6) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final response = await http
          .post(
            Uri.parse('${widget.apiBase}/api/auth/verify'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'code': code.text, 'accepted_policy': true}),
          )
          .timeout(const Duration(seconds: 12));
      final data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      if (response.statusCode != 200) {
        throw Exception(data['detail'] ?? 'Неверный или просроченный код');
      }
      final token = data['token'] as String?;
      if (token == null || token.isEmpty) throw Exception('Нет токена сессии');
      await authStorage.write(key: 'tokyo_token', value: token);
      if (!mounted) return;
      setState(() => success = true);
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      if (mounted)
        Navigator.pop(context, data['display_name'] as String? ?? 'Telegram');
    } catch (e) {
      if (mounted)
        setState(() => error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void showPolicy() {
    showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Сбор и обработка данных'),
              content: const SingleChildScrollView(
                  child: Text(
                'Тестовая версия Tokyo Суши. При входе через Telegram сохраняются '
                'Telegram ID, имя пользователя, время согласия и токен сессии. '
                'При нажатии кнопки передачи контакта Telegram сообщает боту номер '
                'телефона для проверки, что контакт принадлежит вам. В текущей '
                'реализации бот не сохраняет этот номер в базе. Для доставки могут '
                'запрашиваться имя, телефон и адрес. Перед запуском для клиентов '
                'необходимо опубликовать полную политику конфиденциальности с '
                'реквизитами оператора, сроками хранения и способом отзыва согласия.',
              )),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Закрыть'))
              ],
            ));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .88),
        decoration: const BoxDecoration(
          color: Color(0xF51D2023),
          borderRadius: BorderRadius.vertical(top: Radius.circular(29)),
        ),
        child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 15, 22, 28),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                        child: Container(
                            width: 43,
                            height: 5,
                            decoration: BoxDecoration(
                                color: Colors.white30,
                                borderRadius: BorderRadius.circular(9)))),
                    const SizedBox(height: 23),
                    if (success) ...[
                      Center(
                          child: SizedBox(
                              width: 170,
                              height: 170,
                              child: Lottie.asset(
                                  'assets/animations/success_check.json',
                                  repeat: false))),
                      const Center(
                          child: Text('Вход подтверждён!',
                              style: TextStyle(
                                  fontSize: 22, fontWeight: FontWeight.bold))),
                    ] else ...[
                      const Text('Вход через Telegram',
                          style: TextStyle(
                              fontSize: 25, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 8),
                      const Text(
                          '1. Прими условия. 2. Открой бота. 3. Вставь код.',
                          style: TextStyle(color: Colors.white60)),
                      const SizedBox(height: 19),
                      Container(
                          padding: const EdgeInsets.all(9),
                          decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: .055),
                              borderRadius: BorderRadius.circular(17),
                              border: Border.all(color: Colors.white12)),
                          child: Row(children: [
                            Checkbox(
                                value: accepted,
                                activeColor: _accent,
                                checkColor: Colors.black,
                                onChanged: busy
                                    ? null
                                    : (v) =>
                                        setState(() => accepted = v ?? false)),
                            Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  const Text(
                                      'Согласен на сбор и обработку персональных данных',
                                      style: TextStyle(fontSize: 13)),
                                  TextButton(
                                      onPressed: showPolicy,
                                      child: const Text('Прочитать политику')),
                                ])),
                          ])),
                      const SizedBox(height: 15),
                      SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: FilledButton.icon(
                              onPressed: accepted && !busy ? openBot : null,
                              icon: const Icon(Icons.send_rounded),
                              label: const Text('Открыть @tokyodeltest_bot'))),
                      const SizedBox(height: 22),
                      Row(children: [
                        Expanded(
                            child: TextField(
                          controller: code,
                          maxLength: 6,
                          textAlign: TextAlign.center,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly
                          ],
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 21,
                              letterSpacing: 5),
                          decoration: const InputDecoration(
                              labelText: 'Код из Telegram',
                              hintText: '000000',
                              counterText: ''),
                        )),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                            onPressed: busy ? null : paste,
                            icon: const Icon(Icons.content_paste_rounded,
                                size: 18),
                            label: const Text('Вставить')),
                      ]),
                      const SizedBox(height: 19),
                      SizedBox(
                          width: double.infinity,
                          height: 53,
                          child: FilledButton(
                              onPressed:
                                  busy || !accepted || code.text.length != 6
                                      ? null
                                      : verify,
                              child: Text(busy
                                  ? 'Проверяем...'
                                  : 'Подтвердить и войти'))),
                      if (error != null)
                        Padding(
                            padding: const EdgeInsets.only(top: 15),
                            child: Text(error!,
                                style:
                                    const TextStyle(color: Color(0xFFFFA3AB)))),
                    ],
                  ]),
            )),
      ),
    );
  }
}
