{{ config(materialized='table') }}

-- Seasonal-baseline demand forecast.
--
-- This is the same method I built in production for call-arrival forecasting,
-- ported from MongoDB's aggregation framework to SQL: bucket history into
-- (day-of-week x hour-of-day) cells, average each cell across a trailing
-- lookback window, and project that mean forward with a +/-1 sigma band.
--
-- Deliberately NOT a trend extrapolation. Bike-share demand is dominated by
-- weekly seasonality -- the weekday commute double-peak against the weekend
-- midday hump -- so a seasonal mean beats a fitted trend at a 7-day horizon.
-- A trend model would chase weather noise and miss the structure that matters.
--
-- Every estimate carries `observations` and `confidence` so a consumer can
-- distinguish a well-supported cell from one backed by two data points. Shipping
-- a forecast without that is how people trust a number they shouldn't.
--
-- Tunable at run time:
--   dbt run --vars '{lookback_weeks: 12, horizon_days: 14}'

{% set lookback_weeks = var('lookback_weeks', 8) %}
{% set horizon_days   = var('horizon_days', 7) %}

with bounds as (

    select
        max(ride_hour)                                                as latest_hour,
        max(ride_hour) - interval '{{ lookback_weeks }} weeks'         as window_start
    from {{ ref('fct_hourly_rides') }}

),

-- Restrict history to the trailing lookback window. Older data biases the mean
-- toward a service pattern that may no longer hold.
observed as (

    select
        h.day_of_week,
        h.hour_of_day,
        h.rides
    from {{ ref('fct_hourly_rides') }} h
    cross join bounds b
    where h.ride_hour > b.window_start

),

-- One row per (weekday, hour) cell -- the seasonal baseline itself.
cells as (

    select
        day_of_week,
        hour_of_day,
        avg(rides)                       as mean_rides,
        coalesce(stddev_samp(rides), 0)  as sigma,
        count(*)                         as observations
    from observed
    group by day_of_week, hour_of_day

),

-- A cell is fully supported when we observed it once per week across the
-- window. Fewer observations than weeks means gaps in the source data.
scored as (

    select
        *,
        least(observations::double / {{ lookback_weeks }}, 1.0) as confidence
    from cells

),

-- The forward calendar we project onto.
horizon as (

    -- range() yields BIGINT; DuckDB's date arithmetic wants INTEGER.
    select (b.latest_hour::date + d.day_offset::integer)::date as forecast_date
    from bounds b
    cross join range(1, {{ horizon_days }} + 1) as d(day_offset)

)

select
    h.forecast_date,
    dayofweek(h.forecast_date)                       as day_of_week,
    s.hour_of_day,
    round(s.mean_rides, 1)                           as expected_rides,
    greatest(round(s.mean_rides - s.sigma, 1), 0)    as lower_bound,
    round(s.mean_rides + s.sigma, 1)                 as upper_bound,
    s.observations,
    round(s.confidence, 2)                           as confidence
from horizon h
inner join scored s
    on dayofweek(h.forecast_date) = s.day_of_week
order by h.forecast_date, s.hour_of_day
