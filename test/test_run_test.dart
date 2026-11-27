import 'package:is_annotation_shapes/is_annotation_shapes.dart'
    show ApprovedVerdict, HeldOffVerdict, ProposedCorrectionVerdict;
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
  const ok = FetchCameBack(Ran(WebResponse(status: 200)));
  SourceMessageId message(String ts) => SourceMessageId.parse('C0001|$ts')!;
  AskPostingEnded postedIn(List<String> ts) =>
      AskPostingEnded(Ran([for (final t in ts) message(t)]));
  Reacted approves(String ts) =>
      Reacted(nick, message(ts), const ApprovedVerdict());
  final health = AgentStep(
    ResponseStatusIs(
      path: WebPath.parse('/health')!,
      status: HttpStatusCode.ok,
    ),
  );
  final signIn = PersonStep(person: nick, instruction: 'Sign in.');
  final openThread = PersonStep(person: nick, instruction: 'Open a thread.');
  TestRun runOf(List<TestStep> steps) => TestRun.start(
    ProjectTestConfig(
      project: DeployedProjectName.parse('relay')!,
      deployedTo: Origin.parse('https://relay.example')!,
      plan: TestPlan.of(steps)!,
    ),
  );

  test('an empty plan is no plan', () {
    expect(TestPlan.of(const []), isNull);
  });

  test("a run starts with its first step's work in flight", () {
    expect(runOf([health]).position, isA<AgentCheckSent>());
    expect(runOf([signIn]).position, isA<PersonAskSent>());
  });

  test('agent then person, both passing, passes', () {
    final run = runOf([health, signIn])
        .after(ok)!
        .after(postedIn(['1.1']))!
        .after(approves('1.1'))!;
    expect(run.position, isA<RunPassed>());
  });

  test('only the named person, on the ask, answers a person step', () {
    final asked = runOf([signIn]).after(postedIn(['1.1']))!;
    expect(
      asked.after(
        Reacted(someoneElse, message('1.1'), const ApprovedVerdict()),
      ),
      isNull,
    );
    expect(asked.after(approves('9.9')), isNull);
    expect(
      asked.after(
        Reacted(nick, message('1.1'), ProposedCorrectionVerdict(const {})),
      ),
      isNull,
    );
  });

  test('a reaction on any part of a split ask answers it', () {
    final run = runOf([signIn])
        .after(postedIn(['1.1', '1.2']))!
        .after(approves('1.2'))!;
    expect(run.position, isA<RunPassed>());
  });

  test('a late reaction on an earlier ask does not answer the next', () {
    final second = runOf([signIn, openThread])
        .after(postedIn(['1.1']))!
        .after(approves('1.1'))!
        .after(postedIn(['2.1']))!;
    expect(
      second.after(Reacted(nick, message('1.1'), const HeldOffVerdict())),
      isNull,
    );
  });

  test('an event for work not in flight changes nothing', () {
    final checking = runOf([health, signIn]);
    expect(checking.after(postedIn(['1.1'])), isNull);
    expect(checking.after(approves('1.1')), isNull);
    final asking = checking.after(ok)!;
    expect(asking.after(ok), isNull);
    final over = asking.after(postedIn(['1.1']))!.after(approves('1.1'))!;
    expect(over.after(ok), isNull);
    expect(checking.after(ResultsPostingEnded(Ran([message('9.1')]))), isNull);
    final reported = over.after(ResultsPostingEnded(Ran([message('9.1')])))!;
    expect(reported.after(ResultsPostingEnded(Ran([message('9.2')]))), isNull);
    expect(reported.after(const Restarted()), isNull);
  });

  group('the results of a run that is over', () {
    final over = runOf([health]).after(ok)!;
    final reported = over.after(ResultsPostingEnded(Ran([message('9.1')])))!;

    test('are to post until they wholly post', () {
      expect(over.position, isA<RunPassed>());
      expect(reported.position, isA<RunReported>());
      expect((reported.position as RunReported).over, isA<RunPassed>());
    });

    test('post again after a restart that found them unposted', () {
      expect(over.after(const Restarted())!.position, isA<RunPassed>());
    });

    test('that did not wholly post wait for the next restart', () {
      expect(
        over.after(const ResultsPostingEnded(NothingRan('chat down'))),
        isNull,
      );
      expect(
        over.after(
          ResultsPostingEnded(
            StoppedPartway(why: 'rate limited', done: [message('9.1')]),
          ),
        ),
        isNull,
      );
      expect(over.after(const ResultsPostingEnded(Ran([]))), isNull);
    });
  });

  test('an ask posted in no messages is not delivered', () {
    final run = runOf([signIn]).after(postedIn([]))!;
    expect((run.position as RunNotFinished).because, isA<AskNotDelivered>());
  });

  test('an ask that never posted is not delivered', () {
    final run = runOf([signIn])
        .after(const AskPostingEnded(NothingRan('chat module unreachable')))!;
    final because = (run.position as RunNotFinished).because;
    expect((because as AskNotDelivered).posted, isEmpty);
  });

  test('an ask posted only partway stops the run, keeping what posted', () {
    final run = runOf([signIn, health]).after(
      AskPostingEnded(
        StoppedPartway(why: 'rate limited', done: [message('1.1')]),
      ),
    )!;
    final because = (run.position as RunNotFinished).because;
    expect((because as AskNotDelivered).posted, [message('1.1')]);
  });

  test('a held-off person step stops the run there', () {
    final run = runOf([signIn, health])
        .after(postedIn(['1.1']))!
        .after(Reacted(nick, message('1.1'), const HeldOffVerdict()))!;
    expect((run.position as RunNotPassed).endedAt, signIn);
  });

  test('a failed agent check stops the run before the person is asked', () {
    final run = runOf([health, signIn])
        .after(const FetchCameBack(Ran(WebResponse(status: 502))))!;
    expect(run.position, isA<RunNotPassed>());
    expect(run.outcomes, hasLength(1));
  });

  test('a restart with a check in flight ends the run, never refetching', () {
    final run = runOf([health, signIn]).after(const Restarted())!;
    final over = run.position as RunNotFinished;
    expect(over.because, isA<AgentCheckResultLost>());
    expect(run.after(ok), isNull);
  });

  test('a restart with an ask in flight ends the run, never reposting', () {
    final run = runOf([health, signIn]).after(ok)!.after(const Restarted())!;
    expect((run.position as RunNotFinished).because, isA<AskResultLost>());
  });

  test('a restart while waiting on a person keeps waiting', () {
    final asked = runOf([signIn]).after(postedIn(['1.1']))!;
    expect(asked.after(const Restarted()), isNull);
    expect(asked.after(approves('1.1'))!.position, isA<RunPassed>());
  });
}
