-- A prediction interval whose lower bound exceeds its expected value is
-- arithmetically impossible, so this test should never return rows. Cheap
-- guard against a future refactor inverting the sigma arithmetic.

select
    forecast_date,
    hour_of_day,
    lower_bound,
    expected_rides,
    upper_bound
from {{ ref('forecast_hourly_demand') }}
where lower_bound > expected_rides
   or expected_rides > upper_bound
