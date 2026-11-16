import 'package:brahma_core/brahma_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('study progress survives the round trip and the same progress gives the same text', () {
    const p = StudyProgress(
      learning: [
        (
          title: 'Care Certificate',
          kind: 'certification',
          provider: 'Skills for Health',
          finished: '2026-11-03',
        ),
      ],
      skills: [(name: 'SystmOne', category: 'Digital', level: 3)],
    );
    final again = StudyProgress.parse(p.encode());
    expect(again.learning, p.learning);
    expect(again.skills, p.skills);
    expect(again.encode(), p.encode());
  });

  test('damaged or newer progress reads as far as it can, never throws', () {
    for (final text in ['', 'not json', '[]', '{"learning": 3}', '{"skills": [1, "x", {}]}']) {
      final p = StudyProgress.parse(text);
      expect([...p.learning, ...p.skills], isEmpty, reason: text);
    }
    final newer = StudyProgress.parse(
      '{"learning":[{"title":"A","kind":"course","extra":1}],"skills":[{"name":"B","level":"high"}],"badges":[]}',
    );
    expect(newer.learning.single.title, 'A');
    expect(newer.skills.single, (name: 'B', category: '', level: 0));
  });
}
