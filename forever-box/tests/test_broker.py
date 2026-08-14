import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


class BrokerContractTests(unittest.TestCase):
    def load(self, root: str):
        with patch.dict(os.environ, {"BOX_DATA": root, "BOX_SOCKET_DIR": f"{root}/sockets", "BOX_MAX_SESSIONS": "2"}, clear=False):
            spec = importlib.util.spec_from_file_location("broker_under_test", Path(__file__).parents[1] / "broker.py")
            module = importlib.util.module_from_spec(spec)
            assert spec.loader
            spec.loader.exec_module(module)
            return module

    def test_assignments_are_stable_unique_and_persisted(self):
        with tempfile.TemporaryDirectory() as root:
            module = self.load(root)
            manager = module.SessionManager()
            self.assertEqual(manager._slot("coder"), 0)
            self.assertEqual(manager._slot("researcher"), 1)
            self.assertEqual(manager._slot("coder"), 0)
            restored = module.SessionManager()
            self.assertEqual(restored.assignments, {"coder": 0, "researcher": 1})

    def test_invalid_names_and_capacity_fail_closed(self):
        with tempfile.TemporaryDirectory() as root:
            module = self.load(root)
            manager = module.SessionManager()
            with self.assertRaises(ValueError):
                manager._slot("../escape")
            manager._slot("one")
            manager._slot("two")
            with self.assertRaises(RuntimeError):
                manager._slot("three")


if __name__ == "__main__":
    unittest.main()
