# Research deliverables: benchmarks, reports, new repos

Apply these to any lane whose output is a report, benchmark or new repository that other people
will read.

## New repositories

- Create them **private** (`gh repo create --private`), even when the brief says "publish".
  The owner makes a repo public after a full-history leak scan
  (`git grep` over `git rev-list --all` for host paths, emails, internal names) and the
  review passes below. History is easiest to rewrite before anyone else clones it.
- Author email: the owner's noreply address. Add a licence only when the owner names one.

## Numbers come from data, and a check proves it

- Every number in a table, chart or sentence is generated from the results files. Ship a
  check (`make audit` or similar) that fails when the report and the data disagree, and
  re-run it, along with the charts, after any data change. A stale "all passed" from the pilot
  is the failure this prevents.
- Lead with the main pre-registered result. Label pilot, exploratory and post-hoc runs as
  such, and put them in an appendix. Don't put a confidence interval on problems chosen
  because a model failed them.
- Show n on every pass cell, and mark cells whose n differs from the rest.
- Compare like with like: the same harness across model families (tools on or off, the
  same prompt). State any difference that remains, such as host instruction files a CLI
  cannot drop. Get prices from the vendor's own pages, and report cache-hit share, because
  caching can swing cost several-fold.

## Measure more than pass/fail

- Keep every model output on disk, one file per item (`results/<problem>/<config>/r<n>.*`)
  with an index, so a human can read and re-check it.
- Add programmatic quality columns next to pass/fail rather than one blended score:
  - lines of code
  - complexity
  - lint warnings
  - empirical time and memory growth against a reference
  - tests written

  Record reasoning tokens: a low effort setting can mean the model does no reasoning at all,
  and a prompt nudge does not change that.
- When every config passes, you are measuring the ceiling, not the models. Add a harder rung,
  frozen before any model call, until the strongest configs fail.

## Presentation

- Start an Artifact from `quickstart`, and use the account's design system rather than
  hand-rolled styling.
- Before designing tables and charts, study two or three public benchmarks (leaderboards,
  harness papers) and say what you borrowed.
- Tables: sortable by any column, numeric-aware.
- Charts: labelled axes with nothing clipped at phone width, and a marked Pareto frontier on
  cost-vs-latency or cost-vs-accuracy charts.
- Visual first. Lead with a one-sentence verdict box, then follow each
  heading with a chart or table and at most three one-line bullets. Keep visible body prose to
  about 350 words and put method, limitations and appendices in `<details>`. Have more charts
  than text sections.
- Prose: plain words, a deslop pass, no repeated facts.

## Review passes before calling it done

1. The session's `advisor`, at the approach fork and before done.
2. Haiku low: a mechanical number check against the data files.
3. Independent read of a frozen packet (data summary + report), not the transcript
   ([spawn-guide](spawn-guide.md#second-opinions)).
4. A deslop pass on all prose.
5. Re-run the audit check. Done means it passes on the final data.
