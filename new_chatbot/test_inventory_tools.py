"""Fast, dependency-free tests for the deterministic inventory calculations."""

from datetime import date
from decimal import Decimal
import unittest

from inventory_tools import (
    average_daily_demand,
    basket_cost,
    choose_supplier_option,
    eoq,
    exact_json_numbers,
    feasible_quantities,
    forecast_stockout,
    money,
    reorder_point,
    select_unit_price,
)


class ArithmeticTests(unittest.TestCase):
    def test_reference_eoq_is_100(self):
        self.assertEqual(eoq(1000, 10, 2), Decimal("100.0"))

    def test_zero_demand_has_zero_eoq_and_no_stockout(self):
        self.assertEqual(eoq(0, 10, 2), 0)
        forecast = forecast_stockout(0, 0, Decimal(0), date(2026, 3, 1), 10)
        self.assertIsNone(forecast.stockout_date)
        self.assertIsNone(forecast.days_to_stockout)

    def test_money_uses_decimal_two_place_rounding(self):
        self.assertEqual(money(Decimal("1.005")), Decimal("1.01"))
        self.assertEqual(money(Decimal("1.004")), Decimal("1.00"))
        with self.assertRaises(TypeError):
            money(1.005)

    def test_postgrest_json_numbers_are_normalized_before_money_math(self):
        row = exact_json_numbers({"unit_price": 5.6, "fees": [1.2, 30]})
        self.assertEqual(row["unit_price"], Decimal("5.6"))
        self.assertEqual(money(row["unit_price"]), Decimal("5.60"))
        self.assertEqual(row["fees"], [Decimal("1.2"), 30])
        with self.assertRaises(TypeError):
            money(5.6)

    def test_average_uses_calendar_denominator_and_annotated_exclusion(self):
        rows = [
            {"sale_id": "bulk-day", "sku": "PEN-BLU", "sale_date": "2026-02-14",
             "units": 915, "annotation": "ordinary 15 plus one-off 900"},
            {"sale_id": "ordinary-day", "sku": "PEN-BLU", "sale_date": "2026-02-15",
             "units": 15, "annotation": None},
            {"sale_id": "outside", "sku": "PEN-BLU", "sale_date": "2026-01-01",
             "units": 1000, "annotation": "old"},
        ]
        start, end = date(2026, 2, 14), date(2026, 2, 15)
        self.assertEqual(average_daily_demand(rows, start, end, sku="PEN-BLU"), Decimal("465"))
        # Exclusion removes that day's normal 15 units along with the extra 900.
        self.assertEqual(average_daily_demand(rows, start, end, ["bulk-day"], "PEN-BLU"), Decimal("7.5"))
        with self.assertRaises(ValueError):
            average_daily_demand(rows, start, end, ["ordinary-day"], "PEN-BLU")
        with self.assertRaises(ValueError):
            average_daily_demand(rows, start, end, ["outside"], "PEN-BLU")

    def test_price_break_is_all_units(self):
        breaks = [{"minimum_quantity": 1, "unit_price": "1.00"},
                  {"minimum_quantity": 500, "unit_price": "0.95"}]
        self.assertEqual(select_unit_price(breaks, 499), Decimal("1.00"))
        self.assertEqual(select_unit_price(breaks, 500), Decimal("0.95"))

    def test_reorder_point(self):
        self.assertEqual(reorder_point(20, 2, 40), Decimal(80))

    def test_evidence_override_switches_from_disrupted_supplier(self):
        suppliers = [{"supplier_id": "NORTH", "lead_time_days": 2},
                     {"supplier_id": "WEST", "lead_time_days": 3}]
        self.assertEqual(choose_supplier_option(suppliers, {"NORTH": 21})["supplier_id"], "WEST")

    def test_feasible_quantities_respect_moq_pack_and_cap(self):
        candidates = feasible_quantities(Decimal(107), pack_size=50, moq_units=100, cap_units=1200)
        self.assertIn(100, candidates)
        self.assertIn(150, candidates)
        self.assertTrue(all(q >= 100 and q % 50 == 0 and q <= 1200 for q in candidates))
        self.assertEqual(feasible_quantities(Decimal(10), 100, 101, 150), [])

    def test_basket_has_single_fee_and_shipping_charge(self):
        supplier = {"ordering_fee": "20", "shipping_fee": "30", "free_shipping_threshold": "600"}
        prices = {
            "PEN-BLU": [{"minimum_quantity": 1, "unit_price": "1.00"}],
            "NOTE-A4": [{"minimum_quantity": 1, "unit_price": "3.00"}],
            "MARK-BLU": [{"minimum_quantity": 1, "unit_price": "2.00"}],
        }
        lines = [{"sku": "PEN-BLU", "quantity": 100},
                 {"sku": "NOTE-A4", "quantity": 100},
                 {"sku": "MARK-BLU", "quantity": 100}]
        separate = sum((basket_cost([line], supplier, prices)["total"] for line in lines), Decimal(0))
        combined = basket_cost(lines, supplier, prices)["total"]
        self.assertEqual(separate, Decimal("750.00"))
        self.assertEqual(combined, Decimal("620.00"))
        self.assertEqual(separate - combined, Decimal("130.00"))

    def test_budget_feasibility_respects_fixed_order_fees(self):
        supplier = {"ordering_fee": "20", "shipping_fee": "30", "free_shipping_threshold": "600"}
        prices = {"PEN-BLU": [{"minimum_quantity": 1, "unit_price": "1.00"}]}
        feasible = basket_cost([{"sku": "PEN-BLU", "quantity": 100}], supplier, prices)["total"]
        self.assertEqual(feasible, Decimal("150.00"))
        self.assertLessEqual(feasible, Decimal("150.00"))
        self.assertGreater(feasible, Decimal("149.99"))

    def test_basket_rejects_noninteger_duplicate_and_nonpositive_quantities(self):
        supplier = {"ordering_fee": 0, "shipping_fee": 0, "free_shipping_threshold": 0}
        prices = {"A": [{"minimum_quantity": 1, "unit_price": "1"}]}
        for quantity in (0, -1, 1.5, True):
            with self.subTest(quantity=quantity), self.assertRaises(ValueError):
                basket_cost([{"sku": "A", "quantity": quantity}], supplier, prices)
        with self.assertRaises(ValueError):
            basket_cost([{"sku": "A", "quantity": 1}, {"sku": "A", "quantity": 2}],
                        supplier, prices)

    def test_scheduled_receipt_arrives_at_start_of_due_date(self):
        forecast = forecast_stockout(10, 0, Decimal(5), date(2026, 3, 1), 3,
            [{"due_on": "2026-03-02", "quantity": 10}])
        self.assertEqual(forecast.stockout_date, date(2026, 3, 4))

    def test_delivery_gap_is_reported(self):
        forecast = forecast_stockout(10, 0, Decimal(5), date(2026, 3, 1), 4)
        self.assertEqual(forecast.stockout_date, date(2026, 3, 2))
        self.assertEqual(forecast.delivery_gap_days, 3)


if __name__ == "__main__":
    unittest.main()
