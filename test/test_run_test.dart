import 'package:is_annotation_shapes/is_annotation_shapes.dart'
    show ApprovedVerdict, HeldOffVerdict, ProposedCorrectionVerdict;
import 'package:is_conversation_shapes/is_conversation_shapes.dart'
    show SourceMessageId;
import 'package:is_deploy_test_module/is_deploy_test_module.dart';
import 'package:is_effects/is_effects.dart' show Ran, WebResponse;
import 'package:is_shapes/is_shapes.dart' show ActorId;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart'
    show Origin, WebPath;
import 'package:test/test.dart';

void main() {
  final nick = ActorId.parse('slack:T0001/U0NICK')!;
  const ok = Ran(WebResponse(status: 200));
  final someoneElse = ActorId.parse('slack:T0001/U0OTHER')!;
  SourceMessageId message(String ts) => SourceMessageId.parse('C0001|$ts')!;
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

  PersonStepDue personDue(TestRun run) => run.position as PersonStepDue;
  PersonStepAsked personAsked(TestRun run) => run.position as PersonStepAsked;

  test('an empty plan is no plan', () {
    expect(TestPlan.of(const []), isNull);
  });

  test('agent then person, both passing, passes', () {
    final run = runOf([health, signIn]);
    final afterAgent = (run.position as AgentStepDue).checked(ok);
    final asked = personDue(afterAgent).asked([message('1.1')])!;
    final done = personAsked(asked)
        .judged(nick, message('1.1'), const ApprovedVerdict())!;
    expect(done.position, isA<RunPassed>());
  });

  test('only the named person, on the ask, answers a person step', () {
    final run = runOf([signIn]);
    final asked = personAsked(personDue(run).asked([message('1.1')])!);
    expect(
      asked.judged(someoneElse, message('1.1'), const ApprovedVerdict()),
      isNull,
    );
    expect(asked.judged(nick, message('9.9'), const ApprovedVerdict()), isNull);
    expect(
      asked.judged(nick, message('1.1'), ProposedCorrectionVerdict(const {})),
      isNull,
    );
  });

  test('a reaction on any part of a split ask answers it', () {
    final run = runOf([signIn]);
    final asked = personAsked(
      personDue(run).asked([message('1.1'), message('1.2')])!,
    );
    final done = asked.judged(nick, message('1.2'), const ApprovedVerdict())!;
    expect(done.position, isA<RunPassed>());
  });

  test('a late reaction on an earlier ask does not answer the next', () {
    final run = runOf([signIn, openThread]);
    final first = personAsked(personDue(run).asked([message('1.1')])!);
    final second = personAsked(
      personDue(first.judged(nick, message('1.1'), const ApprovedVerdict())!)
          .asked([message('2.1')])!,
    );
    expect(second.judged(nick, message('1.1'), const HeldOffVerdict()), isNull);
  });

  test('an ask with no messages is not asked', () {
    final run = runOf([signIn]);
    expect(personDue(run).asked(const []), isNull);
  });

  test('an ask posted only partway stops the run', () {
    final run = runOf([signIn, health]);
    final stopped = personDue(run).notDelivered([message('1.1')]).position;
    expect(stopped, isA<RunNotFinished>());
    expect((stopped as RunNotFinished).because, isA<AskNotDelivered>());
  });

  test('a held-off person step stops the run there', () {
    final run = runOf([signIn, health]);
    final asked = personAsked(personDue(run).asked([message('1.1')])!);
    final stopped = asked
        .judged(nick, message('1.1'), const HeldOffVerdict())!
        .position;
    expect((stopped as RunNotPassed).endedAt, signIn);
  });

  test('a failed agent check stops the run before the person is asked', () {
    final due = runOf([health, signIn]).position;
    final run = (due as AgentStepDue).checked(
      const Ran(WebResponse(status: 502)),
    );
    expect(run.position, isA<RunNotPassed>());
    expect(run.outcomes, hasLength(1));
  });
}
