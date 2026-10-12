-- The table the BigQuery subscription writes into.
--
-- The subscription is created with --use-table-schema, so Pub/Sub matches the
-- JSON keys of the message against these column names and writes the row with
-- no consumer code in between. The column names therefore have to match the
-- keys ConvertReading publishes, exactly.
--
-- Every column is NULLABLE even though FilterReading guarantees that no null
-- reaches this far. A REQUIRED column would make Pub/Sub fail the write and
-- retry forever if one ever did slip through, which is a worse failure than
-- storing a null and seeing it in the table.
--
--   bq query --use_legacy_sql=false < design/CreateTable.sql

CREATE SCHEMA IF NOT EXISTS SmartMeter
OPTIONS (location = 'northamerica-northeast2');

CREATE TABLE IF NOT EXISTS SmartMeter.Readings (
  time        FLOAT64,   -- epoch seconds, as published by the meter
  profileName STRING,    -- the meter that reported the reading
  temperature FLOAT64,   -- Fahrenheit after ConvertReading
  humidity    FLOAT64,   -- percent, passed through untouched
  pressure    FLOAT64    -- psi after ConvertReading
);
