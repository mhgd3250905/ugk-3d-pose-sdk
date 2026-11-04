/// Product copy used by the shared conversation. Defaults retain SF 3eb2a9e.
library;

class CoachChatStrings {
  const CoachChatStrings({
    this.invitation = '说说今天想怎么练？',
    this.returningInvitation = '欢迎回来，今天想怎么练？',
    this.inputHint = '说说想怎么练…',
    this.sendLabel = '发送',
    this.openPanelLabel = '打开功能面板',
    this.closePanelLabel = '收起面板',
    this.myPlansLabel = '我的计划',
    this.newConversationLabel = '新对话',
    this.libraryLabel = '动作库',
    this.settingsLabel = '设置',
    this.defaultSuggestions = const [
      '办公室 10 分钟肩颈放松',
      '在家 20 分钟练核心',
      '睡前拉伸 10 分钟',
      '跑步前热身',
    ],
    this.discoverySuggestion = '你能做什么',
    this.planSuggestions = const ['再短一点', '难一点', '换掉第 2 个', '换一套'],
    this.safetyIntro = '你好，我是你的训练助手。\n告诉我想练什么、在哪儿、有多少时间，我帮你排一套能直接跟练的计划。',
    this.disclaimer =
        '智能健身助手提供的是通用健身与拉伸建议，不是医疗诊断或康复处方。'
        '训练中如出现疼痛、麻木、头晕、胸闷或呼吸困难，请立即停止并及时就医。'
        '有慢性病、伤病或正在康复期，请先咨询医生。动作示范中的肌肉高亮仅为教学示意。',
    this.safetyQuestions = const [
      '孕期或产后 6 个月内',
      '近期做过手术，或医生让你限制运动',
      '最近摔伤、扭伤，或关节、腰背正在疼痛肿胀',
      '有心脏病、未控制的高血压，或运动时出现过胸痛、晕厥',
    ],
    this.safetyAdvice = const [
      '孕期和产后恢复期的训练，需要先由医生或专业人员评估。',
      '术后或被限制运动期间，请按医生的康复安排来。',
      '有急性疼痛或肿胀时先休息，必要时就医，恢复后再练。',
      '心血管方面的情况需要先经医生评估；如果现在就有胸痛或晕厥，请立即就医。',
    ],
    this.safetyLead = '再确认 4 件事，符合的话点「是」。',
    this.safetyAllClear = '好，都没问题。\n现在说说：想练什么、在哪儿、有多少时间？',
    this.recheckSafety = '好，重新做一次安全确认。',
    this.finishSafetyFirst = '先把上面的安全确认做完，再帮你排计划。',
    this.safetyBlocked = '根据你的安全确认，先不生成训练计划；可以先浏览动作库或重新确认。',
    this.unavailable = 'AI 教练暂不可用，可以先浏览动作库或打开已保存计划。',
    this.noSavedPlan = '这套计划已经删掉了。',
    this.noLastPlan = '还没有训练过的计划。',
    this.noHistory = '还没有训练记录。',
    this.focusUnavailable = '这套计划暂时无法在对话里编辑',
    this.persistenceFailed = '对话保存失败，请重试。',
    this.saveConflict = '这套计划已在其他地方更新，请刷新后重试或另存一份。',
    this.saveFailed = '计划保存失败，请重试。',
    this.retryRequest = '重试',
    this.networkFailure = '网络连接失败，多次重试后仍未成功，请检查网络后再试。',
    this.authenticationFailure = '身份验证失败，请重新登录或检查服务配置后重试。',
    this.contextFailure = '这段对话的上下文暂时放不下，请重试；原有对话会保留。',
    this.conversationLimitReached = '本次对话已到长度上限，请开启新对话继续。',
    this.planGateFailure = '方案未通过计划检查，暂未交付，请重试。',
    this.timeoutFailure = '这次等待时间过长，请重试。',
    this.serviceFailure = '教练服务暂时未能完成回复，请稍后重试。',
    this.generationFailure = '这次未能完成回复，请重试。',
    this.planFromActionsRequest = '请把刚才推荐的动作排成计划。',
    this.historyUnreadable = '之前的对话记录无法读取，已开始新的对话。',
  });

  final String invitation, returningInvitation, inputHint;
  final String sendLabel, openPanelLabel, closePanelLabel;
  final String myPlansLabel, newConversationLabel, libraryLabel, settingsLabel;
  final List<String> defaultSuggestions, planSuggestions;
  final String discoverySuggestion;
  final String safetyIntro, disclaimer, safetyLead, safetyAllClear;
  final List<String> safetyQuestions, safetyAdvice;
  final String recheckSafety, finishSafetyFirst, safetyBlocked, unavailable;
  final String noSavedPlan, noLastPlan, noHistory, focusUnavailable;
  final String persistenceFailed, saveConflict, saveFailed;
  final String retryRequest, planFromActionsRequest;
  final String networkFailure, authenticationFailure, contextFailure;
  final String conversationLimitReached;
  final String planGateFailure,
      timeoutFailure,
      serviceFailure,
      generationFailure;

  /// Shown once when the stored conversation cannot be restored and the chat
  /// falls back to a fresh conversation instead of going silent.
  final String historyUnreadable;

  String get safetyDisclaimer => '开始之前，先花 10 秒确认安全。\n\n$disclaimer';

  String safetyQuestionText(int index) =>
      '${index + 1}/${safetyQuestions.length}　${safetyQuestions[index]}？';

  String safetyBlockedText(int index) =>
      '${safetyAdvice[index]}\n'
      '为了安全，我先不为你生成训练计划，建议先咨询医生。你仍可以浏览动作库里的示范；'
      '情况变化后，可以在菜单的「关于与设置」里重新确认。';

  List<String> suggestions({bool blocked = false}) =>
      blocked ? const [] : [...defaultSuggestions, discoverySuggestion];

  String greetingFor(DateTime value) => switch (value.hour) {
    >= 5 && < 11 => '早上好',
    >= 11 && < 13 => '中午好',
    >= 13 && < 18 => '下午好',
    >= 18 && < 23 => '晚上好',
    _ => '夜深了',
  };

  String saveSuccess(String title, {bool updating = false}) =>
      updating ? '已更新「$title」' : '已保存为「$title」';
}
