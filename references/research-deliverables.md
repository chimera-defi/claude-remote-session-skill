# Research deliverables: benchmarks, reports, new repos

Lessons from the 2026-10-22 model-routing bench. Apply them to any lane whose output is a
report, benchmark or new repository that other people will read.

## New repositories

- Create them **private** (`gh repo create --private`), even when the brief says "publish".
  The operator flips a repo to public after a full-history leak scan
  (`git grep` over `git rev-list --all` for host paths, emails, internal names) and the
  review passes below. History is easiest to rewrite before anyone else clones it.
- Author email: the operator's noreply address. Add a licence only when the operator names one.

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

## Edge-search campaigns: check before the freeze

From a 2026-11 run of search campaigns, where a corrupt dataset faked wins and a mismatched
population faked losses. A campaign that searches for an effect against a baseline records,
in its frozen design, how it checked each item:

1. **The population matches the baseline.** Draw candidates from the population the baseline
   is built from. If they can't match, report the population's own gap to the baseline
   first, and quote every effect against the baseline, never against the population.
2. **One series per identity.** Test for identifiers that carry two interleaved series (for
   example, repeated reversals of very large moves). Drop affected entities entirely: masking
   their values turns artifact gains into artifact losses. Check vendor field formats on real
   rows.
3. **Data hygiene in both directions.** Screen stale runs and bad values up and down, set floors
   from the data rather than a token epsilon, and classify terminal events (a benign exit is
   not a failure). Measure any coverage floor on the exact frozen dataset, after every
   exclusion, before freezing it.
4. **Multiple-testing hurdles use distinct candidates.** Cluster near-duplicates (for example,
   correlation ≥ 0.95) before estimating trial variance; near-identical arms shrink the hurdle
   to almost nothing.
5. **A no-search control.** Any search reports a seed-only control on the same folds, and says
   in advance what a control win means.
6. **Pinned files stay pinned.** Before editing a shared file, grep receipts and tests for its
   path; if a hash pins it, put the fix in your own code with a test.
7. **Scope the verdict.** Name the population, window, data and candidate family. "These arms
   lost on this data" is a verdict; "no effect exists" is not. A fix made after results is a
   labelled sensitivity, never the headline.
8. **Quote instructions from the source.** A design that relies on the operator's words quotes
   them whole, from the message or the written record; a relay or trimmed quote does not bind.

## Presentation

- Start an Artifact from `quickstart`, and use the account's design system rather than
  hand-rolled styling.
- Before designing tables and charts, study two or three public benchmarks (leaderboards,
  harness papers) and say what you borrowed.
- Tables: sortable by any column, numeric-aware.
- Charts: labelled axes with nothing clipped at phone width, and a marked Pareto frontier on
  cost-vs-latency or cost-vs-accuracy charts.
- Visual first. The operator rated a word-heavy, design-system report as clearly worse than an
  earlier page that was mostly charts. Lead with a one-sentence verdict box, then follow each
  heading with a chart or table and at most three one-line bullets. Keep visible body prose to
  about 350 words and put method, limitations and appendices in `<details>`. Have more charts
  than text sections.
- Prose: plain words, a deslop pass, no repeated facts.

## Review passes before calling it done

1. `advisor` at the approach fork and before done.
2. Haiku low: a mechanical number check against the data files.
3. Fable: one review of a frozen packet (data summary + report), not the transcript.
4. A deslop pass on all prose.
5. Re-run the audit check. Done means it passes on the final data.
