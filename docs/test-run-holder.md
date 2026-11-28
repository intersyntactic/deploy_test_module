# What holds a test run

A draft design, to be argued with. `TestRun` decides what a deploy test does
next; this is the program that makes it happen: it starts a run, carries out
what the run's position asks, and feeds back what came of it.

Citations are paths under `~/git/orgs/intersyntactic/`, read on 2026-11-28.

## The shape: a trajectory's loop that isn't a model

In this system nothing outside a trajectory's loop acts on the world. The
airlock has no door to call: it watches the logbook, and acts on
`action-proposed-by-agent-loop` entries written on a trajectory's own chain.
It decides each one against the trajectory's flight rules, runs it, and writes
an `outcome-of-proposed-action` naming the proposal
(`airlock/README.md`, "Running the airlock as its own service";
`airlock_api/lib/src/proposal.dart:232, 327-364`).

So the holder is a trajectory's loop, in the place agent_loop takes for a
model's trajectory. It runs as the trajectory's loop user, reads its feed,
and proposes on its chain. It never sends a byte itself.

That fits `TestRun` better than anything we planned for it:

- **The chain is the save.** `TestRun`'s rule is "save each new run before
  doing what it says". Writing the proposal on the chain is both at once:
  the airlock acts only on what is recorded.
- **Replay is the restart.** On start-up the holder reads its chain from the
  beginning and folds each recorded fact through `run.after(event)`. The run
  it ends with is the run it was, with no store of our own.
- **Nothing is resent, by construction.** A proposal on the chain stays there.
  If the holder restarts before its outcome lands, the airlock still writes
  that outcome (it skips only proposals already answered,
  `airlock/lib/src/airlock_subscriber.dart:177-183, 350-362`). The holder
  waits for it, as agent_loop does (`agent_loop/lib/src/trajectory_history.dart:750-775`).

### What that does to `Restarted`

`Restarted`, `AgentCheckResultLost` and `AskResultLost` were built for a
holder that did its own I/O, which could lose a fetch it had sent. Under the
logbook a proposal is never lost: its outcome comes, late or not. So in this
holder a run in flight on restart is not "not finished"; it is still waiting.

I'd retire `Restarted` and the two `…ResultLost` outcomes rather than keep a
case the holder never feeds. The one thing they did that still matters is
posting results again when a results post failed. Here that is a new
proposal at the next place, owed whenever the last results post's outcome
was a failure, with a limit (task 4's timer is the natural home).

**Decision for Nick:** retire `Restarted` (and its two lost outcomes), or
keep them for a holder that isn't this one?

## How a run starts: a message in a deploys channel

Only one thing starts a trajectory: a `MessageSaid` the docking station
admits at an address its rules let in, when the turn rule says it starts a
turn (`docking_station/service/lib/src/decide.dart:133-163`). A logbook entry
of another kind is never seen by it
(`docking_station/service/lib/src/run.dart:96-100, 147`).

That makes the `release-went-live` entry (agreed with infra-95, task 22) a
poor trigger on its own. To start a trajectory it would need a translator of
its own wired into the docking station and a sender row for a new event kind,
and the trajectory it started would have no Slack thread to reply into:
a trajectory's reply endpoint is the address of the event that started it
(`docking_station/docking_station_api/lib/src/decision.dart:230-236`).

What fits instead: **a run starts from a message in a Slack channel kept for
deploy tests**, say `#deploy-tests`.

- A person types `test intersyntactic-slack-relay on enspyr-syd`. That starts
  a trajectory in that message's thread. The asks and the results post in the
  thread, and a ✅ on an ask comes back to the trajectory open at that thread
  (`docking_station/service/lib/src/decide.dart:109-118`).
- A deploy posts the same message after its live probe passes, as a bot that
  isn't ours. The Slack translator admits other bots' messages as
  `MessageSaid` (`slack_module/lib/src/slack_event_translator.dart:18-19`).
  A Slack incoming webhook on the deploy's side is enough.

So starting by hand and starting after a deploy are one path, not two. It
loses nothing if the holder is down: the relay records the message in the
logbook, and the trajectory starts when it can. It is lost only if the relay
is down, and Slack retries a failed delivery.

`release-went-live` is still worth having as the record of what went live.
It just isn't what starts a test.

**Decision for Nick:** start runs from a message in a deploy-tests channel,
by a person or by a deploy's webhook. This revisits task 22 with something
we didn't know at the time.

## What the holder does, position by position

The holder reads the trigger message, parses `(unit, box)` from it, and
fetches that pair's `ProjectTestConfig`. Then:

| Position | It proposes | What comes back, fed to `after` |
|---|---|---|
| `AgentCheckSent` | `fetch` of the check's address | `FetchCameBack(outcome)` |
| `PersonAskSent` | the ask drawn as Slack requests, then `make-web-requests` | `AskPostingEnded(ids)`, the ids from `slack-reply-drawing posted` |
| `PersonStepAsked` | nothing; it waits | `Reacted(from, to, verdict)`, from an admitted `ShownMessageJudged` |
| `RunOver` | the results drawn, then sent | `ResultsPostingEnded` |
| `RunReported` | nothing; the loop exits | |

**The config is a recorded fact.** If the holder read its config from disk,
a config changed between a run's start and a restart would replay a different
plan. Instead, its first proposal is a `fetch` of the config at a pinned
address (a raw file at a commit). Its body lands in the logbook as that
fetch's outcome, and replay reads the same config every time.

**❌ already means "held off".** The Slack translator turns ✅ into approved
and ❌ into held off (`slack_module/lib/src/slack_event_translator.dart:109-137`,
via `SlackVerdictReaction`). That's the system's vocabulary, so task 5 is
largely answered. What's left is whether the run counts held off as failed.

**Places.** Each proposal needs a `PlaceInTrajectory` fixed by what the chain
already holds, so a replay proposes the same thing at the same place
(`airlock_api/lib/src/proposal.dart:16-19`). Step n is the run's nth
proposal-owing position; `[n, intent, k]` numbers the actions within it
(two for an ask: draw, then send).

### Reuse from agent_loop

agent_loop exports what a loop needs (`agent_loop/lib/agent_loop.dart:22-34`):
`findTrajectoryRoot`, `TrajectoryChain`, `TrajectoryProposalLink`,
`followResults` and `ProposesAtNextPlace`. The holder takes them as a git
dependency, since agent_loop is `publish_to: none`. What it can't reuse is
the history fold, which drops `ShownMessageJudged`
(`agent_loop/lib/src/trajectory_history.dart:379-402`). The holder folds its
own history into `TestRun` events. That fold is the core of the program.

## Where the holder lives

A new package in this repo, `deploy_test_holder/`, beside
`is_deploy_test_module`, or a repo of its own. It is a service, and a package
other repos import never contains a service. I lean towards its own repo.

## What it waits on, and whose it is

None of these is the deploy test's alone. Every Slack user of the system
needs the first three.

1. **The Slack translator isn't wired into the docking station.** The docking
   station runs only `TeamsEventTranslator`
   (`docking_station/service/bin/docking_station.dart:84`). Slack events reach
   the relay and the logbook, and stop there. *docking-station-97.*
2. **The airlock can't run a program.** It wires only the web driver and the
   model router (`airlock/bin/airlock_service.dart:129-138`). `ProgramDriverSocket`
   exists but nothing constructs it (`airlock/lib/src/program_driver.dart:18`).
   So "run `slack-reply-drawing`" is allowed by the rules and then ends as
   "this machine cannot run". That is also the first half of every Teams reply
   agent_loop sends (`agent_loop/lib/src/reply.dart`), so either Teams replies
   fail today or something outside these repos runs them. I couldn't tell
   which. *airlock-d5.*
3. **Nothing checks which Slack channel a post goes to.** Slack's reply
   endpoint pins its channel in the request body, which the
   `ToOwnReplyEndpoint` grant never reads, so that grant never covers Slack
   (`flight_rules/lib/src/what_may_leave_this_machine.dart:535-549`). The only
   route left is a `ToAddressesUnder` grant on `slack.com/api/chat.postMessage`.
   It checks origin, path and sign-in only, so a trajectory holding it could
   post in any channel the bot can reach. The check that would confine it
   exists (`airlock/lib/src/trajectory.dart:455-475`, `admitsBody`), but the
   service passes no writer for it (`airlock/bin/airlock_service.dart:145-155`).
   Wiring that writer is the fix, and the holder should use
   `reply-to-own-conversation` rather than a raw grant. *airlock-d5,
   flight-rules-55.*
4. **The rules can't choose the loop.** loop_launcher always starts
   `agent-loop@loop-N` (`loop_launcher/lib/src/starts_and_stops_trajectory_processes.dart:55-58`),
   and `FlightRules` refuses any key it doesn't know and requires a
   `startingModel` (`flight_rules/lib/src/flight_rules.dart:9-20, 158-177`).
   Making the wrong thing impossible here means the rules say which loop as
   a sealed choice: a model loop carries its starting model, and a deploy
   test loop carries none. That changes flight_rules, which loop_launcher,
   the airlock and agent_loop all parse. loop_launcher then needs a
   `deploy-test-loop@` unit, a polkit rule for it, and a loop limit that
   isn't per model sign-in. *flight-rules-55, loop-launcher-dd, infra-95.*
5. **The deploy-tests channel's rules.** In `flight-rules.json`'s
   `byMissionAddress`: the deploy test loop, `fetchesMayReach` grants for each
   config's site and for the config's own address, and
   `slack-reply-drawing` in `programsItMayRun`. *infra-95.*

### Found on the way, not ours

agent_loop never resends a reply after a restart. Reply actions aren't
awaited, and `stepOwed` never owes one, so a loop that dies between the
model's answer and the reply never sends it
(`agent_loop/lib/src/trajectory_history.dart:323-328, 797-813`). This is
inferred from the code and not tested. *agent-loop-55.*

## The order I'd build it in

1. Items 1–3 above. The first two are what Slack needs anyway, and the third
   is a hole worth closing before anything posts to Slack.
2. The flight_rules loop choice and the loop_launcher change (item 4).
3. The holder: fold the chain into `TestRun` events, then propose per
   position. It's testable against a recorded chain with no box.
4. One real config, agent steps only, and the channel's rules (item 5).
5. A first run started by hand in `#deploy-tests`. Then the deploy's webhook.

Steps 1, 2 and 4 are other sessions' work. Step 3 is ours, and it can start
against recorded chains while the others land.

## Decisions for Nick

- Start runs from a message in a deploy-tests channel (revisits task 22).
- Retire `Restarted` and its two lost outcomes.
- The holder in its own repo, or a package in this one.
- Whether to brief airlock-d5, docking-station-97, flight-rules-55,
  loop-launcher-dd and agent-loop-55 with their items now.
