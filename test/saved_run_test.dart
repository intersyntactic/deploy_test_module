import 'dart:convert' show jsonEncode;

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_annotation_shapes/is_annotation_shapes.dart'
    show ApprovedVerdict, HeldOffVerdict;
import 'package:is_conversation_shapes/is_conversation_shapes.dart'
    show SourceMessageId;
import 'package:is_deploy_test_module/is_deploy_test_module.dart';
import 'package:is_effects/is_effects.dart'
    show NothingRan, Ran, StoppedPartway, WebResponse;
import 'package:is_shapes/is_shapes.dart' show ActorId;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart'
    show Origin, WebPath;
import 'package:test/test.dart';

void main() {
  final nick = ActorId.parse('slack:T0001/U0NICK')!;
  final someoneElse = ActorId.parse('slack:T0001/U0OTHER')!;
  SourceMessageId message(String ts) => SourceMessageId.parse('C0001|$ts')!;
  const ok = FetchCameBack(Ran(WebResponse(status: 200)));
  final health = AgentStep(
    ResponseStatusIs(
      path: WebPath.parse('/health')!,
      status: HttpStatusCode.ok,
    ),
  );
  final signIn = PersonStep(person: nick, instruction: 'Sign in.');
  final start = TestRun.start(
    ProjectTestConfig(
      project: DeployedProjectName.parse('relay')!,
      deployedTo: Origin.parse('https://relay.example')!,
      plan: TestPlan.of([health, signIn])!,
    ),
  );
  final asking = start.after(ok)!;
  final asked = asking.after(
    AskPostingEnded(Ran([message('1.1'), message('1.2')])),
  )!;

  /// [run] saved as wire text and read back.
  TestRun saved(TestRun run) =>
      TestRun.fromJson(JsonObject.decode(jsonEncode(run.toJson())));

  /// [run]'s JSON with [field] replaced by [value].
  JsonObject edited(TestRun run, String field, Object? value) =>
      JsonObject.of({...run.toJson().asUncheckedMap(), field: value});

  group('reads back what it wrote, at every position', () {
    final runs = {
      'a check in flight': start,
      'an ask in flight': asking,
      'waiting on a person': asked,
      'passed': asked.after(
        Reacted(nick, message('1.2'), const ApprovedVerdict()),
      )!,
      'held off': asked.after(
        Reacted(nick, message('1.1'), const HeldOffVerdict()),
      )!,
      'check failed': start.after(
        const FetchCameBack(Ran(WebResponse(status: 502))),
      )!,
      'check not run': start.after(const FetchCameBack(NothingRan('denied')))!,
      'check cut off': start.after(
        const FetchCameBack(
          StoppedPartway<WebResponse>(why: 'reset', done: null),
        ),
      )!,
      'check lost to a restart': start.after(const Restarted())!,
      'ask partly posted': asking.after(
        AskPostingEnded(
          StoppedPartway(why: 'rate limited', done: [message('1.1')]),
        ),
      )!,
      'ask lost to a restart': asking.after(const Restarted())!,
      'reported': asked
          .after(Reacted(nick, message('1.1'), const ApprovedVerdict()))!
          .after(ResultsPostingEnded(Ran([message('9.1')])))!,
    };
    for (final MapEntry(key: name, value: run) in runs.entries) {
      test(name, () {
        final back = saved(run);
        expect(back.toJson(), run.toJson());
        expect(back.position.runtimeType, run.position.runtimeType);
      });
    }
  });

  test('a restored run waiting on a person still takes their answer', () {
    final back = saved(asked);
    expect(
      back
          .after(Reacted(nick, message('1.2'), const ApprovedVerdict()))!
          .position,
      isA<RunPassed>(),
    );
    expect(
      back.after(Reacted(nick, message('9.9'), const ApprovedVerdict())),
      isNull,
    );
  });

  test('a restored run with an ask in flight ends on Restarted', () {
    final back = saved(asking).after(const Restarted())!;
    expect((back.position as RunNotFinished).because, isA<AskResultLost>());
  });

  group('refuses', () {
    test('a valid edit reads, so each refusal below is its own', () {
      expect(
        TestRun.fromJson(
          edited(asked, 'outcomes', [
            {'outcome': 'agentCheckHeld'},
          ]),
        ).position,
        isA<PersonStepAsked>(),
      );
    });

    void refuses(String why, JsonObject json) => test(
      why,
      () => expect(() => TestRun.fromJson(json), throwsFormatException),
    );

    refuses('an extra field', edited(start, 'note', 'hi'));
    refuses(
      'an unknown outcome',
      edited(start, 'outcomes', [
        {'outcome': 'agentCheckPassed'},
      ]),
    );
    refuses(
      'an extra field on an outcome',
      edited(start, 'outcomes', [
        {'outcome': 'agentCheckHeld', 'observed': 'ok'},
      ]),
    );
    refuses(
      'more outcomes than steps',
      edited(start, 'outcomes', [
        {'outcome': 'agentCheckHeld'},
        {'outcome': 'personApproved', 'by': nick.value},
        {'outcome': 'agentCheckHeld'},
      ]),
    );
    refuses(
      'a person outcome on an agent step',
      edited(start, 'outcomes', [
        {'outcome': 'personApproved', 'by': nick.value},
      ]),
    );
    refuses(
      'an agent outcome on a person step',
      edited(start, 'outcomes', [
        {'outcome': 'agentCheckHeld'},
        {'outcome': 'agentCheckHeld'},
      ]),
    );
    refuses(
      'an approval from someone else',
      edited(start, 'outcomes', [
        {'outcome': 'agentCheckHeld'},
        {'outcome': 'personApproved', 'by': someoneElse.value},
      ]),
    );
    refuses(
      'an outcome after one that stopped the run',
      edited(start, 'outcomes', [
        {'outcome': 'agentCheckFailed', 'observed': 'status 502'},
        {'outcome': 'personApproved', 'by': nick.value},
      ]),
    );
    refuses(
      'askedIn while an agent step is in flight',
      edited(start, 'askedIn', ['C0001|1.1']),
    );
    refuses('askedIn that is empty', edited(asked, 'askedIn', <String>[]));
    refuses(
      'askedIn on a run that is over',
      edited(
        asked.after(Reacted(nick, message('1.1'), const HeldOffVerdict()))!,
        'askedIn',
        ['C0001|1.1'],
      ),
    );
    refuses(
      'a message id with whitespace',
      edited(asked, 'askedIn', ['C0001 1.1']),
    );
    refuses(
      'resultsPosted on a run not over',
      edited(asked, 'resultsPosted', true),
    );
    refuses(
      'resultsPosted written false',
      edited(
        start.after(const FetchCameBack(NothingRan('denied')))!,
        'resultsPosted',
        false,
      ),
    );
  });

  test('resultsPosted on a run that is over reads as reported', () {
    final over = start.after(const FetchCameBack(NothingRan('denied')))!;
    expect(
      TestRun.fromJson(edited(over, 'resultsPosted', true)).position,
      isA<RunReported>(),
    );
  });
}
