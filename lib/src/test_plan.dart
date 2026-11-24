import 'package:is_airlock_api/is_airlock_api.dart' show WebFetch;
import 'package:is_effects/is_effects.dart'
    show
        BodyToKeep,
        BytesBody,
        NoBody,
        Outcome,
        Ran,
        Refused,
        TextBody,
        WebResponse;
import 'package:is_shapes/is_shapes.dart' show ActorId;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart'
    show Origin, WebPath;

import 'test_run.dart'
    show AgentCheckFailed, AgentCheckHeld, AgentCheckNotRun, StepOutcome;

/// A project whose deploys are tested, by a name such as `slack-relay`: a
/// lower-case letter, then lower-case letters, digits, `_` or `-`.
final class DeployedProjectName {
  const DeployedProjectName._(this.value);

  /// The name, as text.
  final String value;

  /// [s] as a project name, or null unless it is one.
  static DeployedProjectName? parse(String s) =>
      _name.hasMatch(s) ? DeployedProjectName._(s) : null;

  static final _name = RegExp(r'^[a-z][a-z0-9_-]*$');

  @override
  bool operator ==(Object other) =>
      other is DeployedProjectName && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// How to test one project's deploy: the site it is deployed to, and the
/// steps that test it.
final class ProjectTestConfig {
  const ProjectTestConfig({
    required this.project,
    required this.deployedTo,
    required this.plan,
  });

  /// Which project this tests.
  final DeployedProjectName project;

  /// The site every agent step's request goes to.
  final Origin deployedTo;

  /// The steps, in order.
  final TestPlan plan;
}

/// The steps of a test, in the order they are done. Never empty.
final class TestPlan {
  const TestPlan._(this.steps);

  /// [steps] as a plan, or null when there are none.
  static TestPlan? of(Iterable<TestStep> steps) {
    final list = List<TestStep>.unmodifiable(steps);
    return list.isEmpty ? null : TestPlan._(list);
  }

  /// The steps, in order.
  final List<TestStep> steps;
}

/// One step of a test: done by the agent ([AgentStep]) or by a named person
/// ([PersonStep]).
sealed class TestStep {
  const TestStep();
}

/// A step the agent does by itself: one [check] against the deployed site.
final class AgentStep extends TestStep {
  const AgentStep(this.check);

  /// What the agent checks.
  final AgentCheck check;
}

/// A step only [person] can do: they are shown [instruction] and answer
/// whether it passed.
final class PersonStep extends TestStep {
  const PersonStep({required this.person, required this.instruction});

  /// Who does it. A verdict from anyone else does not answer it.
  final ActorId person;

  /// What they are asked to do and look for, as shown to them.
  final String instruction;
}

/// What the agent checks against the deployed site: the status of a
/// response ([ResponseStatusIs]) or what its body says
/// ([ResponseBodyContains]).
///
/// A check is a GET the airlock decides, [fetchFrom], and a reading of its
/// outcome, [judge], so whatever runs it proposes the fetch on its own
/// trajectory, under that trajectory's rules.
sealed class AgentCheck {
  const AgentCheck();

  /// The path on the deployed site the request goes to.
  WebPath get path;

  /// What of the response's body the check reads.
  BodyToKeep get keep;

  /// The GET of [path] on [site], under no sign-in.
  WebFetch fetchFrom(Origin site) => WebFetch(site, path: path, keep: keep);

  /// What came of the check, from the fetch's [outcome]. A refused fetch
  /// was never sent, so it says nothing of the deploy: [AgentCheckNotRun].
  StepOutcome judge(Outcome<WebResponse> outcome) => switch (outcome) {
    Refused(:final why) => AgentCheckNotRun(why),
    Ran(output: final response) => _judgeResponse(response),
  };

  StepOutcome _judgeResponse(WebResponse response);
}

/// A GET of [path] answers with [status].
final class ResponseStatusIs extends AgentCheck {
  const ResponseStatusIs({required this.path, required this.status});

  @override
  final WebPath path;

  /// The status the response must have.
  final HttpStatusCode status;

  @override
  BodyToKeep get keep => BodyToKeep.none;

  @override
  StepOutcome _judgeResponse(WebResponse response) =>
      response.status == status.value
      ? const AgentCheckHeld()
      : AgentCheckFailed(_statusSeen(response));
}

/// A GET of [path] answers 2xx with a text body containing [text].
final class ResponseBodyContains extends AgentCheck {
  const ResponseBodyContains({required this.path, required this.text});

  @override
  final WebPath path;

  /// What the body must contain.
  final String text;

  @override
  BodyToKeep get keep => BodyToKeep.text;

  @override
  StepOutcome _judgeResponse(WebResponse response) => switch (response.body) {
    TextBody(text: final body) when body.contains(text) =>
      const AgentCheckHeld(),
    TextBody() => AgentCheckFailed('body does not contain "$text"'),
    NoBody() || BytesBody() => AgentCheckFailed(_statusSeen(response)),
  };
}

/// The status [response] had, and the site's reason when it gave one.
String _statusSeen(WebResponse response) => switch (response.refusedBecause) {
  final why? => 'status ${response.status}: $why',
  null => 'status ${response.status}',
};

/// An HTTP status code, 100 to 599.
final class HttpStatusCode {
  const HttpStatusCode._(this.value);

  /// 200 OK.
  static const ok = HttpStatusCode._(200);

  /// [code] as a status code, or null unless it is from 100 to 599.
  static HttpStatusCode? parse(int code) =>
      code >= 100 && code <= 599 ? HttpStatusCode._(code) : null;

  /// The code, as a number.
  final int value;

  @override
  bool operator ==(Object other) =>
      other is HttpStatusCode && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => '$value';
}
