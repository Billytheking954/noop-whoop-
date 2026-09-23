"""CRC-valid constructed fixtures exercise validation; they do not prove SpO2 identity."""
import struct
import unittest

import validate_spo2_candidate as validator
from test_validate_spo2_candidate import make_v18, make_unframed_v18


def rec(frame):
    return {"hex": frame.hex()}


class FrameIntegrityTests(unittest.TestCase):
    def test_both_crcs_and_layout_are_required_before_plausible_bytes_are_used(self):
        original = make_v18(unix=1780000000, sleep_state=2, aux_byte_82=97)
        self.assertTrue(validator.wf.verify_whoop5_frame(original))
        corruptions = []
        # Header, timestamp, plausible candidate and trailer mutations all retain v18.
        for offset in (0, 2, 6, 15, 82, 123):
            changed = bytearray(original)
            changed[offset] ^= 1
            corruptions.append(bytes(changed))
        corruptions.extend((original[:-1], original + b"\x00", make_unframed_v18(aux_byte_82=97)))
        for damaged in corruptions:
            with self.subTest(frame=damaged.hex()):
                counts = {}
                self.assertEqual(list(validator.iter_v18_records([rec(damaged)], diagnostics=counts)), [])
                self.assertEqual(counts["invalid_integrity"], 1)
        counts = {}
        records = list(validator.iter_v18_records([rec(original)] + [rec(x) for x in corruptions],
                                                 diagnostics=counts))
        self.assertEqual([row["aux_byte_82"] for row in records], [97])
        self.assertEqual(counts["decoded"], 1)
        self.assertEqual(counts["invalid_integrity"], len(corruptions))

    def test_crc_valid_different_packet_or_layout_is_not_v18(self):
        for index, value in ((8, 40), (9, 20)):
            frame = bytearray(make_v18(aux_byte_82=97))
            frame[index] = value
            struct.pack_into("<I", frame, 120, validator.wf.crc32(frame[8:120]))
            self.assertTrue(validator.wf.verify_whoop5_frame(frame))
            counts = {}
            self.assertEqual(list(validator.iter_v18_records([rec(frame)], diagnostics=counts)), [])
            self.assertEqual(counts["unsupported_layout"], 1)

    def test_crc_valid_wrong_envelope_format_is_rejected(self):
        frame = bytearray(make_v18(aux_byte_82=97))
        frame[1] = 2
        struct.pack_into("<H", frame, 6, validator.wf.crc16_modbus(frame[:6]))
        self.assertTrue(validator.wf.verify_whoop5_frame(frame))
        self.assertEqual(list(validator.iter_v18_records([rec(frame)])), [])

    def test_invalid_hex_and_non_text_values_are_counted_without_crashing(self):
        counts = {}
        inputs = [{"hex": "zz"}, {"hex": 82}, None, {}, {"hex": ""}]
        self.assertEqual(list(validator.iter_v18_records(inputs, diagnostics=counts)), [])
        self.assertEqual(counts["invalid_encoding"], len(inputs))


if __name__ == "__main__":
    unittest.main()
