import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_idle_behavior.dart';

void main() {
  test('new pose-specific sway weights override legacy weights', () {
    final band = <String, dynamic>{
      'torsoWaistGroupWeights': {'grp_eh_20': 0},
      'torsoWaistGroupWeightsByPoseType': {
        'posetype_01_freehand': {'grp_eh_20': 0.3},
        '': {'grp_eh_30': 0},
      },
    };
    expect(idleTorsoWeights(band, ['posetype_01_freehand']), {
      'grp_eh_20': 0.3,
    });
    expect(idleTorsoWeights(band, ['unknown']), {'grp_eh_30': 0.0});
  });

  test('explicit empty overrides remain disabled and legacy still works', () {
    expect(
      idleTorsoWeights(
        {
          'torsoWaistGroupWeightsByPoseType': {'seated': {}},
          'torsoWaistGroupWeights': {'sway': 1},
        },
        ['seated'],
      ),
      isEmpty,
    );
    expect(
      idleTorsoWeights({
        'torsoWaistGroupWeights': {'sway': 1},
      }, []),
      {'sway': 1.0},
    );
    expect(idleTorsoWeights({}, []), isNull);
  });
}
