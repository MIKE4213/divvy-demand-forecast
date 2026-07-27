{{ config(materialized='table') }}

-- Per-station daily ridership with the three window functions an analyst
-- actually reaches for: a trailing mean to smooth noise, a same-weekday
-- comparison to control for seasonality, and a daily rank to answer "which
-- stations carried the system today".
--
-- Comparing to the same weekday last week rather than to yesterday is the
-- point -- a Monday/Sunday comparison is dominated by the weekly cycle, not
-- by anything that changed.

with daily as (

    select
        start_station_name  as station,
        started_at::date    as ride_date,
        count(*)            as rides
    from {{ ref('stg_trips') }}
    where start_station_name is not null
    group by 1, 2

),

windowed as (

    select
        station,
        ride_date,
        rides,

        avg(rides) over (
            partition by station
            order by ride_date
            rows between 6 preceding and current row
        ) as rides_7d_avg,

        lag(rides, 7) over (
            partition by station
            order by ride_date
        ) as rides_same_day_last_week,

        rank() over (
            partition by ride_date
            order by rides desc
        ) as busiest_rank

    from daily

)

select
    station,
    ride_date,
    rides,
    round(rides_7d_avg, 1)   as rides_7d_avg,
    rides_same_day_last_week,
    case
        when rides_same_day_last_week is null then null
        when rides_same_day_last_week = 0     then null
        else round(100.0 * (rides - rides_same_day_last_week)
                   / rides_same_day_last_week, 1)
    end as wow_pct_change,
    busiest_rank
from windowed
order by ride_date desc, busiest_rank
