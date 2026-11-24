# is_deploy_test_module

End-to-end testing of a deploy for intersyntactic.

When someone deploys something that needs end-to-end testing, a test run
checks it. A run is an ordered list of steps. The agent does some steps itself,
such as requesting a page and checking the response. A named person does the
others, answering ✅ or ❌ on the message that asks them.

The module speaks no chat system itself. It asks people, and posts results,
through a chat module such as
[is_slack_module](https://github.com/intersyntactic/slack_module) or
[is_teams_module](https://github.com/intersyntactic/teams_module).

- `ProjectTestConfig`: how to test one project: the site it is deployed to,
  and its `TestPlan`.
- `TestPlan`: the steps in order, never empty. Each step is an `AgentStep`
  (an `AgentCheck` against the site) or a `PersonStep` (an `ActorId` and an
  instruction).
- `TestRun`: one run of a plan. Its `position` is the step that is due, or
  how the run finished. You answer a due step through that position, so only
  the step that is due can be answered, and only with an outcome of its kind.

## Checking

```sh
dart analyze --fatal-infos
dart test
```
