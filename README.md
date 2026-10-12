# BhavyaGold — XAUUSD MT5 bot

This is a complete **source-code research bot** for your broker's XAUUSD gold
instrument. It trades M5 box breakouts followed by a retest, confirmed by H1
trend strength and, by default, the previous completed D1 trend.

**Returns are unverified.** No market backtest, parameter optimization, native
MetaEditor compilation, or real-account execution was performed when creating
this project. Code checks are described in `VALIDATION.md`. The strategy is a
testable hypothesis; it may lose money. The 2R take-profit setting is a target
for an individual position, not an expected account return.

## Start here

1. Unzip the project on the computer running desktop MetaTrader 5.
2. In MT5, select **File → Open Data Folder**. Copy the entire `BhavyaGold`
   folder from this project's `MQL5/Experts` into that terminal's `MQL5/Experts`.
   Keep `BhavyaGold_XAUUSD.mq5` and `GoldCore.mqh` in the same folder.
3. Open `BhavyaGold_XAUUSD.mq5` in MetaEditor and press **F7**. Confirm there are
   zero compiler errors before proceeding. The `.ex5` executable is produced by
   your MetaEditor; it is not supplied in this download.
4. Open **View → Strategy Tester**, select the EA and your broker's exact gold
   symbol, choose **M5**, and use the testing settings below.
5. After testing, attach it to an XAUUSD M5 **demo** chart and enable Algo Trading
   for that demo terminal/EA. Read the chart status and Experts log.

The filename accepts symbols starting with `XAUUSD` or `GOLD`, including broker
suffixes. Check that the symbol actually represents gold quoted in USD.
Indicators are fixed to M5/H1/D1 even if the chart has another period.

## Strategy rules

1. The last completed H1 bar must agree with EMA20/EMA50, the EMA20 slope,
   ADX14 ≥ 18, and the directional-indicator lines. For a buy, H1 close is above
   EMA20; for a sell it is below. By default, completed D1 EMA20/EMA50 and D1
   close versus EMA20 must also agree. All these are adjustable inputs.
2. A box consists of the high/low of the **12 M5 bars before the signal bar**.
   Its width must be between 1 and 4 times M5 ATR14.
3. A completed M5 candle must close at least 0.10 ATR beyond the box, with a
   directional body of at least 0.15 ATR and no excessive range or extension.
4. A **later** completed candle must retest the broken boundary and close back
   in the trend direction. The setup expires after six M5 bars or if the trend
   fails/price closes too deeply into the box.
5. Enter at the next available quote only if spread, price movement, risk,
   session, daily entry count, and margin checks allow it. A rejected setup is
   discarded instead of repeatedly resubmitted.

There is one gold position at a time. No averaging down, grid, martingale, or
lot doubling is used. Stops are submitted with the entry. Initial stop distance
is at least 1.5 ATR and must cover retest structure and broker stop requirements;
entries requiring more than 3 ATR are skipped. Take-profit is 2 times the initial
quoted stop distance. Break-even management starts at 1R and ATR trailing at
1.5R. Maximum hold is 120 minutes; session-end flattening is enabled.

## Defaults and units

| Setting | Default | Meaning |
|---|---:|---|
| Risk target | 0.25% | Current account equity per entry, including configured commission reserve |
| Daily entries | 2 | Unique opening orders; partial fills do not create extra entry counts |
| Daily equity loss lock | 1% | Loss from observed equity at broker-day start |
| Daily peak equity loss lock | 1% | Fall from the highest observed equity of that broker day |
| Campaign peak equity loss lock | 5% | Fall from the stored highest observed equity; stays locked after restart |
| Session | 07:00–20:00 | **Broker server time**, not Toronto time |
| Friday cutoff | 16:00 | Broker server time; own positions are flattened when executable |
| Maximum spread | 0.50 and 0.15 ATR | Both caps apply; 0.50 means $0.50 per ounce in the gold quote |
| Slippage reserve | 0.30 | Gold quote units; also converted to broker points for order deviation |
| Commission reserve | 8.00 per lot | **Account currency**, expected round-trip commission per 1.00 lot |
| Real-account switch | false | EA initialization on a real account is refused by default |
| News blackouts | off | Optional verified, manually supplied CSV schedule |

The preset `presets/research-defaults.set` repeats the main defaults. Start with
the EA defaults and load the preset if desired; it is not an optimized preset.

Lot sizing uses MT5 `OrderCalcProfit` and the broker's own minimum, maximum,
and volume step. If the minimum lot exceeds the calculated risk allowance,
the trade is skipped. Risk is reduced near an equity floor. The sizing reserves
adverse slippage and the commission you configure; margin use is capped at 50%
of currently free margin. Fill risk is rechecked after entry, and missing
SL/TP or an excessive calculated fill risk triggers a protective close.

For example, on a 25,000 account, 0.25% is a **62.50 account-currency risk
target**. Actual losses can exceed a target during gaps, execution delays,
slippage, or unexpected fees. Software guards cannot guarantee a loss ceiling.

## Broker backtest and forward evaluation

Use a dedicated test/demo account so other trades and cash flows do not affect
the account-equity guards or equity export.

| Tester field | Setting |
|---|---|
| Expert | `BhavyaGold/BhavyaGold_XAUUSD` |
| Symbol | Your broker's exact XAUUSD/GOLD symbol |
| Period | M5 |
| Tick model | Every tick based on real ticks |
| Date range | Several market regimes, e.g. 2022-01-01 to 2026-09-30 if available |
| Deposit/currency | Match the account you would actually use |
| Leverage | Match your broker account |
| Execution delay | Include a plausible delay, then stress a higher delay |
| Commission | Match actual broker charging and verify costs appear in the results |
| Optimization | Disabled for the first baseline run |
| Forward split | Reserve the most recent ~30% as untouched forward data |

MT5 downloads history from the selected broker; tick availability and coverage
vary. The filters need sufficient H1 and D1 history for indicator warmup. Do not
substitute M5 OHLC testing for final evaluation: both stop execution and
break-even/trailing updates can change within a candle.

Choose inputs on the earlier period, freeze them, and evaluate the later period
without retuning. Check net profitability after real costs, equity drawdown,
trade count, and how much the result depends on one exceptional trade/month.
Then stress higher spread/fees/delay and nearby parameter settings. A reasonable
research hurdle might be positive untouched-period expectancy, profit factor
above 1.2, and at least 100 positions across varied conditions; these are
project review criteria, not proof of an edge or an assurance of future returns.
Review the tester's maximum **equity** drawdown, especially if a guard trips.

If the baseline loses or the forward period fails, reject or revise the
strategy. Increasing risk does not fix a strategy with negative expectancy.

## Exports and the evaluator

The EA writes `*_equity.csv` at initialization, M5 boundaries, trade events,
and shutdown. It writes `*_trades.csv` when removed, reinitialized, or a normal
single tester run ends. The Experts/Journal log prints the output location:
the terminal's **Common\Files** directory. CSV export is disabled automatically
during optimization to avoid mass output.

The trade ledger aggregates partial fills and includes attached profit,
commission, swap, and fees on both opening and closing deals. It includes
completed positions only. It excludes mixed-owner/reversed positions. Fees
charged as separate balance-level entries without a position ID are not
attributed here; compare the ledger against the broker/tester statement.
Live exports include the available history for that symbol and magic, so exports
from successive restarts can overlap. Analyze one export rather than combining
them blindly.

With Python 3.10 or later, no third-party packages are required:

```bash
python tools/evaluate.py --trades YOUR_RUN_trades.csv --starting-balance 25000 --equity YOUR_RUN_equity.csv --label "untouched forward period" --report forward-report.md
```

To select a broker-date interval or stress extra costs:

```bash
python tools/evaluate.py --trades YOUR_RUN_trades.csv --starting-balance BALANCE_AT_START_OF_SELECTED_INTERVAL --start 2025-10-01 --end 2026-09-30 --extra-cost-per-lot 10 --report cost-stress.md
```

Replace all placeholders with your actual paths/numbers. The extra cost is
additional **round-trip account-currency cost per 1.00 lot**. Recorded costs are
already included in `net_profit` and are not subtracted a second time.
Date filtering includes positions entered on/after the start and fully exited
by the end. Positions spanning the selection boundary are excluded. For a clean
forward result, start a separate tester run at the forward boundary with the
correct deposit rather than using a filtered ledger from a continuous run.

Closed-position drawdown omits open losses. The sampled equity path can miss
intrabar losses and includes other account activity. The extra-cost scenario
adjusts closed P&L, not the original equity samples. **MT5's real-tick equity
statistics remain the authoritative backtest drawdown measurement.**

## Optional scheduled news filter

By default there is **no automatic economic-news exclusion**. Price/spread
filters do not replace a news schedule. To use manually verified blackout times:

1. Copy `news/gold_news.template.csv` to the terminal's Common\Files as
   `gold_news.csv`.
2. Replace both coverage placeholders with actual broker-server timestamps,
   formatted `YYYY.MM.DD HH:MM` or `YYYY.MM.DD HH:MM:SS`.
3. Add verified relevant events as `timestamp,event name`. Coverage should
   describe a date interval whose relevant schedule you actually checked.
4. Set `InpUseNewsBlackouts=true`. The default blackout is 30 minutes before
   through 15 minutes after each supplied event.

The file supports `COVERAGE_START,timestamp` and `COVERAGE_END,timestamp` rows.
An empty-event day is possible when coverage was verified. Missing, malformed,
or out-of-coverage schedules block new entries. Coverage must include the whole
before/after window. The file is read at entry checks so updates can take effect.
Use local tester agents when testing this manual Common\Files schedule. Use the
same historical news schedule/mode in backtest and demo comparisons.

## Restart behavior and operating limits

- Daily baselines, observed peaks, locks, entry-risk checks, and initial stop
  distance use persistent terminal variables scoped to account/server/symbol/
  magic. Daily counts are rebuilt from deal history. Tester runs use isolated
  in-memory risk state. An armed breakout is deliberately discarded on restart.
- One terminal instance per symbol/magic is enforced with a temporary atomic
  lease. This does not coordinate multiple separate terminals/VPS machines.
- The first deployment's daily baseline is **equity at first activation**, not
  a reconstruction of equity earlier that day. Later days use the first
  observed tick of the new broker day. Prop firms can use different clocks,
  balance rules, static/trailing limits, or news restrictions; this is not an
  implementation of any specific firm's rulebook.
- Guards observe total account equity but close/cancel only this bot's own
  positions/orders. Other strategies, deposits, withdrawals, payouts, and
  manual trades can trigger or distort those guards. Do not trade the same
  gold symbol manually alongside this EA, especially on a netting account.
- A campaign drawdown lock survives normal restart. Review the failure before
  beginning a new demo research campaign with a different magic number. Do not
  use state deletion/relabeling to evade a loss limit. Variables are local to
  the terminal and can expire after prolonged inactivity; moving terminals
  does not automatically transfer the risk state.
- Disconnecting or disabling Algo Trading prevents protective modifications/
  close requests. Existing broker-held SL/TP may remain, but active management
  requires the desktop terminal or VPS to run and stay connected.

## Source references

- [OrderCalcProfit: profit/loss in account currency](https://www.mql5.com/en/docs/trading/ordercalcprofit)
- [CTrade PositionModify: tickets and server-result verification](https://www.mql5.com/en/docs/standardlibrary/tradeclasses/ctrade/ctradepositionmodify)
- [Atomic terminal-global updates](https://www.mql5.com/en/docs/globals/globalvariablesetoncondition)
- [MT5 Strategy Tester and forward settings](https://www.metatrader5.com/en/terminal/help/algotrading/testing)
- [Testing and broker history preparation](https://www.metatrader5.com/en/terminal/help/algotrading/test_preparation)

Created 2026-10-06. No broker login, API key, or account connection is bundled.
