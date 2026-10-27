import 'character_state.dart';
import 'body_sensitivity.dart';
import 'story_clock.dart';

/// A small local checkpoint taken before a user turn mutates the game state.
/// It travels with that user message, so save slots and character sessions keep
/// their own undo history without copying entire inventories or chat histories.
final class ConversationTurnSnapshot {
  ConversationTurnSnapshot({
    required CharacterState characterState,
    required StoryClock storyClock,
    required this.characterMood,
    required this.sceneTime,
    required this.storyClockEnabled,
    required this.automaticSceneTime,
    required this.userMessageCount,
    this.canRestoreCharacterState = true,
    this.bodySensitivity,
    this.canRestoreBodySensitivity = true,
  }) : characterState = CharacterState(
         values: Map.unmodifiable(characterState.values),
         bands: Map.unmodifiable(characterState.bands),
         delta: Map.unmodifiable(characterState.delta),
         settled: List.unmodifiable(characterState.settled),
         emotion: characterState.emotion,
         reason: characterState.reason,
         updatedAt: characterState.updatedAt,
         oathRingLossPending: characterState.oathRingLossPending,
       ),
       storyClock = StoryClock(
         totalMinutes: storyClock.totalMinutes,
         satiety: storyClock.satiety,
         settledTurns: List.unmodifiable(storyClock.settledTurns),
       );

  final CharacterState characterState;
  final StoryClock storyClock;
  final String characterMood;
  final String sceneTime;
  final bool storyClockEnabled;
  final bool automaticSceneTime;
  final int userMessageCount;
  final bool canRestoreCharacterState;

  /// Null for older checkpoints, so undo cannot invent past sensitivity.
  final BodySensitivityState? bodySensitivity;
  final bool canRestoreBodySensitivity;

  ConversationTurnSnapshot preserveItemStateChanges() =>
      ConversationTurnSnapshot(
        characterState: characterState,
        storyClock: storyClock,
        characterMood: characterMood,
        sceneTime: sceneTime,
        storyClockEnabled: storyClockEnabled,
        automaticSceneTime: automaticSceneTime,
        userMessageCount: userMessageCount,
        canRestoreCharacterState: false,
        bodySensitivity: bodySensitivity,
        canRestoreBodySensitivity: canRestoreBodySensitivity,
      );

  ConversationTurnSnapshot preserveBodySensitivityChanges() =>
      ConversationTurnSnapshot(
        characterState: characterState,
        storyClock: storyClock,
        characterMood: characterMood,
        sceneTime: sceneTime,
        storyClockEnabled: storyClockEnabled,
        automaticSceneTime: automaticSceneTime,
        userMessageCount: userMessageCount,
        canRestoreCharacterState: canRestoreCharacterState,
        bodySensitivity: bodySensitivity,
        canRestoreBodySensitivity: false,
      );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'characterState': characterState.toJson(),
    'storyClock': storyClock.toJson(),
    'characterMood': characterMood,
    'sceneTime': sceneTime,
    'storyClockEnabled': storyClockEnabled,
    'automaticSceneTime': automaticSceneTime,
    'userMessageCount': userMessageCount,
    'canRestoreCharacterState': canRestoreCharacterState,
    if (bodySensitivity != null) 'bodySensitivity': bodySensitivity!.toJson(),
    'canRestoreBodySensitivity': canRestoreBodySensitivity,
  };

  /// Missing, damaged or future checkpoints must not prevent opening old saves.
  /// They cannot be replaced by invented state from the present conversation.
  static ConversationTurnSnapshot? tryFromJson(Object? raw) {
    if (raw is! Map || raw['version'] != 1) return null;
    try {
      final state = raw['characterState'];
      final clock = raw['storyClock'];
      if (state is! Map || clock is! Map) return null;
      const stats = {'mood', 'energy', 'closeness', 'curiosity'};
      for (final field in ['values', 'bands', 'delta']) {
        final values = state[field];
        if (values is! Map ||
            values.keys.any((key) => !stats.contains(key)) ||
            values.values.any((value) => value is! int) ||
            (field != 'delta' && !values.keys.toSet().containsAll(stats))) {
          return null;
        }
        for (final entry in values.entries) {
          final value = entry.value as int;
          if (field == 'bands' && (value < 0 || value > 2) ||
              field == 'values' &&
                  (value > 100 || entry.key != 'mood' && value < 0)) {
            return null;
          }
        }
      }
      final settled = state['settled'];
      final turns = clock['settledTurns'];
      if (settled is! List ||
          settled.length > 100 ||
          settled.any((v) => v is! String || v.length > 256) ||
          turns is! List ||
          turns.length > 100 ||
          turns.any((v) => v is! String || v.length > 256) ||
          !CharacterState.emotions.contains(state['emotion']) ||
          state['reason'] is! String ||
          (state['reason'] as String).length > 240 ||
          state['oathRingLossPending'] is! bool ||
          state['updatedAt'] != null &&
              (state['updatedAt'] is! String ||
                  DateTime.tryParse(state['updatedAt'] as String) == null) ||
          !const {
            'neutral',
            'happy',
            'concerned',
            'excited',
          }.contains(raw['characterMood']) ||
          !const {
            'morning',
            'afternoon',
            'evening',
            'night',
          }.contains(raw['sceneTime']) ||
          raw['storyClockEnabled'] is! bool ||
          raw['automaticSceneTime'] is! bool ||
          raw.containsKey('canRestoreCharacterState') &&
              raw['canRestoreCharacterState'] is! bool ||
          raw.containsKey('canRestoreBodySensitivity') &&
              raw['canRestoreBodySensitivity'] is! bool ||
          raw['userMessageCount'] is! int ||
          (raw['userMessageCount'] as int) < 0) {
        return null;
      }
      return ConversationTurnSnapshot(
        characterState: CharacterState(
          values: Map<String, int>.from(state['values'] as Map),
          bands: Map<String, int>.from(state['bands'] as Map),
          delta: Map<String, int>.from(state['delta'] as Map),
          settled: List<String>.from(settled),
          emotion: state['emotion'] as String,
          reason: state['reason'] as String,
          updatedAt: state['updatedAt'] == null
              ? null
              : DateTime.parse(state['updatedAt'] as String),
          oathRingLossPending: state['oathRingLossPending'] as bool,
        ),
        storyClock: StoryClock.fromJson(clock),
        characterMood: raw['characterMood'] as String,
        sceneTime: raw['sceneTime'] as String,
        storyClockEnabled: raw['storyClockEnabled'] as bool,
        automaticSceneTime: raw['automaticSceneTime'] as bool,
        userMessageCount: raw['userMessageCount'] as int,
        canRestoreCharacterState: raw['canRestoreCharacterState'] != false,
        bodySensitivity: raw['bodySensitivity'] == null
            ? null
            : BodySensitivityState.fromJson(raw['bodySensitivity']),
        canRestoreBodySensitivity: raw['canRestoreBodySensitivity'] != false,
      );
    } on Object {
      return null;
    }
  }
}
