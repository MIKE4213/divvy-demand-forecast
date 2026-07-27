"""Print the forecast's daily peak hour -- a fast sanity check after a build."""

from __future__ import annotations

from pathlib import Path

import duckdb

DB = Path(__file__).resolve().parent.parent / "divvy.duckdb"
DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

QUERY = """
select
    forecast_date,
    day_of_week,
    hour_of_day,
    expected_rides,
    lower_bound,
    upper_bound,
    confidence
from forecast_hourly_demand
qualify row_number() over (
    partition by forecast_date order by expected_rides desc
) = 1
order by forecast_date
"""


def main() -> None:
    if not DB.exists():
        raise SystemExit("no database yet -- run `make ingest` then `make run`")

    con = duckdb.connect(str(DB), read_only=True)
    rows = con.execute(QUERY).fetchall()

    print(f"\n  Peak forecast hour per day ({len(rows)}-day horizon)\n")
    print(f"  {'date':<12} {'day':<5} {'peak':<7} {'expected':>9} "
          f"{'band':>17} {'conf':>6}")
    print("  " + "-" * 62)
    for d, dow, hod, exp, lo, hi, conf in rows:
        band = f"{lo:,.0f} - {hi:,.0f}"
        print(f"  {str(d):<12} {DAYS[int(dow)]:<5} {hod:02d}:00   "
              f"{exp:>9,.0f} {band:>17} {conf:>6.2f}")

    total = con.execute("select count(*) from forecast_hourly_demand").fetchone()[0]
    hours = con.execute("select count(*) from fct_hourly_rides").fetchone()[0]
    trips = con.execute("select count(*) from stg_trips").fetchone()[0]
    print(f"\n  {trips:,} trips -> {hours:,} hourly buckets -> "
          f"{total:,} forecast rows\n")
    con.close()


if __name__ == "__main__":
    main()
