# ConvertReading microservice.
#
# Stage 2 of the smart meter preprocessing pipeline. Subscribes to the single
# topic with the filter attributes.function="convert", converts the pressure
# from kPa to psi and the temperature from Celsius to Fahrenheit, then
# republishes with the attribute function="store".
#
# Nothing consumes function="store" in code. A BigQuery subscription carrying
# that filter writes the row straight into the table.
#
#   pip install google-cloud-pubsub
#   python convertReading.py             # needs the cloud
#   python convertReading.py --selftest  # pure logic, no cloud, no libraries

import glob
import json
import os
import sys

# P(psi) = P(kPa) / 6.895
KPA_PER_PSI = 6.895


def to_psi(kpa):
    return kpa / KPA_PER_PSI


def to_fahrenheit(celsius):
    # T(F) = T(C) * 1.8 + 32
    return celsius * 1.8 + 32


def convert(record):
    """Return a copy of the reading in psi and Fahrenheit.

    The keys are unchanged, so the record keeps the same shape all the way to
    the BigQuery table. Only the units change.
    """
    converted = dict(record)
    converted["pressure"] = to_psi(record["pressure"])
    converted["temperature"] = to_fahrenheit(record["temperature"])
    return converted


def selftest():
    assert abs(to_psi(68.95) - 10.0) < 1e-9, "68.95 kPa is 10 psi"
    assert abs(to_fahrenheit(100.0) - 212.0) < 1e-9, "100 C is 212 F"
    assert abs(to_fahrenheit(0.0) - 32.0) < 1e-9, "0 C is 32 F"
    assert abs(to_fahrenheit(-40.0) - (-40.0)) < 1e-9, "-40 C is -40 F"

    reading = {"time": 1768708698.5, "profileName": "denver",
               "temperature": 100.0, "humidity": 37.5, "pressure": 68.95}
    out = convert(reading)
    assert abs(out["pressure"] - 10.0) < 1e-9
    assert abs(out["temperature"] - 212.0) < 1e-9
    assert out["humidity"] == 37.5, "humidity is passed through untouched"
    assert out["profileName"] == "denver", "the key fields are untouched"
    assert reading["pressure"] == 68.95, "the input record is not mutated"
    assert sorted(out) == sorted(reading), "the record shape does not change"

    print("convertReading selftest passed")


def run():
    from google.cloud import pubsub_v1

    # Search the current directory for the JSON file holding the Pub/Sub
    # credentials. Falls back to application default credentials when the
    # service runs somewhere a key file was not copied to.
    files = glob.glob("*.json")
    if files:
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = files[0]

    project_id = os.environ["GCP_PROJECT"]
    topic_name = os.environ.get("TOPIC_NAME", "meter")
    subscription_id = os.environ.get("SUB_ID", "meter-convert-sub")
    debug = "DEBUG" in os.environ

    if debug:
        print("key={} project={} topic={} subscription={}".format(
            files[0] if files else "(application default)",
            project_id, topic_name, subscription_id))

    publisher = pubsub_v1.PublisherClient()
    topic_path = publisher.topic_path(project_id, topic_name)

    converted_count = 0

    def callback(message: pubsub_v1.subscriber.message.Message) -> None:
        nonlocal converted_count
        record = json.loads(message.data)

        try:
            converted = convert(record)
        except (KeyError, TypeError) as error:
            # FilterReading should have removed these already. If one slips
            # through, drop it loudly rather than crashing the replica.
            print("cannot convert {} ({}). Dropped.".format(record, error))
            message.ack()
            return

        converted_count += 1
        publisher.publish(topic_path,
                          json.dumps(converted).encode("utf-8"),
                          function="store")
        print("converted {} -> {}".format(record, converted))

        if debug:
            print("total converted: {}".format(converted_count))

        message.ack()

    subscriber = pubsub_v1.SubscriberClient()
    subscription_path = subscriber.subscription_path(project_id, subscription_id)
    sub_filter = 'attributes.function="convert"'

    print("Listening for messages on {}..\n".format(subscription_path))

    with subscriber:
        # Create the filtered subscription the first time the service starts.
        # Every later replica finds it already there, which is not an error.
        try:
            subscriber.create_subscription(
                request={"name": subscription_path, "topic": topic_path,
                         "filter": sub_filter})
            print("Created subscription {} with filter {}".format(
                subscription_id, sub_filter))
        except Exception as error:
            # Printing the reason matters. A bare except would hide a malformed
            # filter string exactly as quietly as it hides already-exists.
            print("Subscription not created ({}). Assuming it exists.".format(
                type(error).__name__))

        streaming_pull_future = subscriber.subscribe(subscription_path,
                                                     callback=callback)
        try:
            streaming_pull_future.result()
        except KeyboardInterrupt:
            streaming_pull_future.cancel()
            print("\nStopped after converting {} readings.".format(
                converted_count))


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        run()
