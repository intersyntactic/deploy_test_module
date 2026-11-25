import 'package:checked_json/checked_json.dart'
    show JsonFieldException, JsonObject;
import 'package:is_airlock_api/is_airlock_api.dart' show WebFetch;
import 'package:is_effects/is_effects.dart'
    show
        BodyToKeep,
        BytesBody,
        NoBody,
        Outcome,
        Ran,
        NothingRan,
        StoppedPartway,
        TextBody,
        WebResponse;
import 'package:is_shapes/is_shapes.dart' show ActorId;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart'
    show
        Origin,
        WebPath,
        decodeOrigin,
        decodeWebPath,
        encodeOrigin,
        encodeWebPath;

import 'test_run.dart'
    show
        AgentCheckCutOff,
        AgentCheckFailed,
        AgentCheckHeld,
        AgentCheckNotRun,
        StepOutcome;

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
///
/// As JSON:
///
/// ```json
/// {
///   "project": "slack-relay",
///   "deployedTo": "https://relay.example",
///   "steps": [
///     {"step": "responseStatusIs", "path": "/health", "status": 200},
///     {"step": "responseBodyContains", "path": "/health", "text": "ready"},
///     {"step": "person", "person": "slack:T0001/U024BE7LH",
///      "instruction": "Mention the bot in a thread; does it answer?"}
///   ]
/// }
/// ```
final class ProjectTestConfig {
  const ProjectTestConfig({
    required this.project,
    required this.deployedTo,
    required this.plan,
  });

  /// The config [json] holds, read strictly: a field missing, extra or of
  /// the wrong type, an unknown step, or no steps, is a [FormatException].
  factory ProjectTestConfig.fromJson(JsonObject json) {
    _onlyFields(json, const {'project', 'deployedTo', 'steps'}, 'the config');
    final project = DeployedProjectName.parse(json.string('project'));
    if (project == null) {
      throw JsonFieldException('project', 'a project name');
    }
    final plan = TestPlan.of([
      for (final (i, step) in json.objects('steps').indexed)
        _stepFromJson(step, 'steps[$i]'),
    ]);
    if (plan == null) throw JsonFieldException('steps', 'at least one step');
    return ProjectTestConfig(
      project: project,
      deployedTo: decodeOrigin(json.raw('deployedTo'), 'deployedTo'),
      plan: plan,
    );
  }

  /// Which project this tests.
  final DeployedProjectName project;

  /// The site every agent step's request goes to.
  final Origin deployedTo;

  /// The steps, in order.
  final TestPlan plan;

  /// This config as JSON, as [ProjectTestConfig.fromJson] reads it back.
  JsonObject toJson() => JsonObject.of({
    'project': project.value,
    'deployedTo': encodeOrigin(deployedTo),
    'steps': [for (final step in plan.steps) _stepToJson(step)],
  });
}

/// The names a step's `step` field takes on the wire.
const _responseStatusIs = 'responseStatusIs';
const _responseBodyContains = 'responseBodyContains';
const _person = 'person';

/// The step [json], at [field] in the config, read strictly.
TestStep _stepFromJson(JsonObject json, String field) {
  switch (json.string('step')) {
    case _responseStatusIs:
      _onlyFields(json, const {'step', 'path', 'status'}, field);
      final status = HttpStatusCode.parse(json.integer('status'));
      if (status == null) {
        throw JsonFieldException('$field.status', 'a status from 100 to 599');
      }
      return AgentStep(
        ResponseStatusIs(
          path: decodeWebPath(json.raw('path'), '$field.path'),
          status: status,
        ),
      );
    case _responseBodyContains:
      _onlyFields(json, const {'step', 'path', 'text'}, field);
      return AgentStep(
        ResponseBodyContains(
          path: decodeWebPath(json.raw('path'), '$field.path'),
          text: json.string('text'),
        ),
      );
    case _person:
      _onlyFields(json, const {'step', 'person', 'instruction'}, field);
      final person = ActorId.parse(json.string('person'));
      if (person == null) {
        throw JsonFieldException('$field.person', 'an actor id');
      }
      return PersonStep(
        person: person,
        instruction: json.string('instruction'),
      );
    case final step:
      throw FormatException('$field.step is not a step: $step');
  }
}

/// [step] as JSON, as [_stepFromJson] reads it back.
JsonObject _stepToJson(TestStep step) => JsonObject.of(switch (step) {
  AgentStep(check: ResponseStatusIs(:final path, :final status)) => {
    'step': _responseStatusIs,
    'path': encodeWebPath(path),
    'status': status.value,
  },
  AgentStep(check: ResponseBodyContains(:final path, :final text)) => {
    'step': _responseBodyContains,
    'path': encodeWebPath(path),
    'text': text,
  },
  PersonStep(:final person, :final instruction) => {
    'step': _person,
    'person': person.value,
    'instruction': instruction,
  },
});

/// Throws a [FormatException] naming [what] and the first key of [json]
/// not in [fields].
void _onlyFields(JsonObject json, Set<String> fields, String what) {
  for (final key in json.keys) {
    if (!fields.contains(key)) {
      throw FormatException('`$key` is not a field of $what');
    }
  }
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

  /// What came of the check, from the fetch's [outcome]. A fetch where
  /// nothing ran was never sent, so it says nothing of the deploy:
  /// [AgentCheckNotRun]. One cut off partway may have reached the site, and a
  /// site dropping or timing out is something about the deploy, so it is
  /// neither: [AgentCheckCutOff].
  StepOutcome judge(Outcome<WebResponse> outcome) => switch (outcome) {
    NothingRan(:final why) => AgentCheckNotRun(why),
    StoppedPartway(:final why) => AgentCheckCutOff(why),
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
