#!/usr/bin/env python3
"""Evaluate REAL exported MT5 trades; this does not simulate or invent returns."""
from __future__ import annotations
import argparse
import csv
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
import math


@dataclass(frozen=True)
class Trade:
    position_id: str
    entry: datetime
    exit: datetime
    volume: float
    pnl: float


def stamp(value: str) -> datetime:
    if not isinstance(value, str):
        raise ValueError("Missing timestamp field")
    return datetime.strptime(value.strip(), "%Y.%m.%d %H:%M:%S")


def finite_number(value: str, name: str) -> float:
    if not isinstance(value, str):
        raise ValueError(f"Missing {name} field")
    number = float(value)
    if not math.isfinite(number):
        raise ValueError(f"{name} must be finite")
    return number


def load_trades(path: Path, extra_cost_per_lot: float = 0.0) -> list[Trade]:
    trades, seen = [], set()
    with path.open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        required = {"position_id", "entry_time", "exit_time", "volume", "net_profit"}
        if not required.issubset(reader.fieldnames or []):
            raise ValueError("Use the bot's *_trades.csv export; required columns are missing")
        for row in reader:
            pid = row["position_id"].strip()
            if not pid or pid in seen:
                raise ValueError(f"Missing or duplicate position ID: {pid!r}")
            seen.add(pid)
            volume = finite_number(row["volume"], "volume")
            pnl = finite_number(row["net_profit"], "net_profit")
            entry, exit_time = stamp(row["entry_time"]), stamp(row["exit_time"])
            if volume <= 0 or exit_time < entry:
                raise ValueError(f"Invalid volume or chronology for position {pid}")
            trades.append(Trade(pid, entry, exit_time, volume,
                                pnl - volume * extra_cost_per_lot))
    return sorted(trades, key=lambda trade: (trade.exit, trade.position_id))


def drawdown(values: list[float], initial: float) -> tuple[float, float]:
    peak, max_cash, max_pct = initial, 0.0, 0.0
    for value in values:
        peak = max(peak, value)
        max_cash = max(max_cash, peak - value)
        if peak > 0:
            max_pct = max(max_pct, 100 * (peak - value) / peak)
    return max_cash, max_pct


def metrics(trades: list[Trade], initial: float) -> dict:
    if not math.isfinite(initial) or initial <= 0:
        raise ValueError("Starting balance must be finite and positive")
    winners = [t.pnl for t in trades if t.pnl > 0]
    losers = [t.pnl for t in trades if t.pnl < 0]
    profit, loss = sum(winners), -sum(losers)
    running, balances, streak, longest = initial, [], 0, 0
    for trade in trades:
        running += trade.pnl
        balances.append(running)
        streak = streak + 1 if trade.pnl < 0 else 0
        longest = max(longest, streak)
    dd_cash, dd_pct = drawdown(balances, initial)
    return {
        "trades": len(trades), "net": running - initial,
        "return_pct": 100 * (running - initial) / initial,
        "win_pct": 100 * len(winners) / len(trades) if trades else 0.0,
        "profit_factor": profit / loss if loss else (math.inf if profit else None),
        "expectancy": (running - initial) / len(trades) if trades else 0.0,
        "dd_cash": dd_cash, "dd_pct": dd_pct, "longest_loss_streak": longest,
    }


def equity_drawdown(path: Path, start: datetime | None,
                    end: datetime | None) -> tuple[int, float, float]:
    values = []
    last_time = None
    with path.open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        if not {"timestamp", "equity"}.issubset(reader.fieldnames or []):
            raise ValueError("Use the bot's *_equity.csv export")
        for row in reader:
            when, value = stamp(row["timestamp"]), finite_number(row["equity"], "equity")
            if last_time is not None and when < last_time:
                raise ValueError("Equity samples must be chronological")
            last_time = when
            if (start is None or when >= start) and (end is None or when < end):
                values.append(value)
    if not values:
        return 0, 0.0, 0.0
    cash, percent = drawdown(values, values[0])
    return len(values), cash, percent


def report(trades: list[Trade], initial: float, label: str,
           extra_cost: float, sampled_equity: tuple[int, float, float] | None) -> str:
    m = metrics(trades, initial)
    pf = "N/A" if m["profit_factor"] is None else (
        "No losing trades; insufficient downside evidence" if math.isinf(m["profit_factor"])
        else f'{m["profit_factor"]:.2f}')
    lines = [f"# XAUUSD backtest evaluation — {label}", "",
             "Computed from supplied closed positions. Amounts use the MT5 account currency.", "",
             "| Metric | Result |", "|---|---:|",
             f'| Closed positions | {m["trades"]} |',
             f'| Net profit after recorded costs and additional cost stress | {m["net"]:.2f} |',
             f'| Return on the supplied starting balance | {m["return_pct"]:.2f}% |',
             f'| Win rate | {m["win_pct"]:.2f}% |',
             f'| Profit factor | {pf} |',
             f'| Average net profit per position | {m["expectancy"]:.2f} |',
             f'| Closed-position drawdown | {m["dd_cash"]:.2f} / {m["dd_pct"]:.2f}% |',
             f'| Longest losing streak | {m["longest_loss_streak"]} |',
             f'| Extra round-trip cost per lot | {extra_cost:.2f} |', ""]
    if sampled_equity:
        n, cash, pct = sampled_equity
        if n:
            lines += [f"Account equity samples: {n}; observed sampled equity drawdown: "
                      f"{cash:.2f} / {pct:.2f}%.", ""]
        else:
            lines += ["No equity samples in the selected interval.", ""]
        if extra_cost:
            lines += ["The additional-cost scenario adjusts closed-position P&L only; "
                      "the equity CSV is the original, unstressed path.", ""]
    lines += ["Closed-position drawdown excludes losses while positions are open. "
              "Equity samples can also miss losses between samples. Use the MT5 tester's "
              "real-tick equity drawdown as the authoritative measure. Account equity "
              "includes any other account activity.", "", "## Monthly realized results", "",
              "| Month of exit | Positions | Net profit |", "|---|---:|---:|"]
    buckets: dict[str, list[Trade]] = {}
    for trade in trades:
        buckets.setdefault(trade.exit.strftime("%Y-%m"), []).append(trade)
    for month, group in sorted(buckets.items()):
        lines.append(f"| {month} | {len(group)} | {sum(t.pnl for t in group):.2f} |")
    if not buckets:
        lines.append("| No closed positions | 0 | 0.00 |")
    lines += ["", "## Evidence still needed", "",
              "- Identify whether this is training data or untouched out-of-sample data.",
              "- Record broker, symbol specification, dates, spread, commission, leverage, "
              "execution model, and exact input settings.",
              "- Compare with higher costs and with neighboring parameter settings.",
              "- Confirm performance on a demo account; profitable history alone does "
              "not establish future profitability.", ""]
    return "\n".join(lines)


def date_bound(value: str | None, inclusive_end: bool = False) -> datetime | None:
    if value is None:
        return None
    result = datetime.strptime(value, "%Y-%m-%d")
    return result + timedelta(days=1) if inclusive_end else result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trades", type=Path, required=True)
    parser.add_argument("--starting-balance", type=float, required=True)
    parser.add_argument("--equity", type=Path)
    parser.add_argument("--start", help="Include entries on/after this broker date, YYYY-MM-DD")
    parser.add_argument("--end", help="Include exits through this broker date, YYYY-MM-DD")
    parser.add_argument("--extra-cost-per-lot", type=float, default=0.0)
    parser.add_argument("--label", default="unclassified dataset")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        if not math.isfinite(args.extra_cost_per_lot) or args.extra_cost_per_lot < 0:
            raise ValueError("Extra cost must be finite and nonnegative")
        start, end = date_bound(args.start), date_bound(args.end, True)
        if start and end and start >= end:
            raise ValueError("The start must precede the end")
        trades = [t for t in load_trades(args.trades, args.extra_cost_per_lot)
                  if (start is None or t.entry >= start) and (end is None or t.exit < end)]
        eq = equity_drawdown(args.equity, start, end) if args.equity else None
        content = report(trades, args.starting_balance, args.label,
                         args.extra_cost_per_lot, eq)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    if args.report:
        args.report.write_text(content, encoding="utf-8")
        print(f"Wrote {args.report}")
    else:
        print(content)


if __name__ == "__main__":
    main()
