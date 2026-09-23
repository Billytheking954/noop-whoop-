"""Focused fail-closed regressions for the independent @82 comparison."""
import unittest

import spo2_reference as research

START = 1780000000


def row(ts, value, state=2):
    return {"unix": ts, "aux_byte_82": value, "sleep_state": state}


class FailClosedComparisonTests(unittest.TestCase):
    def test_out_of_band_asleep_value_is_not_censored_from_pairing(self):
        records = [row(START, 97), row(START + 1, 160)]
        reference = {START: 97, START + 1: 96}

        result = research.analyze(records, START, START + 2, reference)
        comparison = result["comparison"]

        self.assertEqual(comparison["paired_seconds"], 2)
        self.assertEqual(comparison["unpaired_candidate_seconds"], 0)
        self.assertFalse(result["candidate_range_consistent"])
        self.assertFalse(comparison["candidate_range_consistent"])
        self.assertEqual(result["observations"]["asleep_out_of_band_nonzero_seconds"], 1)
        self.assertEqual(result["availability"], "candidate_range_violation")
        self.assertGreater(
            comparison["matched_sample_differences"]["mean_absolute_difference"], 0
        )

    def test_single_pair_is_explicitly_insufficient(self):
        result = research.analyze([row(START, 97)], START, START + 1, {START: 97})
        comparison = result["comparison"]

        self.assertEqual(comparison["paired_seconds"], 1)
        self.assertEqual(comparison["minimum_paired_seconds"], research.MIN_PAIRED_SECONDS)
        self.assertFalse(comparison["paired_sample_count_sufficient"])
        self.assertEqual(result["availability"], "insufficient_paired_samples")
        self.assertFalse(result["promotion_allowed"])


if __name__ == "__main__":
    unittest.main()
