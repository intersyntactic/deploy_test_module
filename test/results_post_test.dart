import 'package:is_annotation_shapes/is_annotation_shapes.dart'
    show ApprovedVerdict, HeldOffVerdict, VerdictOnShownMessage;
import 'package:is_conversation_vocabulary/is_conversation_vocabulary.dart'
    show SourceMessageId;
import 'package:is_deploy_test_module/is_deploy_test_module.dart';
import 'package:is_effects/is_effects.dart'
    show NothingRan, Ran, StoppedPartway, TextBody, WebResponse;
import 'package:is_shapes/is_shapes.dart' show ActorId;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart'
    show Origin, WebPath;
import 'package:test/test.dart';

void main() {
  final nick = ActorId.parse('slack:T0001/U0NICK')!;
  final ask = SourceMessageId.parse('C0001|1.1')!;
  final health = AgentStep(
    ResponseStatusIs(
      path: WebPath.parse('/health')!,
      status: HttpStatusCode.ok,
    ),
  );
  final ready = AgentStep(
    ResponseBodyContains(path: WebPath.root, text: 'ready'),
  );
  final signIn = PersonStep(person: nick, instruction: 'Sign in.');
  final run = TestRun.start(
    ProjectTestConfig(
      project: DeployedProjectName.parse('slack-relay')!,
      deployedTo: Origin.parse('https://relay.example')!,
      plan: TestPlan.of([health, ready, signIn])!,
    ),
  );

  TestRun agentDoes(TestRun r, WebResponse response) =>
      r.after(FetchCameBack(Ran(response)))!;
  TestRun personSays(TestRun r, VerdictOnShownMessage verdict) =>
      r.after(AskPostingEnded(Ran([ask])))!.after(Reacted(nick, ask, verdict))!;

  String textOf(TestRun r) => resultsPostText(r.position as RunOver);

  final bothChecksPass = agentDoes(
    agentDoes(run, const WebResponse(status: 200)),
    const WebResponse(status: 200, body: TextBody('ready')),
  );

  test('a passed run says so, with every step', () {
    expect(
      textOf(personSays(bothChecksPass, const ApprovedVerdict())),
      'Deploy test of slack-relay (https://relay.example) passed: all 3 '
      'steps.\n'
      '1. GET /health answers 200: passed\n'
      '2. GET / says "ready": passed\n'
      '3. Person check: Sign in.: approved ✅',
    );
  });

  test('a failed check says where, and what it saw', () {
    expect(
      textOf(
        agentDoes(
          run,
          const WebResponse(status: 502, refusedBecause: 'Bad Gateway'),
        ),
      ),
      'Deploy test of slack-relay (https://relay.example) failed at step 1 '
      'of 3.\n'
      '1. GET /health answers 200: failed, status 502: Bad Gateway\n'
      '2. GET / says "ready": not reached\n'
      '3. Person check: Sign in.: not reached',
    );
  });

  test('a held-off person step says held off, not failed', () {
    expect(
      textOf(personSays(bothChecksPass, const HeldOffVerdict()))
          .split('\n')
          .first,
      'Deploy test of slack-relay (https://relay.example) was held off at '
      'step 3 of 3.',
    );
  });

  test('a check that never ran says nothing about the deploy', () {
    final notRun = run.after(
      const FetchCameBack(NothingRan('no rule grants https://relay.example')),
    )!;
    final text = textOf(notRun);
    expect(
      text.split('\n').first,
      "Deploy test of slack-relay (https://relay.example) didn't finish: "
      'step 1 of 3 was never run, so this says nothing about the deploy.',
    );
    expect(text, contains('not run, no rule grants https://relay.example'));
    expect(text, isNot(contains('failed')));
  });

  test('a check cut off partway is neither failed nor nothing', () {
    final cutOff = run.after(
      const FetchCameBack(
        StoppedPartway<WebResponse>(why: 'connection reset', done: null),
      ),
    )!;
    final text = textOf(cutOff);
    expect(
      text.split('\n').first,
      "Deploy test of slack-relay (https://relay.example) didn't finish: "
      'step 1 of 3 was cut off before a whole response came back.',
    );
    expect(
      text,
      contains('1. GET /health answers 200: cut off, connection reset'),
    );
    expect(text, isNot(contains('failed')));
    expect(text, isNot(contains('says nothing')));
  });

  test('an ask that never posted is not asked, and not a failure', () {
    final undelivered = bothChecksPass.after(
      const AskPostingEnded(NothingRan('chat module unreachable')),
    )!;
    final text = textOf(undelivered);
    expect(
      text.split('\n').first,
      "Deploy test of slack-relay (https://relay.example) didn't finish: "
      'step 3 of 3 was never fully asked, so this says nothing about the '
      'deploy.',
    );
    expect(
      text,
      contains("3. Person check: Sign in.: not asked, the ask didn't post"),
    );
    expect(text, isNot(contains('failed')));
  });

  test('an ask that partly posted says so', () {
    final partway = bothChecksPass.after(
      AskPostingEnded(
        StoppedPartway<List<SourceMessageId>>(why: 'rate limited', done: [ask]),
      ),
    )!;
    expect(textOf(partway), contains('not asked, the ask only partly posted'));
  });

  test('a restart mid-step says nothing about the deploy', () {
    final lost = bothChecksPass.after(const Restarted())!;
    final text = textOf(lost);
    expect(
      text.split('\n').first,
      "Deploy test of slack-relay (https://relay.example) didn't finish: "
      'step 3 of 3 was interrupted by a restart, so this says nothing about '
      'the deploy.',
    );
    expect(text, contains('interrupted by a restart while being asked'));
  });

  test('the text names no one', () {
    final text = textOf(personSays(bothChecksPass, const ApprovedVerdict()));
    expect(text, isNot(contains(nick.value)));
    expect(text, isNot(contains('U0NICK')));
  });
}
