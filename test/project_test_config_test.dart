import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_deploy_test_module/is_deploy_test_module.dart';
import 'package:test/test.dart';

void main() {
  const example = '''
{
  "project": "slack-relay",
  "deployedTo": "https://relay.example",
  "steps": [
    {"step": "responseStatusIs", "path": "/health", "status": 200},
    {"step": "responseBodyContains", "path": "/health", "text": "ready"},
    {"step": "person", "person": "slack:T0001/U024BE7LH",
     "instruction": "Mention the bot in a thread; does it answer?"}
  ]
}''';

  ProjectTestConfig read(String text) =>
      ProjectTestConfig.fromJson(JsonObject.decode(text));

  JsonObject withSteps(List<Map<String, Object?>> steps) => JsonObject.of({
    'project': 'slack-relay',
    'deployedTo': 'https://relay.example',
    'steps': steps,
  });

  test('reads each kind of step, in order', () {
    final config = read(example);
    expect(config.project.value, 'slack-relay');
    expect(config.deployedTo.toString(), 'https://relay.example');
    final [first, second, third] = config.plan.steps;
    expect(
      (first as AgentStep).check,
      isA<ResponseStatusIs>().having((c) => c.status.value, 'status', 200),
    );
    expect(
      (second as AgentStep).check,
      isA<ResponseBodyContains>().having((c) => c.text, 'text', 'ready'),
    );
    expect((third as PersonStep).person.value, 'slack:T0001/U024BE7LH');
  });

  test('a valid step reads, so each refusal below is its own', () {
    expect(
      ProjectTestConfig.fromJson(
        withSteps([
          {'step': 'responseStatusIs', 'path': '/', 'status': 200},
        ]),
      ).plan.steps,
      hasLength(1),
    );
  });

  test('writes back what it reads', () {
    final json = JsonObject.decode(example);
    expect(ProjectTestConfig.fromJson(json).toJson(), json);
  });

  group('refuses', () {
    void refuses(JsonObject json) =>
        expect(() => ProjectTestConfig.fromJson(json), throwsFormatException);

    test('no steps', () => refuses(withSteps([])));

    test(
      'an unknown step',
      () => refuses(
        withSteps([
          {'step': 'ssh'},
        ]),
      ),
    );

    test('a field a step does not have', () {
      refuses(
        withSteps([
          {'step': 'responseStatusIs', 'path': '/', 'status': 200, 'x': 1},
        ]),
      );
    });

    test('a status out of range', () {
      refuses(
        withSteps([
          {'step': 'responseStatusIs', 'path': '/', 'status': 99},
        ]),
      );
    });

    test('a path that could leave the site', () {
      refuses(
        withSteps([
          {'step': 'responseStatusIs', 'path': '/@evil.example', 'status': 200},
        ]),
      );
    });

    test('a person who is not an actor id', () {
      refuses(
        withSteps([
          {'step': 'person', 'person': 'Nick', 'instruction': 'Look.'},
        ]),
      );
    });

    test('a site with a path', () {
      refuses(
        JsonObject.of({
          'project': 'slack-relay',
          'deployedTo': 'https://relay.example/app',
          'steps': [
            {'step': 'responseStatusIs', 'path': '/', 'status': 200},
          ],
        }),
      );
    });

    test('a field the config does not have', () {
      refuses(
        withSteps([
          {'step': 'responseStatusIs', 'path': '/', 'status': 200},
        ]).withFields({'branch': 'main'}),
      );
    });
  });
}
