import 'test_plan.dart';
import 'test_run.dart';

/// The text that tells a deploy's thread how its test ended: a headline,
/// then one line per step with what came of it.
///
/// It is plain text naming no one, so any chat module can post it as it is.
/// A run that could not be done is said to be one, never a failure: a
/// refused check or an ask that never arrived says nothing about the deploy.
String resultsPostText(RunFinished finished) {
  final run = finished.run;
  final count = run.steps.length;
  final subject =
      'Deploy test of ${run.config.project} (${run.config.deployedTo})';
  final headline = switch (finished) {
    RunPassed() => '$subject passed: all $count steps.',
    RunStopped(:final because) => switch (because) {
      AgentCheckFailed() =>
        '$subject failed at step ${run.outcomes.length} '
            'of $count.',
      AgentCheckCutOff() =>
        '$subject stopped at step ${run.outcomes.length} of $count: the '
            'check was cut off before a whole response came back.',
      PersonHeldOff() =>
        '$subject was held off at step '
            '${run.outcomes.length} of $count.',
      AgentCheckNotRun() || AskNotDelivered() =>
        "$subject couldn't be finished: step ${run.outcomes.length} of "
            "$count couldn't be done, so this says nothing about the deploy.",
    },
  };
  return [
    headline,
    for (final (i, step) in run.steps.indexed)
      '${i + 1}. ${_stepText(step)}: '
          '${i < run.outcomes.length ? _outcomeText(run.outcomes[i]) : 'not reached'}',
  ].join('\n');
}

/// What [step] checks, in a few words.
String _stepText(TestStep step) => switch (step) {
  AgentStep(check: ResponseStatusIs(:final path, :final status)) =>
    'GET ${_pathText(path.value)} answers $status',
  AgentStep(check: ResponseBodyContains(:final path, :final text)) =>
    'GET ${_pathText(path.value)} says "$text"',
  PersonStep(:final instruction) => 'Person check: $instruction',
};

/// The root path is empty on the wire and `/` to a reader.
String _pathText(String path) => path.isEmpty ? '/' : path;

/// What came of a step, in a few words.
String _outcomeText(StepOutcome outcome) => switch (outcome) {
  AgentCheckHeld() => 'passed',
  PersonApproved() => 'approved ✅',
  AgentCheckFailed(:final observed) => 'failed, $observed',
  PersonHeldOff() => 'held off ❌',
  AgentCheckCutOff(:final why) => 'cut off, $why',
  AgentCheckNotRun(:final why) => 'not run, $why',
  AskNotDelivered(:final posted) when posted.isEmpty =>
    "not asked, the ask didn't post",
  AskNotDelivered() => 'not asked, the ask only partly posted',
};
