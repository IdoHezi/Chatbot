"""PostgreSQL integration checks; only run with an explicit TEST_DATABASE_URL.

Point this at the dedicated empty Supabase test branch after applying the saved
exercise migrations. It must never default to the user's development project.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import json
import os
import unittest
from decimal import Decimal

try:
    import psycopg
except ImportError:  # pragma: no cover - optional integration dependency
    psycopg = None


TEST_DATABASE_URL = os.environ.get("TEST_DATABASE_URL")


@unittest.skipUnless(TEST_DATABASE_URL and psycopg, "requires explicit TEST_DATABASE_URL and psycopg")
class InventoryDatabaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Fail closed if this is not a database initialized with our fixtures.
        with psycopg.connect(TEST_DATABASE_URL) as conn:
            row = conn.execute("""
                select to_regclass('inventory.demo_state'),
                       to_regclass('inventory.purchase_orders'),
                       to_regclass('inventory_checkpoints.checkpoints'),
                       count(*) from inventory.products
            """).fetchone()
            if row != ("inventory.demo_state", "inventory.purchase_orders",
                       "inventory_checkpoints.checkpoints", 12):
                raise RuntimeError("TEST_DATABASE_URL is not the initialized inventory test database")

    def setUp(self):
        with psycopg.connect(TEST_DATABASE_URL) as conn:
            conn.execute("select inventory.reset_demo('budget')")

    @staticmethod
    def _create(conn, supplier: str, key: str, lines: list[dict]):
        return conn.execute(
            "select inventory.create_purchase_order(%s, %s, %s::jsonb)",
            (supplier, key, json.dumps(lines)),
        ).fetchone()[0]

    def test_invalid_quantities_packs_and_caps_rollback(self):
        invalid = [
            ("DESK", "frac", [{"sku": "PEN-BLU", "quantity": 100.5}]),
            ("DESK", "pack", [{"sku": "PEN-BLU", "quantity": 101}]),
            ("DESK", "moq", [{"sku": "PEN-BLU", "quantity": 50}]),
            ("NORTH", "cap", [{"sku": "PAPER-A4", "quantity": 1300}]),
        ]
        with psycopg.connect(TEST_DATABASE_URL) as conn:
            for supplier, key, lines in invalid:
                with conn.transaction():
                    conn.execute("SAVEPOINT invalid_order")
                    with self.assertRaises(psycopg.Error):
                        self._create(conn, supplier, key, lines)
                    conn.execute("ROLLBACK TO SAVEPOINT invalid_order")
            count = conn.execute("select count(*) from inventory.purchase_orders").fetchone()[0]
            self.assertEqual(count, 0)

    def test_idempotency_replay_and_changed_payload_rejection(self):
        lines = [{"sku": "PEN-BLU", "quantity": 100}]
        with psycopg.connect(TEST_DATABASE_URL) as conn:
            first = self._create(conn, "DESK", "idempotent-test", lines)
            replay = self._create(conn, "DESK", "idempotent-test", lines)
            self.assertEqual(first["order_id"], replay["order_id"])
            self.assertTrue(replay["idempotent_replay"])
            with self.assertRaises(psycopg.Error):
                self._create(conn, "DESK", "idempotent-test", [{"sku": "PEN-BLU", "quantity": 150}])

    def test_cumulative_cap_is_shared_across_split_orders(self):
        with psycopg.connect(TEST_DATABASE_URL) as conn:
            self._create(conn, "DESK", "cap-700", [{"sku": "PEN-BLU", "quantity": 700}])
            self._create(conn, "DESK", "cap-500", [{"sku": "PEN-BLU", "quantity": 500}])
            with self.assertRaises(psycopg.Error):
                self._create(conn, "DESK", "cap-over", [{"sku": "PEN-BLU", "quantity": 100}])

    def test_send_and_receipt_are_repeat_safe(self):
        with psycopg.connect(TEST_DATABASE_URL) as conn:
            order = self._create(conn, "DESK", "receipt-test", [{"sku": "PEN-BLU", "quantity": 100}])
            first_send = conn.execute("select inventory.send_purchase_order(%s::uuid)",
                                      (order["order_id"],)).fetchone()[0]
            replay_send = conn.execute("select inventory.send_purchase_order(%s::uuid)",
                                       (order["order_id"],)).fetchone()[0]
            self.assertEqual(first_send["sent_on"], replay_send["sent_on"])
            conn.execute("select inventory.advance_clock(2)")
            first_receipt = conn.execute("select inventory.receive_due_orders()").fetchone()[0]
            replay_receipt = conn.execute("select inventory.receive_due_orders()").fetchone()[0]
            self.assertEqual(first_receipt["orders_received"], 1)
            self.assertEqual(replay_receipt["orders_received"], 0)
            stock = conn.execute("select on_hand_units from inventory.stock where sku='PEN-BLU'").fetchone()[0]
            self.assertEqual(stock, 300)

    def test_fixture_counts_and_privileges(self):
        with psycopg.connect(TEST_DATABASE_URL) as conn:
            counts = conn.execute("""
                select (select count(*) from inventory.products),
                       (select count(*) from inventory.suppliers),
                       (select count(*) from inventory.sales_history),
                       (select count(*) from inventory.supplier_messages),
                       (select count(*) from inventory_checkpoints.checkpoint_migrations where v=8)
            """).fetchone()
            self.assertEqual(counts, (12, 4, 2160, 5, 1))
            denied = conn.execute("""
                select bool_and(c.relrowsecurity)
                   and bool_and(not has_table_privilege('anon', c.oid, 'select'))
                   and bool_and(not has_table_privilege('authenticated', c.oid, 'select'))
                  from pg_class c join pg_namespace n on n.oid=c.relnamespace
                 where n.nspname='inventory' and c.relkind='r'
            """).fetchone()[0]
            self.assertTrue(denied)

    def test_concurrent_orders_cannot_exceed_shared_budget(self):
        orders = [
            ("TECH", "parallel-toner", [{"sku": "TONER-BLK", "quantity": 100}]),
            ("TECH", "parallel-chairs", [{"sku": "CHAIR-ERG", "quantity": 50}]),
        ]

        def attempt(args):
            supplier, key, lines = args
            try:
                with psycopg.connect(TEST_DATABASE_URL) as conn:
                    return self._create(conn, supplier, key, lines)
            except psycopg.Error as exc:
                return {"error": exc.sqlstate}

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(attempt, orders))
        accepted = [result for result in results if "error" not in result]
        rejected = [result for result in results if "error" in result]
        self.assertEqual(len(accepted), 1, results)
        self.assertEqual(len(rejected), 1, results)
        total = Decimal(str(accepted[0]["total_amount"]))
        self.assertIn(total, {Decimal("11430.00"), Decimal("8580.00")})


if __name__ == "__main__":
    unittest.main()
