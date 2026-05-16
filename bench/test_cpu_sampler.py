#!/usr/bin/env python3
import importlib.util
import os
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("cpu_sampler.py")
spec = importlib.util.spec_from_file_location("cpu_sampler", MODULE_PATH)
cpu_sampler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cpu_sampler)


class CpuSamplerTests(unittest.TestCase):
    def test_rss_bytes_total_includes_current_process(self):
        proc = cpu_sampler.psutil.Process(os.getpid())
        rss = cpu_sampler.rss_bytes_total(proc)
        self.assertGreater(rss, 0)
        self.assertGreaterEqual(rss, proc.memory_info().rss)

    def test_sample_header_includes_rss_bytes(self):
        self.assertEqual(cpu_sampler.SAMPLE_HEADER, "ts_ms cpu_pct rss_bytes")


if __name__ == "__main__":
    unittest.main()
