import 'package:flutter/widgets.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart'
    show TrainingLibraryConfig, TrainingLibraryActionText;

import '../core/chat_controller.dart';
import '../core/chat_strings.dart';

/// A narrow inherited presentation scope. Ordinary token/progress changes do
/// not rebuild descendants; a language change keeps their state and geometry.
class ChatLocalization extends StatelessWidget {
  const ChatLocalization({
    super.key,
    required this.controller,
    required this.child,
  });
  final CoachChatController controller;
  final Widget child;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    child: child,
    builder: (context, child) => _ChatLocalizationScope(
      language: controller.context.language,
      strings: controller.profile.strings,
      library: controller.profile.library,
      child: child!,
    ),
  );
}

class _ChatLocalizationScope extends InheritedWidget {
  const _ChatLocalizationScope({
    required this.language,
    required this.strings,
    this.library,
    required super.child,
  });
  final String language;
  final CoachChatStrings strings;
  final TrainingLibraryConfig? library;
  @override
  bool updateShouldNotify(_ChatLocalizationScope old) =>
      language != old.language ||
      strings != old.strings ||
      library != old.library;
}

String chatLanguage(BuildContext context) =>
    context
        .dependOnInheritedWidgetOfExactType<_ChatLocalizationScope>()
        ?.language ??
    Localizations.maybeLocaleOf(context)?.languageCode ??
    'zh';
bool chatIsEnglish(BuildContext context) =>
    chatLanguage(context).toLowerCase().startsWith('en');
String chatCopy(BuildContext context, String chinese, String english) =>
    chatIsEnglish(context) ? english : chinese;
TrainingLibraryActionText? chatActionText(BuildContext context, String id) =>
    context
        .dependOnInheritedWidgetOfExactType<_ChatLocalizationScope>()
        ?.library
        ?.displayText
        ?.call(id);

String chatEnglishTime(DateTime at, DateTime now) {
  final days = DateTime(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime(at.year, at.month, at.day)).inDays;
  final hm =
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  return '${days == 0
      ? 'Today'
      : days == 1
      ? 'Yesterday'
      : '${at.month}/${at.day}'} $hm';
}
