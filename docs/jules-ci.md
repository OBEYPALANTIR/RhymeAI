# Jules CI repair

The `Jules CI repair` workflow is disabled until repository variable
`JULES_CI_ENABLED` is exactly `true`. It watches Android, iOS, Android APK,
and Build Android APK failures. Only a current same-repository branch SHA,
write-authorized original and rerun actors, and a started failing build/test
step qualify. Forks, stale branches, Jules repairs, setup failures, and runs
without failed steps are skipped. No application builds or devices are needed
to validate this tooling.

## Setup

1. Connect this repository in Jules. The helper discovers the matching source
   through every page of the [Sources API](https://jules.google/docs/api/reference/sources/).
2. Set the repository Actions secret `JULES_API_KEY` using the existing account.
   Never put its value in logs, workflow files, or command arguments.
3. Run the read-only preflight below. Then set `JULES_CI_ENABLED=true` when ready.

The owner authorized the Pro/Ultra account's provider default. The
[Sessions API](https://jules.google/docs/api/reference/sessions/) has no model
selector or returned model identity. This integration uses that provider
default; the exact model and whether it is the latest Pro/coding model are
unverified. A prompt cannot select or attest a model. Account entitlement and
quota remain account-side requirements.

Sessions use `requirePlanApproval:false` and `automationMode:AUTO_CREATE_PR`.
This workflow cannot merge: its token has no contents or pull-request write
permission. A resulting PR still needs required checks and the existing
independent non-author approval. Submission is not repair completion.

## Validation and operation

After merging the workflow into the default branch, use Actions → Jules CI
repair → Run workflow, supplying an actual failed run ID and leaving `dry_run`
enabled. This reads GitHub metadata, permissions and existing checks, but does
not create check runs or contact Jules. It works without Jules credentials.
For local read-only validation with an authenticated GitHub CLI:

```sh
GH_TOKEN="$(gh auth token)" GITHUB_REPOSITORY=OBEYPALANTIR/RhymeAI \
  RUN_ID=38100385490 DRY_RUN=true node .github/scripts/jules-ci.mjs
node --test .github/scripts/jules-ci.test.mjs
```

The helper is always checked out from the trusted default branch, never from
the failed branch. Run/job/step metadata are passed as JSON to Jules, never
executed. Raw logs are deliberately omitted: they can contain secrets and
untrusted instructions. Jules is asked to inspect and reproduce the exact run.
The API starts from a branch, not an immutable SHA; the helper rechecks it
immediately before submission and asks Jules to stop if it has since moved.

All runs and reruns for a SHA share one concurrency group. The helper reads
every page of check runs and creates `Jules CI submission attempt` before the
single session POST. Do not delete this marker: transport ambiguity consumes
the attempt, because a session may already exist. GitHub may replace an older
pending concurrent job; a retained attempt still prevents duplicates. The
helper is not a standalone concurrent submitter: only the workflow provides
the serialization contract. Local execution must stay in dry-run mode.

The summary reports the run URL/SHA, skipped or eligible status, and, after a
submission, the session URL. It polls at most six times over roughly a minute
and reports observed state and any returned PR URLs. `submitted` means Jules
may still be running or awaiting feedback; `completed` is provider-reported,
not proof the PR passed tests. Later progress is available at the session URL.
API errors fail the workflow without dumping response bodies or keys. Failed
or ambiguous submissions are not retried for that SHA; investigate the Jules
account and check marker before considering a new commit. Disable future
submissions by setting `JULES_CI_ENABLED=false`.
