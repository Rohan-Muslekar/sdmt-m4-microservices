# The smart meter.
#
# Publishes every reading in design/Labels.csv to the single topic with the
# attribute function="filter", which is the only thing that makes FilterReading
# pick it up. Runs on the local machine, exactly like the voting machine in the
# lab part.
#
#   pip install google-cloud-pubsub
#   python design/producer.py              # needs the cloud
#   python design/producer.py --selftest   # pure logic, no cloud, no libraries

import csv
import glob
import json
import os
import sys

# Columns that carry a number. A blank cell means the meter did not report that
# measurement, so it is published as JSON null and FilterReading drops the row.
NUMERIC_FIELDS = ["time", "temperature", "humidity", "pressure"]


def to_record(row):
    record = dict(row)
    for field in NUMERIC_FIELDS:
        record[field] = float(record[field]) if record[field] else None
    return record


def selftest():
    complete = to_record({"time": "1768708698.5", "profileName": "denver",
                          "temperature": "31.1", "humidity": "37.5",
                          "pressure": "1.35"})
    assert complete["temperature"] == 31.1, "numbers are parsed as floats"
    assert complete["profileName"] == "denver", "text columns stay text"

    blank = to_record({"time": "1768708698.5", "profileName": "denver",
                       "temperature": "", "humidity": "37.5",
                       "pressure": "1.35"})
    assert blank["temperature"] is None, "a blank cell becomes None"
    assert json.loads(json.dumps(blank))["temperature"] is None, \
        "None survives the round trip through JSON as null"

    print("producer selftest passed")


def run():
    from google.cloud import pubsub_v1

    # Use the service account key in the current folder when there is one,
    # otherwise fall back to application default credentials.
    files = glob.glob("*.json")
    if files:
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = files[0]

    project_id = os.environ.get("GCP_PROJECT", "project-177cbd41-037f-441e-80d")
    topic_name = os.environ.get("TOPIC_NAME", "meter")
    csv_file = os.environ.get("CSV_FILE", "design/Labels.csv")

    # No ordering key. The two services run three replicas each, so the order
    # readings reach BigQuery is not preserved anyway, and every reading is
    # independent of the ones around it.
    publisher = pubsub_v1.PublisherClient()
    topic_path = publisher.topic_path(project_id, topic_name)
    print("Publishing the records of {} to {}.".format(csv_file, topic_path))

    published = 0
    incomplete = 0
    with open(csv_file, newline="") as f:
        for row in csv.DictReader(f):
            record = to_record(row)
            if any(record[field] is None for field in NUMERIC_FIELDS):
                incomplete += 1
            try:
                future = publisher.publish(
                    topic_path,
                    json.dumps(record).encode("utf-8"),
                    function="filter")
                future.result()
                published += 1
                print("The record {} has been published successfully".format(
                    record))
            except Exception as error:
                print("Failed to publish the record: {}".format(error))

    print("{} records published to {}, {} of them incomplete.".format(
        published, topic_name, incomplete))
    print("FilterReading should drop those {} and pass {} on to "
          "ConvertReading.".format(incomplete, published - incomplete))


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        run()
