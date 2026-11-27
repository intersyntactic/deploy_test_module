import 'test_plan.dart';
import 'test_run.dart';

/// The text that tells a deploy's thread how its test ended: a headline,
/// then one line per step with what came of it.
///
/// It is plain text naming no one, so any chat module can post it as it is.
/// A run whose step never finished is said to be one, never a failure; one
/// whose step never reached the site says so, since it says nothing about
/// the deploy.
String resultsPostText(RunOver over) {
  final run = over.run;
  final count = run.steps.length;
  final subject =
      'Deploy test of ${run.config.project} (${run.config.deployedTo})';
  final step = 'step ${run.outcomes.length} of $count';
  final headline = switch (over) {
    RunPassed() => '$subject passed: all $count steps.',
    RunNotPassed(:final because) => switch (because) {
      AgentCheckFailed() => '$subject failed at $step.',
      PersonHeldOff() => '$subject was held off at $step.',
    },
    RunNotFinished(:final because) =>
      "$subject didn't finish: $step ${switch (because) {
        AgentCheckCutOff() => 'was cut off before a whole response came back.',
        AgentCheckNotRun() => 'was never run, so this says nothing about the deploy.',
        AskNotDelivered() => 'was never fully asked, so this says nothing about the deploy.',
        AgentCheckResultLost() || AskResultLost() => 'was interrupted by a restart, so this says nothing about the deploy.',
      }}",
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
  AgentCheckResultLost() =>
    'interrupted by a restart before its result came back',
  AskResultLost() => 'interrupted by a restart while being asked',
};
