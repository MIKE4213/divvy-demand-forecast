{{ config(materialized='table') }}

-- One row per hour of the calendar: the grain everything else forecasts on.
-- Bucketing to the hour is what makes weekly seasonality legible -- Divvy
-- demand is a commute signal, so it lives in the (weekday, hour) interaction
-- rather than in the daily total.

with hourly as (

    select
        date_trunc('hour', started_at)                    as ride_hour,
        count(*)                                          as rides,
        count(*) filter (where member_casual = 'member')  as member_rides,
        count(*) filter (where member_casual = 'casual')  as casual_rides,
        round(avg(duration_minutes), 2)                   as avg_duration_minutes
    from {{ ref('stg_trips') }}
    group by 1

)

select
    ride_hour,
    ride_hour::date       as ride_date,
    dayofweek(ride_hour)  as day_of_week,   -- 0 = Sunday
    hour(ride_hour)       as hour_of_day,
    rides,
    member_rides,
    casual_rides,
    avg_duration_minutes
from hourly
