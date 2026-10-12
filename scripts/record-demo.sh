#!/usr/bin/env bash
# record-demo.sh - shot lists for the two Milestone 4 videos. Prints the steps
# to narrate; it records nothing itself. Use your screen recorder (OBS, Loom)
# and read each beat aloud.
#
#   ./scripts/record-demo.sh voting   # video 1 (~3 min): the voting system
#   ./scripts/record-demo.sh design   # video 2 (~5 min): the design part
#
# Have this ready before you hit record:
#   - cluster up, logger and recorder deployed, pods Running
#   - two terminals side by side for the two voting machines
#   - the Pub/Sub subscriptions page open in a browser tab
#   - for video 2, the BigQuery table open in another tab

set -euo pipefail

case "${1:-}" in
voting)
  cat <<'EOF'
VIDEO 1  (~3 minutes)  The voting system, with audio
------------------------------------------------------------
0:00  Intro. Name, student ID, "Milestone 4, microservices over Google Pub/Sub."
      One sentence on the point: no service knows any other service's address.

0:20  Architecture. Show figures/arch.jpg. Name the four pieces: voting machine
      on the laptop, logger service, recorder service, one Pub/Sub topic called
      election carrying all of it.

0:40  The filters. Open the Pub/Sub subscriptions page. Show the three
      subscriptions and read their filters out loud:
        election-submit-sub    attributes.function="submit vote"
        election-record-sub    attributes.function="record vote"
        election-result-1-sub  attributes.function="result" AND machineID="1"
      Say the key line: every message goes to the same topic, the filter is the
      only thing deciding who gets it.

1:10  The pods. kubectl get pods. Point out logger x3, recorder x3, redis x1,
      postgres x1. Say why Redis and PostgreSQL are single replica: they hold
      state, the services do not.

1:30  Logger logs. kubectl logs -l app=logger --tail 20. Show it connected to
      Redis and listening on its filtered subscription.

1:45  Run machine 1. ./scripts/setup-ms4.sh machine, election ID 2026,
      machine ID 1. Show a vote going out and "successful" coming back.

2:10  Run machine 2 in the second terminal, same election ID 2026, machine ID 2.
      Both running at once. Point out that each machine only ever sees its own
      results, because machineID is in its filter.

2:30  Already voted. Let it run until a repeated voter ID appears and
      "Already Voted!!!" comes back. Say that is Redis, not PostgreSQL, and
      that the voter ID never reaches the recorder, for voting privacy.

2:45  The data. ./scripts/setup-ms4.sh votes. Show the rows in PostgreSQL:
      electionID, machineID, voting, and no voter ID column anywhere.

3:00  Wrap up. Three filters, one topic, no addresses.
EOF
  ;;

design)
  cat <<'EOF'
VIDEO 2  (~5 minutes)  The design part, with audio
------------------------------------------------------------
0:00  Intro. "Milestone 4 design: the same smart meter preprocessing I built as
      a Dataflow job in Milestone 3, rebuilt as microservices."

0:20  The job. 100 readings from three meters. Drop anything with a missing
      measurement, convert kPa to psi and Celsius to Fahrenheit, store the
      result. Show a couple of rows of design/Labels.csv including a blank cell.

0:45  Architecture. Show figures/design.jpg, then design/architecture.png.
      One topic named meter, three attribute values, two services, and a
      BigQuery subscription at the end that is not code at all.

1:15  FilterReading. Open design/filterReading/filterReading.py. Show
      is_complete, the filter string attributes.function="filter", and the
      republish with function="convert". 40 lines of actual work.

1:45  ConvertReading. Open design/convertReading/convertReading.py. Show the two
      conversions and the republish with function="store". Mention the self
      tests: 68.95 kPa is 10 psi, 100 C is 212 F.

2:05  Run them. ./scripts/setup-ms4.sh selftest. Three passes, no cloud needed.

2:20  Deployed. kubectl get pods, point at filter-reading x3 and
      convert-reading x3. Say what is missing on purpose: no Kubernetes Service
      for either one. They have no inbound traffic and no data store, so there
      is nothing to give an address to.

2:45  The subscriptions. Pub/Sub page, show meter-filter-sub,
      meter-convert-sub and meter-store-bq-sub with their three filters, and
      that the last one has a BigQuery table set rather than a subscriber.

3:10  Run the meter. ./scripts/setup-ms4.sh design-run. 100 records publish.
      The script prints how many were incomplete: 22 of them.

3:35  Watch the drop. kubectl logs -l app=filter-reading --tail 30. Show both
      "passed" and "dropped" lines. Read one dropped record out and point at
      its null.

4:00  Watch the convert. kubectl logs -l app=convert-reading --tail 20. Show a
      before and after pair: pressure in kPa becoming psi, Celsius becoming
      Fahrenheit.

4:20  BigQuery. Refresh the SmartMeter.Readings table. 78 rows, which is 100
      minus the 22 incomplete. Show the preview: Fahrenheit and psi, no nulls.
      Say the punchline: nothing subscribed to that data, Pub/Sub wrote it.

4:45  ./scripts/setup-ms4.sh design-check to show the count and the last rows.

5:00  Wrap up. One topic, three attribute values, two containers, zero sink code.
EOF
  ;;

*)
  echo "usage: $0 {voting|design}"
  ;;
esac
