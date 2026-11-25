import 'package:is_deploy_test_module/is_deploy_test_module.dart';
import 'package:is_effects/is_effects.dart'
    show
        BodyToKeep,
        NoBody,
        NothingRan,
        Ran,
        StoppedPartway,
        TextBody,
        WebResponse;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart'
    show Origin, WebPath;
import 'package:test/test.dart';

void main() {
  final site = Origin.parse('https://relay.example')!;
  final health = WebPath.parse('/health')!;
  final statusOk = ResponseStatusIs(path: health, status: HttpStatusCode.ok);
  final saysReady = ResponseBodyContains(path: health, text: 'ready');

  group('fetchFrom', () {
    test('a status check GETs its path on the site, keeping no body', () {
      final fetch = statusOk.fetchFrom(site);
      expect(fetch.origin, site);
      expect(fetch.path, health);
      expect(fetch.keep, BodyToKeep.none);
      expect(fetch.signIn, isNull);
    });

    test('a body check keeps the body as text', () {
      expect(saysReady.fetchFrom(site).keep, BodyToKeep.text);
    });
  });

  group('judge', () {
    test('the expected status holds', () {
      expect(
        statusOk.judge(const Ran(WebResponse(status: 200))),
        isA<AgentCheckHeld>(),
      );
    });

    test('another status fails, saying what it saw and why', () {
      final outcome = statusOk.judge(
        const Ran(WebResponse(status: 502, refusedBecause: 'Bad Gateway')),
      );
      expect((outcome as AgentCheckFailed).observed, 'status 502: Bad Gateway');
    });

    test('a body containing the text holds', () {
      expect(
        saysReady.judge(
          const Ran(WebResponse(status: 200, body: TextBody('all ready'))),
        ),
        isA<AgentCheckHeld>(),
      );
    });

    test('a body without the text fails', () {
      final outcome = saysReady.judge(
        const Ran(WebResponse(status: 200, body: TextBody('starting'))),
      );
      expect(
        (outcome as AgentCheckFailed).observed,
        'body does not contain "ready"',
      );
    });

    test('a body check on a non-2xx fails on the status', () {
      final outcome = saysReady.judge(
        const Ran(WebResponse(status: 503, body: NoBody())),
      );
      expect((outcome as AgentCheckFailed).observed, 'status 503');
    });

    test('a fetch where nothing ran is not run, not failed', () {
      final outcome = statusOk.judge(
        const NothingRan('no rule grants the site'),
      );
      expect((outcome as AgentCheckNotRun).why, 'no rule grants the site');
      expect(outcome, isA<StoppingOutcome>());
    });

    test('a fetch cut off partway is cut off, neither failed nor not run', () {
      final outcome = statusOk.judge(
        const StoppedPartway<WebResponse>(why: 'connection reset', done: null),
      );
      expect((outcome as AgentCheckCutOff).why, 'connection reset');
      expect(outcome, isA<StoppingOutcome>());
    });
  });
}
