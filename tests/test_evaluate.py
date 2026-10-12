"""Synthetic fixtures test arithmetic and ingestion, never trading performance."""
import csv
from datetime import datetime
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import evaluate


class EvaluationTests(unittest.TestCase):
    def trades(self):
        time = datetime(2026, 1, 1, 12)
        return [evaluate.Trade(str(i), time, time, 0.1, pnl)
                for i, pnl in enumerate([100.0, -50.0, 25.0])]

    def test_known_cash_metrics_and_peak_drawdown(self):
        m = evaluate.metrics(self.trades(), 10000)
        self.assertEqual(m["net"], 75)
        self.assertEqual(m["profit_factor"], 2.5)
        self.assertEqual(m["dd_cash"], 50)
        self.assertAlmostEqual(m["dd_pct"], 50 / 10100 * 100)
        self.assertEqual(m["expectancy"], 25)

    def test_losing_streak_and_zero_profit_case(self):
        t = self.trades()[0]
        trades = [evaluate.Trade(str(i), t.entry, t.exit, 0.1, p)
                  for i, p in enumerate([-1, -2, 0, -4, -3, -2])]
        self.assertEqual(evaluate.metrics(trades, 100)["longest_loss_streak"], 3)
        self.assertEqual(evaluate.metrics(trades, 100)["profit_factor"], 0.0)
        self.assertIsNone(evaluate.metrics([], 100)["profit_factor"])
        self.assertIn("No closed positions", evaluate.report([], 100, "synthetic fixture", 0, None))

    def write_trades(self, path, rows):
        with path.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle)
            writer.writerow(["position_id", "entry_time", "exit_time", "volume", "net_profit"])
            writer.writerows(rows)

    def test_cost_stress_and_chronological_sorting(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "fixture.csv"
            self.write_trades(path, [
                ["2", "2026.01.01 10:00:00", "2026.01.01 12:00:00", .2, -50],
                ["1", "2026.01.01 10:00:00", "2026.01.01 11:00:00", .1, 100]])
            trades = evaluate.load_trades(path, 20)
            self.assertEqual([t.position_id for t in trades], ["1", "2"])
            self.assertEqual([t.pnl for t in trades], [98, -54])

    def test_bad_csv_is_rejected(self):
        stamp = "2026.01.01 10:00:00"
        cases = [
            [["1", stamp, stamp, .1, 10], ["1", stamp, stamp, .1, 10]],
            [["1", stamp, stamp, -0.1, 10]],
            [["1", stamp, stamp, .1, "nan"]],
            [["1", stamp, stamp, .1]],
            [["1", stamp, "2025.01.01 10:00:00", .1, 10]],
        ]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "fixture.csv"
            for rows in cases:
                with self.subTest(rows=rows):
                    self.write_trades(path, rows)
                    with self.assertRaises(ValueError):
                        evaluate.load_trades(path)

    def test_equity_sampling_uses_own_initial_peak(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "equity.csv"
            path.write_text("timestamp,equity,balance\n"
                            "2026.01.01 00:00:00,10000,10000\n"
                            "2026.01.01 01:00:00,10100,10000\n"
                            "2026.01.01 02:00:00,9800,10000\n", encoding="utf-8")
            n, cash, percent = evaluate.equity_drawdown(path, None, None)
            self.assertEqual((n, cash), (3, 300))
            self.assertAlmostEqual(percent, 300 / 10100 * 100)

    def test_inclusive_end_and_invalid_balance(self):
        self.assertEqual(evaluate.date_bound("2026-01-01", True), datetime(2026, 1, 2))
        for invalid in (0, -1, float("nan"), float("inf")):
            with self.assertRaises(ValueError):
                evaluate.metrics([], invalid)


if __name__ == "__main__":
    unittest.main()
