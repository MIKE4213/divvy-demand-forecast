"""
Ingest Divvy (Chicago bike share) trip data into DuckDB.

Divvy publishes monthly trip archives as public zipped CSVs — no API key, no auth.
Each row is one trip: start/end timestamp, start/end station, rider type.

This mirrors the ingestion pattern I use in production: pull a window of source
data, land it raw, and let the transformation layer own all business logic. The
watermark below is the same idea as the `last_sync_at` document in the call
pipeline it's modelled on — re-running is safe and only fetches what's missing.
"""

from __future__ import annotations

import argparse
import io
import logging
import sys
import zipfile
from dataclasses import dataclass
from datetime import date
from pathlib import Path

import duckdb
import requests

LOG = logging.getLogger("ingest")

BASE_URL = "https://divvy-tripdata.s3.amazonaws.com"
DB_PATH = Path(__file__).resolve().parent.parent / "divvy.duckdb"

# Columns we keep from the source CSV. Divvy has changed its schema over the
# years; these six have been stable since 2020-04 and are all the marts need.
KEEP_COLUMNS = [
    "ride_id",
    "rideable_type",
    "started_at",
    "ended_at",
    "start_station_name",
    "member_casual",
]


@dataclass(frozen=True)
class Month:
    year: int
    month: int

    @property
    def key(self) -> str:
        return f"{self.year:04d}{self.month:02d}"

    @property
    def url(self) -> str:
        return f"{BASE_URL}/{self.key}-divvy-tripdata.zip"

    def __str__(self) -> str:
        return f"{self.year:04d}-{self.month:02d}"


def recent_months(n: int, ending: date | None = None) -> list[Month]:
    """The n complete months ending before `ending` (default: today)."""
    ending = ending or date.today()
    months: list[Month] = []
    y, m = ending.year, ending.month
    for _ in range(n):
        m -= 1
        if m == 0:
            y, m = y - 1, 12
        months.append(Month(y, m))
    return list(reversed(months))


def ensure_schema(con: duckdb.DuckDBPyConnection) -> None:
    con.execute("create schema if not exists raw")
    con.execute(
        """
        create table if not exists raw.trips (
            ride_id            varchar,
            rideable_type      varchar,
            started_at         timestamp,
            ended_at           timestamp,
            start_station_name varchar,
            member_casual      varchar,
            source_month       varchar
        )
        """
    )
    # Watermark: which source months have already landed. Makes the whole
    # script idempotent — the same reason the production pipeline upserts on a
    # natural key instead of blind-inserting.
    con.execute(
        """
        create table if not exists raw.ingest_log (
            source_month varchar primary key,
            row_count    bigint,
            ingested_at  timestamp default current_timestamp
        )
        """
    )


def already_ingested(con: duckdb.DuckDBPyConnection) -> set[str]:
    rows = con.execute("select source_month from raw.ingest_log").fetchall()
    return {r[0] for r in rows}


def fetch_month(month: Month) -> bytes | None:
    """Download and unzip one month's CSV. Returns None if the month isn't published."""
    LOG.info("fetching %s", month.url)
    resp = requests.get(month.url, timeout=180)
    if resp.status_code == 404:
        LOG.warning("%s not published yet — skipping", month)
        return None
    resp.raise_for_status()

    with zipfile.ZipFile(io.BytesIO(resp.content)) as zf:
        names = [n for n in zf.namelist() if n.endswith(".csv") and "__MACOSX" not in n]
        if not names:
            raise RuntimeError(f"no CSV inside {month.url}")
        return zf.read(names[0])


def load_month(con: duckdb.DuckDBPyConnection, month: Month, csv_bytes: bytes) -> int:
    tmp = DB_PATH.parent / f".tmp-{month.key}.csv"
    tmp.write_bytes(csv_bytes)
    try:
        cols = ", ".join(KEEP_COLUMNS)
        con.execute(
            f"""
            insert into raw.trips
            select {cols}, '{month.key}' as source_month
            from read_csv_auto('{tmp}', header = true, sample_size = -1)
            """
        )
        count = con.execute(
            "select count(*) from raw.trips where source_month = ?", [month.key]
        ).fetchone()[0]
        con.execute(
            "insert or replace into raw.ingest_log (source_month, row_count) values (?, ?)",
            [month.key, count],
        )
        return count
    finally:
        tmp.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--months", type=int, default=6, help="how many recent complete months to load"
    )
    parser.add_argument(
        "--force", action="store_true", help="re-download months already in the log"
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s"
    )

    con = duckdb.connect(str(DB_PATH))
    ensure_schema(con)
    done = set() if args.force else already_ingested(con)

    total = 0
    for month in recent_months(args.months):
        if month.key in done:
            LOG.info("%s already ingested — skipping", month)
            continue
        csv_bytes = fetch_month(month)
        if csv_bytes is None:
            continue
        if args.force:
            con.execute("delete from raw.trips where source_month = ?", [month.key])
        rows = load_month(con, month, csv_bytes)
        LOG.info("%s → %s rows", month, f"{rows:,}")
        total += rows

    grand = con.execute("select count(*) from raw.trips").fetchone()[0]
    LOG.info("done. %s rows this run, %s rows total in raw.trips", f"{total:,}", f"{grand:,}")
    con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
