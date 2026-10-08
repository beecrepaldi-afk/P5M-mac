"""Tests use synthetic metrics only; no app, device, or Metal collection."""
import importlib.util
import json
import unittest
from pathlib import Path

module_path = Path(__file__).resolve().parents[1] / 'mac' / 'metal_diagnostics.py'
spec = importlib.util.spec_from_file_location('metal_diagnostics', module_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def row(a=0, b=1, frames=60, duration=1):
    return {'Start Date': f'2026-10-07T05:00:0{a}Z', 'End Date': f'2026-10-07T05:00:0{b}Z',
            'Total Duration (sec)': duration,
            'Presented Frame Stats': {'Frame Count': frames,
                'On-GPU Walltime Stats': {'Count': frames, 'Total (ms)': frames * 5, 'Max (ms)': 9}},
            'Skipped Frame Stats': {'Frame Count': 0},
            'Frame-On-Glass Interval Stats': {'Count': frames, 'Total (ms)': 1000, 'Max (ms)': 17}}


def data(rows, process='chiaki'):
    return [{'Process': process, 'PID': 'secret-id', 'Private path': '/Users/private',
             'Layers': [{'Layer ID': 'private-layer', 'Stats Timeline': rows}]}]


class Tests(unittest.TestCase):
    def setUp(self):
        self.start = m.date('2026-10-07T02:00:00-03:00')
        self.end = m.date('2026-10-07T05:00:02Z')

    def test_weighting_and_privacy(self):
        report = m.summarize(data([row(), row(1, 2, 30)]) + data([row()], 'Other app'), self.start, self.end)
        self.assertEqual(report['groups'][0]['presented_fps'], 45)
        self.assertEqual(report['groups'][0]['gpu_ms']['mean'], 5)
        output = json.dumps(report)
        for private in ('secret-id', '/Users/private', 'private-layer', 'Other app', 'PID', 'chiaki'):
            self.assertNotIn(private, output)

    def test_boundary_not_estimated(self):
        report = m.summarize(data([row(), row(1, 2)]), m.date('2026-10-07T05:00:00.5Z'), self.end)
        self.assertEqual(report['groups'][0]['samples'], 1)
        self.assertEqual(report['groups'][0]['excluded_boundary_samples'], 1)
        self.assertEqual(report['groups'][0]['presented_frames'], 60)

    def test_layers_never_summed(self):
        report = m.summarize(data([row()]) + data([row()], 'P5M'), self.start, self.end)
        self.assertEqual(len(report['groups']), 2)
        self.assertTrue(all(g['presented_fps'] == 60 for g in report['groups']))

    def test_missing_empty_or_invalid(self):
        for sample in ([], data([row()], 'Unrelated'), data([row(frames=float('nan'))])):
            with self.assertRaises(ValueError):
                m.summarize(sample, self.start, self.end)
        with self.assertRaises(ValueError):
            m.date('2026-10-07T05:00:00')
        with self.assertRaises(ValueError):
            m.summarize(data([row()]), self.end, self.start)

    def test_no_zero_as_missing_measurement(self):
        g = m.summarize(data([row()]), self.start, self.end)['groups'][0]
        self.assertIsNone(g['drawable_wait_ms']['mean'])
        self.assertIsNone(g['drawable_wait_ms']['max'])


if __name__ == '__main__':
    unittest.main()
