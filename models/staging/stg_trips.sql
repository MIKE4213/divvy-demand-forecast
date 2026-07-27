{{ config(materialized='view') }}

-- Light cleanup only -- casting, trimming, and dropping rows that can't be
-- reasoned about. All business logic lives downstream in the marts, so this
-- layer stays cheap to rebuild and easy to reason about.

with source as (

    select * from {{ source('raw', 'trips') }}

),

cleaned as (

    select
        ride_id,
        rideable_type,
        started_at,
        ended_at,
        nullif(trim(start_station_name), '')       as start_station_name,
        member_casual,
        date_diff('minute', started_at, ended_at)  as duration_minutes
    from source
    where started_at is not null
      and ended_at   is not null
      and ended_at > started_at            -- a handful of archive rows invert these
      and date_diff('minute', started_at, ended_at) < 60 * 24  -- drop unreturned bikes

)

select *
from cleaned
-- Divvy's monthly archives repeat a small number of ride_ids across month
-- boundaries. QUALIFY keeps the first occurrence of each without a self-join.
qualify row_number() over (partition by ride_id order by started_at) = 1
