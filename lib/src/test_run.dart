import 'package:checked_json/checked_json.dart'
    show JsonFieldException, JsonObject;
import 'package:is_airlock_api/is_airlock_api.dart' show WebFetch;
import 'package:is_annotation_shapes/is_annotation_shapes.dart'
    show
        ApprovedVerdict,
        HeldOffVerdict,
        ProposedCorrectionVerdict,
        VerdictOnShownMessage;
import 'package:is_conversation_vocabulary/is_conversation_vocabulary.dart'
    show SourceMessageId;
import 'package:is_effects/is_effects.dart'
    show NothingRan, Outcome, Ran, StoppedPartway, WebResponse;
import 'package:is_shapes/is_shapes.dart' show ActorId;

import 'strict_json.dart';
import 'test_plan.dart';

/// What came of one step: it passed ([PassingOutcome]), it finished with a
/// result against the deploy ([NotPassingOutcome]), or it never finished
/// ([NotFinishedOutcome]). The run goes on only from one that passed.
sealed class StepOutcome {
  const StepOutcome();
}

/// The step passed: [AgentCheckHeld] or [PersonApproved].
sealed class PassingOutcome extends StepOutcome {
  const PassingOutcome();
}

/// The step finished, with a result against the deploy: a check's response
/// was wrong ([AgentCheckFailed]), or its person answered ❌
/// ([PersonHeldOff]). Not called failing: whether a ❌ is a failure is not
/// decided here.
sealed class NotPassingOutcome extends StepOutcome {
  const NotPassingOutcome();
}

/// The step never finished, so there is no result to judge: a check never
/// sent ([AgentCheckNotRun]) or cut off partway ([AgentCheckCutOff]), or an
/// ask that never wholly posted ([AskNotDelivered]).
sealed class NotFinishedOutcome extends StepOutcome {
  const NotFinishedOutcome();
}

/// The agent's check held.
final class AgentCheckHeld extends PassingOutcome {
  const AgentCheckHeld();
}

/// The agent's check did not hold; [observed] is what it saw instead, such
/// as `status 502`.
final class AgentCheckFailed extends NotPassingOutcome {
  const AgentCheckFailed(this.observed);

  /// What the agent saw instead.
  final String observed;
}

/// The agent's check was never sent: nothing ran, for [why], such as the
/// airlock denying the fetch because no rule grants the deployed site. It
/// says nothing of the deploy, only that the run could not test it.
final class AgentCheckNotRun extends NotFinishedOutcome {
  const AgentCheckNotRun(this.why);

  /// Why nothing ran.
  final String why;
}

/// The agent's check was cut off partway, for [why]: the request may have
/// reached the site, and no whole response came back. Unlike
/// [AgentCheckNotRun] it may say something of the deploy, such as a site
/// that drops the connection, so it is not read as saying nothing; unlike
/// [AgentCheckFailed] no response was seen to fail.
final class AgentCheckCutOff extends NotFinishedOutcome {
  const AgentCheckCutOff(this.why);

  /// Why it stopped, as the driver said.
  final String why;
}

/// The agent's check was handed off to be carried out, and the process
/// restarted before its result came back. The fetch may or may not have
/// reached the site; it is never sent again, and since the stop was this
/// run's own, it says nothing of the deploy.
final class AgentCheckResultLost extends NotFinishedOutcome {
  const AgentCheckResultLost();
}

/// The step's person answered ✅.
final class PersonApproved extends PassingOutcome {
  const PersonApproved(this.by);

  /// Who answered.
  final ActorId by;
}

/// The step's person answered ❌: they held off, which is what was said, not
/// a reading of why.
final class PersonHeldOff extends NotPassingOutcome {
  const PersonHeldOff(this.by);

  /// Who answered.
  final ActorId by;
}

/// The ask for a person step was not wholly posted: posting stopped partway,
/// after [posted], or before anything. The person never saw all of the
/// instruction, so no reaction to what did post answers the step.
final class AskNotDelivered extends NotFinishedOutcome {
  const AskNotDelivered(this.posted);

  /// The messages of the ask that did post, in order, perhaps none.
  final List<SourceMessageId> posted;
}

/// The ask for a person step was handed off to be posted, and the process
/// restarted before it was known what posted. The person may have seen it,
/// but no reaction can be matched to messages never learned, so it is never
/// posted again; it says nothing of the deploy.
final class AskResultLost extends NotFinishedOutcome {
  const AskResultLost();
}

/// Something that happened to a [TestRun], handed to [TestRun.after].
sealed class RunEvent {
  const RunEvent();
}

/// The fetch for the check in flight came back with [outcome].
final class FetchCameBack extends RunEvent {
  const FetchCameBack(this.outcome);

  /// What the fetch gave.
  final Outcome<WebResponse> outcome;
}

/// Posting the ask in flight ended with [outcome]: the messages that
/// posted, in order, when it [Ran].
final class AskPostingEnded extends RunEvent {
  const AskPostingEnded(this.outcome);

  /// What posting the ask gave.
  final Outcome<List<SourceMessageId>> outcome;
}

/// [from] answered [verdict] on message [to].
final class Reacted extends RunEvent {
  const Reacted(this.from, this.to, this.verdict);

  /// Who reacted.
  final ActorId from;

  /// The message reacted to.
  final SourceMessageId to;

  /// What the reaction says.
  final VerdictOnShownMessage verdict;
}

/// Posting the results of a run that is over ended with [outcome]: the
/// messages that posted, in order, when it [Ran].
final class ResultsPostingEnded extends RunEvent {
  const ResultsPostingEnded(this.outcome);

  /// What posting the results gave.
  final Outcome<List<SourceMessageId>> outcome;
}

/// The process restarted, so whatever was in flight before it never reports
/// back. Handed to every saved run before any other event.
final class Restarted extends RunEvent {
  const Restarted();
}

/// One run of a project's [ProjectTestConfig]: the outcome of each step done
/// so far, in order, and the messages that asked the person step due, once
/// they are posted.
///
/// Only [TestRun.start] and [after] make one, so a run's outcomes are always
/// of its first steps, one each, each of the kind its step takes, and none
/// after one that stopped it.
///
/// Whoever holds a run saves each new one before doing what its [position]
/// says: carry out the fetch of an [AgentCheckSent], post the ask of a
/// [PersonAskSent], post the results of a [RunOver]. A saved run that says
/// a check or ask is sent may not have sent it, which is why [Restarted]
/// ends it rather than sending again. Results are only text, so a
/// [Restarted] run that is over and not yet [RunReported] posts them again.
final class TestRun {
  const TestRun._(
    this.config,
    this.outcomes,
    this._askedIn, [
    this._resultsPosted = false,
  ]);

  /// A run of [config]'s plan with no step done yet.
  factory TestRun.start(ProjectTestConfig config) =>
      TestRun._(config, const [], null);

  /// The run [json] holds, as [toJson] wrote it, read strictly: a field
  /// missing, extra or of the wrong type, an unknown outcome, or outcomes
  /// that [start] and [after] could never have reached, is a
  /// [FormatException].
  ///
  /// ```json
  /// {
  ///   "config": {"project": "slack-relay", "deployedTo": "…", "steps": […]},
  ///   "outcomes": [{"outcome": "agentCheckHeld"}],
  ///   "askedIn": ["C0001|1700000000.000100"]
  /// }
  /// ```
  ///
  /// `askedIn` is there only while a person step's ask has posted and its
  /// person has not answered; `"resultsPosted": true` only once a run that
  /// is over has posted its results.
  factory TestRun.fromJson(JsonObject json) {
    onlyFields(json, const {
      'config',
      'outcomes',
      'askedIn',
      'resultsPosted',
    }, 'a saved run');
    final config = ProjectTestConfig.fromJson(json.object('config'));
    final outcomes = List<StepOutcome>.unmodifiable([
      for (final (i, outcome) in json.objects('outcomes').indexed)
        _outcomeFromJson(outcome, 'outcomes[$i]'),
    ]);
    final askedIn = switch (json.stringsOrNull('askedIn')) {
      null => null,
      final ids => List<SourceMessageId>.unmodifiable([
        for (final (i, id) in ids.indexed)
          SourceMessageId.parse(id) ??
              (throw JsonFieldException('askedIn[$i]', 'a message id')),
      ]),
    };
    final resultsPosted = switch (json.booleanOrNull('resultsPosted')) {
      null => false,
      true => true,
      false => throw JsonFieldException(
        'resultsPosted',
        'true, or no field at all',
      ),
    };
    if (_whyNotReachable(config.plan.steps, outcomes, askedIn)
        case final why?) {
      throw FormatException('not a run this plan can reach: $why');
    }
    final run = TestRun._(config, outcomes, askedIn, resultsPosted);
    if (resultsPosted && run._overPosition == null) {
      throw const FormatException(
        'not a run this plan can reach: resultsPosted on a run not over',
      );
    }
    return run;
  }

  /// This run as JSON, as [TestRun.fromJson] reads it back.
  JsonObject toJson() => JsonObject.of({
    'config': config.toJson(),
    'outcomes': [for (final outcome in outcomes) _outcomeToJson(outcome)],
    'askedIn': ?_askedIn?.map((id) => id.value).toList(),
    if (_resultsPosted) 'resultsPosted': true,
  });

  /// Why [outcomes] and [askedIn] are not a run of [steps] that [start] and
  /// [after] could reach, or null when they are.
  static String? _whyNotReachable(
    List<TestStep> steps,
    List<StepOutcome> outcomes,
    List<SourceMessageId>? askedIn,
  ) {
    if (outcomes.length > steps.length) {
      return '${outcomes.length} outcomes for ${steps.length} steps';
    }
    for (final (i, outcome) in outcomes.indexed) {
      if (!_fits(steps[i], outcome)) {
        return 'outcomes[$i] is not an outcome of step ${i + 1}';
      }
      if (i < outcomes.length - 1 && outcome is! PassingOutcome) {
        return 'outcomes[$i] stopped the run, yet more follow';
      }
    }
    if (askedIn == null) return null;
    final stillGoing = switch (outcomes) {
      [] || [..., PassingOutcome()] => outcomes.length < steps.length,
      _ => false,
    };
    return switch ((askedIn, stillGoing)) {
      ([], _) => 'askedIn is empty',
      (_, false) => 'askedIn on a run that is over',
      _ when steps[outcomes.length] is! PersonStep =>
        'askedIn while an agent step is in flight',
      _ => null,
    };
  }

  /// Whether [outcome] is one [step] can have: of its kind, and from its
  /// person.
  static bool _fits(TestStep step, StepOutcome outcome) =>
      switch ((step, outcome)) {
        (
          AgentStep(),
          AgentCheckHeld() ||
              AgentCheckFailed() ||
              AgentCheckNotRun() ||
              AgentCheckCutOff() ||
              AgentCheckResultLost(),
        ) =>
          true,
        (PersonStep(:final person), PersonApproved(:final by)) ||
        (PersonStep(:final person), PersonHeldOff(:final by)) => by == person,
        (PersonStep(), AskNotDelivered() || AskResultLost()) => true,
        _ => false,
      };

  /// What is being run, and against which site.
  final ProjectTestConfig config;

  /// What came of each step done so far, in order.
  final List<StepOutcome> outcomes;

  /// The messages that asked the person step due, or null before it is
  /// asked.
  final List<SourceMessageId>? _askedIn;

  /// Whether the run is over and its results have posted.
  final bool _resultsPosted;

  /// The steps, in order.
  List<TestStep> get steps => config.plan.steps;

  /// The run after [event], to save and then act on, or null when there is
  /// nothing to do: a reaction from someone other than the step's person, a
  /// fetch coming back when no check is in flight, or a results post that
  /// did not wholly post, which the next [Restarted] posts again.
  TestRun? after(RunEvent event) => switch ((position, event)) {
    (final AgentCheckSent p, FetchCameBack(:final outcome)) => p._checked(
      outcome,
    ),
    (final PersonAskSent p, AskPostingEnded(:final outcome)) => p._posted(
      outcome,
    ),
    (
      final PersonStepAsked p,
      Reacted(:final from, :final to, :final verdict),
    ) =>
      p._judged(from, to, verdict),
    (AgentCheckSent(), Restarted()) => _with(const AgentCheckResultLost()),
    (PersonAskSent(), Restarted()) => _with(const AskResultLost()),
    (RunOver(), ResultsPostingEnded(outcome: Ran(output: [_, ...]))) =>
      TestRun._(config, outcomes, null, true),
    (RunOver(), Restarted()) => this,
    _ => null,
  };

  /// Where the run is: a step in flight, over with its results to post, or
  /// reported.
  RunPosition get position {
    if (_overPosition case final over?) {
      return _resultsPosted ? RunReported._(over) : over;
    }
    return switch ((steps[outcomes.length], _askedIn)) {
      (final AgentStep step, _) => AgentCheckSent._(this, step),
      (final PersonStep step, null) => PersonAskSent._(this, step),
      (final PersonStep step, final askedIn?) => PersonStepAsked._(
        this,
        step,
        askedIn,
      ),
    };
  }

  /// How the run ended, or null while a step is in flight.
  RunOver? get _overPosition => switch (outcomes) {
    [..., final NotPassingOutcome last] => RunNotPassed._(this, last),
    [..., final NotFinishedOutcome last] => RunNotFinished._(this, last),
    _ when outcomes.length == steps.length => RunPassed._(this),
    _ => null,
  };

  TestRun _with(StepOutcome outcome) =>
      TestRun._(config, List.unmodifiable([...outcomes, outcome]), null);
}

/// The names an outcome's `outcome` field takes on the wire.
const _agentCheckHeld = 'agentCheckHeld';
const _agentCheckFailed = 'agentCheckFailed';
const _agentCheckNotRun = 'agentCheckNotRun';
const _agentCheckCutOff = 'agentCheckCutOff';
const _agentCheckResultLost = 'agentCheckResultLost';
const _personApproved = 'personApproved';
const _personHeldOff = 'personHeldOff';
const _askNotDelivered = 'askNotDelivered';
const _askResultLost = 'askResultLost';

/// The outcome [json], at [field] in a saved run, read strictly.
StepOutcome _outcomeFromJson(JsonObject json, String field) {
  ActorId by() =>
      ActorId.parse(json.string('by')) ??
      (throw JsonFieldException('$field.by', 'an actor id'));
  switch (json.string('outcome')) {
    case _agentCheckHeld:
      onlyFields(json, const {'outcome'}, field);
      return const AgentCheckHeld();
    case _agentCheckFailed:
      onlyFields(json, const {'outcome', 'observed'}, field);
      return AgentCheckFailed(json.string('observed'));
    case _agentCheckNotRun:
      onlyFields(json, const {'outcome', 'why'}, field);
      return AgentCheckNotRun(json.string('why'));
    case _agentCheckCutOff:
      onlyFields(json, const {'outcome', 'why'}, field);
      return AgentCheckCutOff(json.string('why'));
    case _agentCheckResultLost:
      onlyFields(json, const {'outcome'}, field);
      return const AgentCheckResultLost();
    case _personApproved:
      onlyFields(json, const {'outcome', 'by'}, field);
      return PersonApproved(by());
    case _personHeldOff:
      onlyFields(json, const {'outcome', 'by'}, field);
      return PersonHeldOff(by());
    case _askNotDelivered:
      onlyFields(json, const {'outcome', 'posted'}, field);
      return AskNotDelivered(
        List.unmodifiable([
          for (final (i, id) in json.strings('posted').indexed)
            SourceMessageId.parse(id) ??
                (throw JsonFieldException('$field.posted[$i]', 'a message id')),
        ]),
      );
    case _askResultLost:
      onlyFields(json, const {'outcome'}, field);
      return const AskResultLost();
    case final outcome:
      throw FormatException('$field.outcome is not an outcome: $outcome');
  }
}

/// [outcome] as JSON, as [_outcomeFromJson] reads it back.
JsonObject _outcomeToJson(StepOutcome outcome) => JsonObject.of(
  switch (outcome) {
    AgentCheckHeld() => {'outcome': _agentCheckHeld},
    AgentCheckFailed(:final observed) => {
      'outcome': _agentCheckFailed,
      'observed': observed,
    },
    AgentCheckNotRun(:final why) => {'outcome': _agentCheckNotRun, 'why': why},
    AgentCheckCutOff(:final why) => {'outcome': _agentCheckCutOff, 'why': why},
    AgentCheckResultLost() => {'outcome': _agentCheckResultLost},
    PersonApproved(:final by) => {'outcome': _personApproved, 'by': by.value},
    PersonHeldOff(:final by) => {'outcome': _personHeldOff, 'by': by.value},
    AskNotDelivered(:final posted) => {
      'outcome': _askNotDelivered,
      'posted': [for (final id in posted) id.value],
    },
    AskResultLost() => {'outcome': _askResultLost},
  },
);

/// Where a [TestRun] is: a step in flight, or over ([RunOver]). Only
/// [TestRun.after] moves a run on, so only the step in flight can be
/// answered, and only with an outcome of its kind.
sealed class RunPosition {
  const RunPosition();

  /// The run this is the position of.
  TestRun get run;
}

/// The agent's [step] is in flight: its [fetch] is to be carried out, and
/// its result handed back as [FetchCameBack].
final class AgentCheckSent extends RunPosition {
  const AgentCheckSent._(this.run, this.step);

  @override
  final TestRun run;

  /// The step.
  final AgentStep step;

  /// The fetch to propose for [step], on the run's deployed site.
  WebFetch get fetch => step.check.fetchFrom(run.config.deployedTo);

  TestRun _checked(Outcome<WebResponse> outcome) =>
      run._with(step.check.judge(outcome));
}

/// [step]'s ask is in flight: it is to be posted, and what posted handed
/// back as [AskPostingEnded].
final class PersonAskSent extends RunPosition {
  const PersonAskSent._(this.run, this.step);

  @override
  final TestRun run;

  /// The step.
  final PersonStep step;

  /// Wholly posted in at least one message, the run waits on [step]'s
  /// person; otherwise the ask was not delivered and the run ends.
  TestRun _posted(Outcome<List<SourceMessageId>> outcome) => switch (outcome) {
    Ran(output: [_, ...] && final posted) => TestRun._(
      run.config,
      run.outcomes,
      List.unmodifiable(posted),
    ),
    Ran() || NothingRan() => run._with(const AskNotDelivered([])),
    StoppedPartway(:final done) => run._with(
      AskNotDelivered(List.unmodifiable(done ?? const <SourceMessageId>[])),
    ),
  };
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

  /// Null when it is no answer: [to] is not one of [askedIn], [from] is not
  /// the step's person, or it proposes a correction.
  TestRun? _judged(
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

/// The run is over and its results are to be posted, then handed back as
/// [ResultsPostingEnded]: every step passed ([RunPassed]), a step finished
/// with a result against the deploy ([RunNotPassed]), or a step never
/// finished ([RunNotFinished]).
sealed class RunOver extends RunPosition {
  const RunOver();
}

/// The run is [over] and its results have posted: nothing is left to do.
final class RunReported extends RunPosition {
  const RunReported._(this.over);

  /// How it ended.
  final RunOver over;

  @override
  TestRun get run => over.run;
}

/// Every step passed.
final class RunPassed extends RunOver {
  const RunPassed._(this.run);

  @override
  final TestRun run;
}

/// A step finished with a result against the deploy, [because], and the run
/// ended there.
final class RunNotPassed extends RunOver {
  const RunNotPassed._(this.run, this.because);

  @override
  final TestRun run;

  /// What came of the step it ended at.
  final NotPassingOutcome because;

  /// The step it ended at.
  TestStep get endedAt => run.steps[run.outcomes.length - 1];
}

/// A step never finished, [because], and the run ended there.
final class RunNotFinished extends RunOver {
  const RunNotFinished._(this.run, this.because);

  @override
  final TestRun run;

  /// What came of the step it ended at.
  final NotFinishedOutcome because;

  /// The step it ended at.
  TestStep get endedAt => run.steps[run.outcomes.length - 1];
}
