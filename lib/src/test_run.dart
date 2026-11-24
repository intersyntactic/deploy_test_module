import 'package:is_annotation_shapes/is_annotation_shapes.dart'
    show
        ApprovedVerdict,
        HeldOffVerdict,
        ProposedCorrectionVerdict,
        VerdictOnShownMessage;
import 'package:is_conversation_shapes/is_conversation_shapes.dart'
    show SourceMessageId;
import 'package:is_shapes/is_shapes.dart' show ActorId;

import 'test_plan.dart';

/// What came of one step.
sealed class StepOutcome {
  const StepOutcome();

  /// Whether the run goes on to the next step after this one.
  bool get continuesRun;
}

/// The agent's check held.
final class AgentCheckHeld extends StepOutcome {
  const AgentCheckHeld();

  @override
  bool get continuesRun => true;
}

/// The agent's check did not hold; [observed] is what it saw instead, such
/// as `status 502`.
final class AgentCheckFailed extends StepOutcome {
  const AgentCheckFailed(this.observed);

  /// What the agent saw instead.
  final String observed;

  @override
  bool get continuesRun => false;
}

/// The step's person answered ✅.
final class PersonApproved extends StepOutcome {
  const PersonApproved(this.by);

  /// Who answered.
  final ActorId by;

  @override
  bool get continuesRun => true;
}

/// The step's person answered ❌: they held off, which is what was said, not
/// a reading of why.
final class PersonHeldOff extends StepOutcome {
  const PersonHeldOff(this.by);

  /// Who answered.
  final ActorId by;

  @override
  bool get continuesRun => false;
}

/// The ask for a person step was not wholly posted: posting stopped partway,
/// after [posted], or before anything. The person never saw all of the
/// instruction, so no reaction to what did post answers the step.
final class AskNotDelivered extends StepOutcome {
  const AskNotDelivered(this.posted);

  /// The messages of the ask that did post, in order, perhaps none.
  final List<SourceMessageId> posted;

  @override
  bool get continuesRun => false;
}

/// One run of a [TestPlan]: the outcome of each step done so far, in order,
/// and the messages that asked the person step due, once they are posted.
///
/// Only [TestRun.start] and the answers on its [position] make one, so a
/// run's outcomes are always of its first steps, one each, each of the kind
/// its step takes, and none after one that stopped it.
final class TestRun {
  const TestRun._(this.plan, this.outcomes, this._askedIn);

  /// A run of [plan] with no step done yet.
  factory TestRun.start(TestPlan plan) => TestRun._(plan, const [], null);

  /// What is being run.
  final TestPlan plan;

  /// What came of each step done so far, in order.
  final List<StepOutcome> outcomes;

  /// The messages that asked the person step due, or null before it is
  /// asked.
  final List<SourceMessageId>? _askedIn;

  /// Where the run is: a step due, or finished.
  RunPosition get position {
    if (outcomes case [..., final last] when !last.continuesRun) {
      return RunStopped._(this);
    }
    if (outcomes.length == plan.steps.length) return RunPassed._(this);
    return switch ((plan.steps[outcomes.length], _askedIn)) {
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
      TestRun._(plan, List.unmodifiable([...outcomes, outcome]), null);
}

/// Where a [TestRun] is. A step that is due is answered through its case, so
/// only the step due can be answered, and only with an outcome of its kind.
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

  /// The run, with [step]'s check having held.
  TestRun held() => run._with(const AgentCheckHeld());

  /// The run, with [step]'s check having failed, having seen [observed].
  TestRun failed(String observed) => run._with(AgentCheckFailed(observed));
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
      : TestRun._(run.plan, run.outcomes, List.unmodifiable(posted));

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

/// Every step was done and none stopped the run.
final class RunPassed extends RunPosition {
  const RunPassed._(this.run);

  @override
  final TestRun run;
}

/// A step stopped the run: its outcome is the run's last.
final class RunStopped extends RunPosition {
  const RunStopped._(this.run);

  @override
  final TestRun run;

  /// The step that stopped it.
  TestStep get stoppedAt => run.plan.steps[run.outcomes.length - 1];
}
