# Validation status — 2026-10-06

## Completed

`python3 tools/validate.py` passed:

- Six Python evaluator tests: known profit-factor/expectancy/drawdown arithmetic,
  losing streaks, empty histories, cost stress, chronological sorting, duplicate
  positions, invalid/missing values, sampled equity drawdown, and date bounds.
- C++ harness compiled with `-Wall -Wextra -Werror`, then ran deterministic
  buy/sell breakout/retest and session-boundary cases.
- 100,000 seeded randomized cases checked the production `GoldCore.mqh`
  functions for risk-budget floors, volume-step compliance, no minimum-lot
  round-up, and directionally conservative tick-price rounding.

The C++ harness includes the actual production `.mqh` decisions and supplies
standard C++ equivalents of the MQL mathematical functions. It is **not** a
MetaEditor compiler or an MT5 trading-server simulator. Synthetic test fixtures
are arithmetic checks, not evidence of a profitable trading strategy.

## Not completed in this environment

- Native `.mq5` compilation: MetaEditor/MT5 is not installed; no `.ex5` is bundled.
- Full event-loop, account-history, persistence, CSV-file, and broker execution
  integration tests in MT5.
- Broker gold tick backtest, untouched forward evaluation, cost stress on real
  data, or demo forward run.
- Any measured or verified return, win rate, market profit factor, or market
  drawdown. No profitable performance claim is made.

## MT5 integration checks before using results

1. Compile both source files together in MetaEditor; fix/review any compiler
   errors or warnings before enabling the EA.
2. Run the default settings using real broker ticks. Check that a later retest
   follows each breakout and that H1/D1 filters use completed bars.
3. Test both buy and sell fills, minimum-lot rejection, broker stop/freeze
   distances, partial fills if supported, and rejection/close retry behavior.
4. On demo, verify disabling real-account use, restart during an open trade,
   daily guard reset on server-date change, and persistent campaign lock after
   a guard breach. Do not use real funds for fault injection.
5. Confirm that an optional missing/malformed/stale news CSV blocks entries,
   and verify blackout boundaries with a correctly covered test schedule.
6. Compare the exported completed-position ledger and attached costs against
   the native tester statement. Compare the account equity samples against
   the tester's real-tick equity curve.

The README explains the settings, test split, operating limits, and how to
evaluate actual output without treating sample fixtures as trading results.
