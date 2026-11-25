import 'package:is_airlock_api/is_airlock_api.dart' show WebFetch;
import 'package:is_annotation_shapes/is_annotation_shapes.dart'
    show
        ApprovedVerdict,
        HeldOffVerdict,
        ProposedCorrectionVerdict,
        VerdictOnShownMessage;
import 'package:is_conversation_shapes/is_conversation_shapes.dart'
    show SourceMessageId;
import 'package:is_effects/is_effects.dart' show Outcome, WebResponse;
import 'package:is_shapes/is_shapes.dart' show ActorId;

import 'test_plan.dart';

/// What came of one step: one the run goes on from ([PassingOutcome]), or
/// one that stops it ([StoppingOutcome]).
sealed class StepOutcome {
  const StepOutcome();
}

/// An outcome the run goes on from: [AgentCheckHeld] or [PersonApproved].
sealed class PassingOutcome extends StepOutcome {
  const PassingOutcome();
}

/// An outcome that stops the run: the deploy failed a check
/// ([AgentCheckFailed]), a person held off ([PersonHeldOff]), a check was
/// cut off partway ([AgentCheckCutOff]), or the step could not be done at
/// all ([AgentCheckNotRun], [AskNotDelivered]).
sealed class StoppingOutcome extends StepOutcome {
  const StoppingOutcome();
}

/// The agent's check held.
final class AgentCheckHeld extends PassingOutcome {
  const AgentCheckHeld();
}

/// The agent's check did not hold; [observed] is what it saw instead, such
/// as `status 502`.
final class AgentCheckFailed extends StoppingOutcome {
  const AgentCheckFailed(this.observed);

  /// What the agent saw instead.
  final String observed;
}

/// The agent's check was never sent: nothing ran, for [why], such as the
/// airlock denying the fetch because no rule grants the deployed site. It
/// says nothing of the deploy, only that the run could not test it.
final class AgentCheckNotRun extends StoppingOutcome {
  const AgentCheckNotRun(this.why);

  /// Why nothing ran.
  final String why;
}

/// The agent's check was cut off partway, for [why]: the request may have
/// reached the site, and no whole response came back. Unlike
/// [AgentCheckNotRun] it may say something of the deploy, such as a site
/// that drops the connection, so it is not read as saying nothing; unlike
/// [AgentCheckFailed] no response was seen to fail.
final class AgentCheckCutOff extends StoppingOutcome {
  const AgentCheckCutOff(this.why);

  /// Why it stopped, as the driver said.
  final String why;
}

/// The step's person answered ✅.
final class PersonApproved extends PassingOutcome {
  const PersonApproved(this.by);

  /// Who answered.
  final ActorId by;
}

/// The step's person answered ❌: they held off, which is what was said, not
/// a reading of why.
final class PersonHeldOff extends StoppingOutcome {
  const PersonHeldOff(this.by);

  /// Who answered.
  final ActorId by;
}

/// The ask for a person step was not wholly posted: posting stopped partway,
/// after [posted], or before anything. The person never saw all of the
/// instruction, so no reaction to what did post answers the step.
final class AskNotDelivered extends StoppingOutcome {
  const AskNotDelivered(this.posted);

  /// The messages of the ask that did post, in order, perhaps none.
  final List<SourceMessageId> posted;
}

/// One run of a project's [ProjectTestConfig]: the outcome of each step done
/// so far, in order, and the messages that asked the person step due, once
/// they are posted.
///
/// Only [TestRun.start] and the answers on its [position] make one, so a
/// run's outcomes are always of its first steps, one each, each of the kind
/// its step takes, and none after one that stopped it.
final class TestRun {
  const TestRun._(this.config, this.outcomes, this._askedIn);

  /// A run of [config]'s plan with no step done yet.
  factory TestRun.start(ProjectTestConfig config) =>
      TestRun._(config, const [], null);

  /// What is being run, and against which site.
  final ProjectTestConfig config;

  /// What came of each step done so far, in order.
  final List<StepOutcome> outcomes;

  /// The messages that asked the person step due, or null before it is
  /// asked.
  final List<SourceMessageId>? _askedIn;

  /// The steps, in order.
  List<TestStep> get steps => config.plan.steps;

  /// Where the run is: a step due, or finished.
  RunPosition get position {
    if (outcomes case [..., final StoppingOutcome last]) {
      return RunStopped._(this, last);
    }
    if (outcomes.length == steps.length) return RunPassed._(this);
    return switch ((steps[outcomes.length], _askedIn)) {
      (final AgentStep step, _) => AgentStepDue._(this, step),
      (final PersonStep step, null) => PersonStepDue._(this, step),
      (final PersonStep step, final askedIn?) => PersonStepAsked._(
        this,
        step,
        askedIn,
      ),
    };
  }

  TestRun _with(StepOutcome outcome) =>
      TestRun._(config, List.unmodifiable([...outcomes, outcome]), null);
}

/// Where a [TestRun] is: a step due, or finished ([RunFinished]). A step
/// that is due is answered through its case, so only the step due can be
/// answered, and only with an outcome of its kind.
sealed class RunPosition {
  const RunPosition();

  /// The run this is the position of.
  TestRun get run;
}

/// The agent's [step] is due.
final class AgentStepDue extends RunPosition {
  const AgentStepDue._(this.run, this.step);

  @override
  final TestRun run;

  /// The step.
  final AgentStep step;

  /// The fetch to propose for [step], on the run's deployed site.
  WebFetch get fetch => step.check.fetchFrom(run.config.deployedTo);

  /// The run, with what came of [step]'s check, judged from its fetch's
  /// [outcome].
  TestRun checked(Outcome<WebResponse> outcome) =>
      run._with(step.check.judge(outcome));
}

/// [step] is due and its person has not been asked yet.
final class PersonStepDue extends RunPosition {
  const PersonStepDue._(this.run, this.step);

  @override
  final TestRun run;

  /// The step.
  final PersonStep step;

  /// The run, with [step] asked in [posted], every message of the ask in
  /// posting order; null when there are none.
  TestRun? asked(List<SourceMessageId> posted) => posted.isEmpty
      ? null
      : TestRun._(run.config, run.outcomes, List.unmodifiable(posted));

  /// The run, with the ask for [step] posted only as far as [posted].
  TestRun notDelivered(List<SourceMessageId> posted) =>
      run._with(AskNotDelivered(List.unmodifiable(posted)));
}

/// [step] has been asked in [askedIn] and is waiting on its person.
final class PersonStepAsked extends RunPosition {
  const PersonStepAsked._(this.run, this.step, this.askedIn);

  @override
  final TestRun run;

  /// The step.
  final PersonStep step;

  /// The messages that asked it, in posting order.
  final List<SourceMessageId> askedIn;

  /// The run, with [verdict] from [from] on message [to] as [step]'s answer;
  /// null when it is no answer: [to] is not one of [askedIn], [from] is not
  /// the step's person, or it proposes a correction.
  TestRun? judged(
    ActorId from,
    SourceMessageId to,
    VerdictOnShownMessage verdict,
  ) {
    if (from != step.person || !askedIn.contains(to)) return null;
    return switch (verdict) {
      ApprovedVerdict() => run._with(PersonApproved(from)),
      HeldOffVerdict() => run._with(PersonHeldOff(from)),
      ProposedCorrectionVerdict() => null,
    };
  }
}

/// The run is over: it passed ([RunPassed]) or a step stopped it
/// ([RunStopped]).
sealed class RunFinished extends RunPosition {
  const RunFinished();
}

/// Every step was done and none stopped the run.
final class RunPassed extends RunFinished {
  const RunPassed._(this.run);

  @override
  final TestRun run;
}

/// A step stopped the run, [because] of its outcome, the run's last.
final class RunStopped extends RunFinished {
  const RunStopped._(this.run, this.because);

  @override
  final TestRun run;

  /// The outcome that stopped it.
  final StoppingOutcome because;

  /// The step that stopped it.
  TestStep get stoppedAt => run.steps[run.outcomes.length - 1];
}
