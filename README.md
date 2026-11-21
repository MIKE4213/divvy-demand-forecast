# Divvy Demand Forecast

A small, complete analytics pipeline: ingest 1.9M public bike-share trips, model
them in SQL with dbt, and forecast hourly demand a week out with a ±1σ
uncertainty band.

I built a seasonal call-arrival forecast in production at work, in MongoDB's
aggregation framework, against data I can't share. This is the same method
rebuilt in SQL against data anyone can download — so the reasoning is inspectable
rather than just claimed.

```
make setup && make all
```

Runs on DuckDB, so there's no warehouse account, no credentials, and no cloud
setup. Clone it and it works.

---

## The result

The model is given nothing but timestamps. It recovers Chicago's commute
structure on its own — a morning peak at 08:00, a larger evening peak at 17:00,
and the midday trough between them:

```
Wednesday, expected rides per hour

06:00     715  ############################
07:00   1,434  #########################################################
08:00   1,768  ######################################################################
09:00     854  ##################################
12:00     782  ###############################
15:00   1,219  ################################################
16:00   1,866  ##########################################################################
17:00   2,535  #####################################################################################################
18:00   2,071  ##################################################################################
20:00   1,009  ########################################
```

Weekends have a different shape entirely — no commute peaks, one broad midday
hump:

```
date         day   peak hour   expected          ±1σ band   confidence
2026-07-01   Wed       17:00      2,535     1,804 – 3,267        1.00
2026-07-03   Fri       17:00      2,522     1,993 – 3,050        1.00
2026-07-04   Sat       15:00      2,498     2,105 – 2,890        1.00
2026-07-05   Sun       14:00      1,776     1,109 – 2,442        1.00
```

That weekday/weekend divergence is the signal the method is built to capture,
and nothing in the code hardcodes it.

---

## How it works

```
Divvy S3 archives  ──▶  ingest.py  ──▶  raw.trips        (1.86M rows, landed verbatim)
                                            │
                                            ▼
                                       stg_trips          (dedup + validity filter)
                                            │
                                            ▼
                                     fct_hourly_rides     (2,184 hourly buckets)
                                       │            │
                                       ▼            ▼
                          forecast_hourly_demand   station_daily_trends
                              (168 forecast rows)
```

**Ingestion** (`ingest/ingest.py`) pulls monthly archives and lands them
unmodified. A watermark table records which months have arrived, so re-running is
free and idempotent — the same reason the production pipeline this is modelled on
upserts on a natural key instead of blind-inserting. `make ingest` twice in a row
downloads nothing the second time.

**Transformation** is all dbt. Staging does cleanup only; every business decision
lives in the marts, documented inline with the reasoning rather than just the
mechanics.

**The forecast** buckets history into (day-of-week × hour-of-day) cells, averages
each cell across a trailing 8-week window, and projects that mean forward with a
±1σ band.

### Why a seasonal baseline and not a trend model

Bike-share demand is dominated by weekly seasonality, not by trend. A fitted
trend line over this window chases weather noise — a warm week reads as growth —
and then misses the structure that actually predicts tomorrow: what this hour of
this weekday normally looks like. A seasonal mean is the honest model for a
7-day horizon.

The 8-week lookback is a deliberate tradeoff: long enough that each of the 168
cells has ~8 observations, short enough that a service change six months ago
doesn't bias the mean. Both knobs are configurable:

```bash
dbt run --vars '{lookback_weeks: 12, horizon_days: 14}'
```

### Every estimate ships with its own support

`confidence` is observed cells ÷ lookback weeks, capped at 1.0, alongside a raw
`observations` count. A forecast without that is how people end up trusting a
number backed by two data points. Two singular tests enforce the invariants that
matter — the band can never invert, and a forecast day can never be missing hours.

---

## SQL worth reading

The models are written to be read, not just to run:

| Technique | Where | Why there |
|---|---|---|
| `QUALIFY` + `ROW_NUMBER` | `stg_trips` | Dedups repeated `ride_id`s across month boundaries without a self-join |
| `COUNT(*) FILTER (WHERE …)` | `fct_hourly_rides` | Member/casual split in one pass instead of two joined aggregates |
| `STDDEV_SAMP` + `LEAST`/`GREATEST` | `forecast_hourly_demand` | The ±1σ band, clamped so a negative ride count never ships |
| Rolling `AVG … ROWS BETWEEN` | `station_daily_trends` | 7-day trailing mean to smooth daily noise |
| `LAG(rides, 7)` | `station_daily_trends` | Same-weekday comparison — a Mon/Sun delta measures the weekly cycle, not a change |
| `RANK() OVER (PARTITION BY …)` | `station_daily_trends` | Which stations carried the system on a given day |

---

## Running it

```bash
make setup            # venv + pinned deps
make ingest           # download recent months     (MONTHS=6 to change)
make build            # dbt run + dbt test
make preview          # print the peak hour per forecast day
make docs             # dbt lineage graph in a browser
```

Current state on 3 months of data: **4 models, 18 tests, all passing.** Models
build in under a second; the download dominates the runtime.

DuckDB keeps this frictionless, but the SQL is deliberately portable — pointing
`profiles.yml` at Postgres or Snowflake is the only change required.

---

## Limitations

Worth being explicit about what this does not do:

- **No weather.** Precipitation is probably the single largest driver of daily
  variance and it isn't modelled. That's the first thing I'd add, and it would
  cut the band width materially.
- **No holidays.** July 4th falls inside the forecast window above and gets
  treated as an ordinary Saturday, which is wrong.
- **System-wide, not per-station.** Station-level cells get thin fast; that needs
  either hierarchical pooling or a shrinkage estimator, not a plain mean.
- **No backtest.** The band is a ±1σ description of historical spread, not a
  validated 68% coverage claim. Proving coverage means holding out weeks and
  scoring them — the honest next step before anyone should plan staffing on it.

---

## Provenance

Trip data is published by [Divvy](https://divvybikes.com/system-data) under their
public data license. No API key required.

Built by [Miguel Bocard](https://github.com/MIKE4213) — the SQL port of a
forecasting method I run in production.
