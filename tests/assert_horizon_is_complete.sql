-- Every forecast date should carry a full 24-hour profile. A short day means
-- a (weekday, hour) cell was missing from history entirely -- worth failing
-- loudly rather than silently serving a gap.

select
    forecast_date,
    count(*) as hours_present
from {{ ref('forecast_hourly_demand') }}
group by forecast_date
having count(*) <> 24
