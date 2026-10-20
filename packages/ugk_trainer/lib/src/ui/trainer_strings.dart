// ugk_trainer's own: every word the player shows, given by the app (3D-Body
// has 12 languages). [TrainerStrings.zh] / [TrainerStrings.en] are the
// SmartFit wording as a starting point; nothing in the player is written
// in one language.
import '../engine/session.dart';

class TrainerStrings {
  const TrainerStrings({
    required this.prepFirst,
    required this.restNext,
    required this.restBetweenSets,
    required this.roundRest,
    required this.switchTo,
    required this.sideName,
    required this.roundOf,
    required this.setOf,
    required this.dose,
    required this.secondsCaption,
    required this.startsInCaption,
    required this.repsCaption,
    required this.selfPacedCaption,
    required this.completeSet,
    required this.paused,
    required this.next,
    required this.nextUp,
    required this.discomfort,
    required this.discomfortTitle,
    required this.discomfortBody,
    required this.discomfortContinue,
    required this.discomfortSkip,
    required this.discomfortEnd,
    required this.close,
    required this.closeTitle,
    required this.closeBody,
    required this.closeConfirm,
    required this.closeCancel,
    required this.previous,
    required this.skip,
    required this.pause,
    required this.resume,
    required this.doneFull,
    required this.donePartial,
    required this.minutes,
    required this.exercisesDone,
    required this.finish,
    required this.saveFailed,
    required this.saveRetry,
    required this.mediaUnavailable,
    required this.notificationChannel,
    required this.notificationChannelDescription,
    required this.notificationTitle,
    required this.notificationText,
  });

  /// Top label during prep ("准备 · 第一个动作").
  final String prepFirst;
  final String restNext;
  final String restBetweenSets;
  final String roundRest;

  /// "换左侧".
  final String Function(Side side) switchTo;

  /// "右侧" / "左侧".
  final String Function(Side side) sideName;

  /// "第 2/3 轮".
  final String Function(int round, int rounds) roundOf;

  /// "第 1/3 组".
  final String Function(int set, int sets) setOf;

  /// One set's amount: "每侧 12 次" / "30 秒".
  final String Function({
    required bool reps,
    required int amount,
    required bool perSide,
  })
  dose;

  /// Under the ring: "秒" (working) / "秒后开始" (rest) / "/ 12 次" /
  /// "自己数" (self-paced).
  final String secondsCaption;
  final String startsInCaption;
  final String Function(int reps) repsCaption;
  final String selfPacedCaption;

  /// The self-paced button ("完成本组").
  final String completeSet;
  final String paused;
  final String next;

  /// "下一个".
  final String nextUp;
  final String discomfort;
  final String discomfortTitle;
  final String discomfortBody;
  final String discomfortContinue;
  final String discomfortSkip;
  final String discomfortEnd;
  final String close;
  final String closeTitle;
  final String closeBody;
  final String closeConfirm;
  final String closeCancel;
  final String previous;
  final String skip;
  final String pause;
  final String resume;
  final String doneFull;
  final String donePartial;
  final String minutes;
  final String exercisesDone;
  final String finish;
  final String saveFailed;
  final String saveRetry;
  final String mediaUnavailable;

  /// Android ongoing notification while the keep-alive service runs.
  final String notificationChannel;
  final String notificationChannelDescription;
  final String notificationTitle;
  final String notificationText;

  static String _zhDose({
    required bool reps,
    required int amount,
    required bool perSide,
  }) => '${perSide ? '每侧 ' : ''}$amount ${reps ? '次' : '秒'}';

  static String _enDose({
    required bool reps,
    required int amount,
    required bool perSide,
  }) => '$amount ${reps ? 'reps' : 's'}${perSide ? ' each side' : ''}';

  factory TrainerStrings.zh() => TrainerStrings(
    prepFirst: '准备 · 第一个动作',
    restNext: '休息 · 下一个动作',
    restBetweenSets: '组间休息',
    roundRest: '这一轮完成 · 休息',
    switchTo: (s) => s == Side.left ? '换左侧' : '换右侧',
    sideName: (s) => s == Side.left ? '左侧' : '右侧',
    roundOf: (r, n) => '第 $r/$n 轮',
    setOf: (s, n) => '第 $s/$n 组',
    dose: _zhDose,
    secondsCaption: '秒',
    startsInCaption: '秒后开始',
    repsCaption: (n) => '/ $n 次',
    selfPacedCaption: '做完点完成',
    completeSet: '完成本组',
    paused: '已暂停',
    next: '下一个',
    nextUp: '下一个',
    discomfort: '不舒服',
    discomfortTitle: '哪里不舒服？',
    discomfortBody: '出现刺痛、麻木、头晕或胸闷，请立即停止训练。轻微酸胀可以减小幅度、放慢速度。',
    discomfortContinue: '减小幅度，继续',
    discomfortSkip: '跳过这个动作',
    discomfortEnd: '结束今天的训练',
    close: '关闭训练',
    closeTitle: '结束训练？',
    closeBody: '本次进度会记为未完成。',
    closeConfirm: '结束',
    closeCancel: '继续练',
    previous: '上一个动作',
    skip: '跳过动作',
    pause: '暂停训练',
    resume: '继续训练',
    doneFull: '训练完成！',
    donePartial: '今天先到这里',
    minutes: '分钟',
    exercisesDone: '完成动作',
    finish: '完成',
    saveFailed: '训练记录没有保存成功',
    saveRetry: '重试',
    mediaUnavailable: '示范暂时加载不了',
    notificationChannel: '训练进行中',
    notificationChannelDescription: '训练进行时保持计时和语音指导',
    notificationTitle: '训练进行中',
    notificationText: '锁屏或切到后台时，计时和语音会继续',
  );

  factory TrainerStrings.en() => TrainerStrings(
    prepFirst: 'Get ready · first move',
    restNext: 'Rest · next move',
    restBetweenSets: 'Rest between sets',
    roundRest: 'Round done · rest',
    switchTo: (s) => s == Side.left ? 'Switch to left' : 'Switch to right',
    sideName: (s) => s == Side.left ? 'Left' : 'Right',
    roundOf: (r, n) => 'Round $r/$n',
    setOf: (s, n) => 'Set $s/$n',
    dose: _enDose,
    secondsCaption: 'sec',
    startsInCaption: 'sec to go',
    repsCaption: (n) => '/ $n reps',
    selfPacedCaption: 'tap when done',
    completeSet: 'Set done',
    paused: 'Paused',
    next: 'Next',
    nextUp: 'Next',
    discomfort: 'Discomfort',
    discomfortTitle: 'What feels wrong?',
    discomfortBody:
        'Stop now if you feel sharp pain, numbness, dizziness or chest tightness. Mild soreness: reduce the range and slow down.',
    discomfortContinue: 'Reduce the range, continue',
    discomfortSkip: 'Skip this move',
    discomfortEnd: 'End today\'s session',
    close: 'Close session',
    closeTitle: 'End the session?',
    closeBody: 'It will be saved as not finished.',
    closeConfirm: 'End',
    closeCancel: 'Keep going',
    previous: 'Previous move',
    skip: 'Skip move',
    pause: 'Pause',
    resume: 'Resume',
    doneFull: 'Session complete!',
    donePartial: 'That\'s it for today',
    minutes: 'min',
    exercisesDone: 'moves done',
    finish: 'Done',
    saveFailed: 'The session was not saved',
    saveRetry: 'Retry',
    mediaUnavailable: 'Demo unavailable',
    notificationChannel: 'Training in progress',
    notificationChannelDescription:
        'Keeps the timer and voice coaching running',
    notificationTitle: 'Training in progress',
    notificationText: 'The timer and voice keep going with the screen locked',
  );
}
