# FilterReading microservice.
#
# Stage 1 of the smart meter preprocessing pipeline. Subscribes to the single
# topic with the filter attributes.function="filter", drops any reading that is
# missing a measurement, and republishes the survivors with the attribute
# function="convert" so the ConvertReading service picks them up.
#
# Nothing in here knows where ConvertReading runs. The only shared knowledge is
# the topic name and the attribute vocabulary.
#
#   pip install google-cloud-pubsub
#   python filterReading.py             # needs the cloud
#   python filterReading.py --selftest  # pure logic, no cloud, no libraries

import glob
import json
import os
import sys

# The measurements a complete reading must carry. profileName and time are
# always present; a blank cell in the CSV becomes JSON null for these three.
MEASUREMENTS = ["temperature", "humidity", "pressure"]


def is_complete(record):
    """True when the meter reported every measurement.

    A blank cell in Labels.csv is published as JSON null, so a missing
    measurement arrives as None. Those records are dropped here.
    """
    return all(record.get(field) is not None for field in MEASUREMENTS)


def selftest():
    complete = {"time": 1768708698.5, "profileName": "denver",
                "temperature": 31.1, "humidity": 37.5, "pressure": 1.35}
    assert is_complete(complete), "a complete reading must survive the filter"

    for field in MEASUREMENTS:
        incomplete = dict(complete, **{field: None})
        assert not is_complete(incomplete), \
            "a reading missing {} must be dropped".format(field)

    # A missing key is as bad as an explicit null.
    assert not is_complete({"profileName": "denver"}), \
        "a reading with no measurements at all must be dropped"

    print("filterReading selftest passed")


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
    subscription_id = os.environ.get("SUB_ID", "meter-filter-sub")
    debug = "DEBUG" in os.environ

    if debug:
        print("key={} project={} topic={} subscription={}".format(
            files[0] if files else "(application default)",
            project_id, topic_name, subscription_id))

    publisher = pubsub_v1.PublisherClient()
    topic_path = publisher.topic_path(project_id, topic_name)

    dropped = 0
    passed = 0

    def callback(message: pubsub_v1.subscriber.message.Message) -> None:
        nonlocal dropped, passed
        record = json.loads(message.data)

        if is_complete(record):
            passed += 1
            publisher.publish(topic_path,
                              json.dumps(record).encode("utf-8"),
                              function="convert")
            print("passed  {}".format(record))
        else:
            dropped += 1
            print("dropped {}".format(record))

        if debug:
            print("totals: {} passed, {} dropped".format(passed, dropped))

        # Acknowledge either way. A dropped reading was handled successfully,
        # so letting Pub/Sub redeliver it would just repeat the drop.
        message.ack()

    subscriber = pubsub_v1.SubscriberClient()
    subscription_path = subscriber.subscription_path(project_id, subscription_id)
    sub_filter = 'attributes.function="filter"'

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
            print("\nStopped. {} passed, {} dropped.".format(passed, dropped))


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        run()
