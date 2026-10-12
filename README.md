# Milestone 4: Microservices using Google Pub/Sub Communication

ENGR 5520G / SOFE4630U. Student 101006689.

Microservices that never learn each other's address. They share one Pub/Sub
topic and sort the traffic with subscription filters on message attributes.

Two parts: the lab voting system, and a design part that rebuilds the
Milestone 3 smart meter preprocessing as microservices.

## Layout

```
voting_logger/    logger service: checks Redis for a repeat voter, strips the
                  voter ID, forwards the vote. Dockerfile, logger.yaml
voting_record/    recorder service: writes the vote to PostgreSQL and answers
                  the machine. Dockerfile, recorder.yaml, postgres/
voting_machine/   the local script that generates votes and waits for a result
design/           the design part
  producer.py       the smart meter, publishes Labels.csv with function="filter"
  filterReading/    FilterReading service, drops readings with a null
  convertReading/   ConvertReading service, kPa to psi and C to F
  design.yaml       both deployments
  CreateTable.sql   the BigQuery table the subscription writes into
  Labels.csv        100 readings from 3 meters, 22 of them incomplete
  architecture.png  the design architecture
scripts/
  setup-ms4.sh      provision, deploy, run, tear down. One subcommand per step
  record-demo.sh    shot lists for the two videos
figures/          the lab figures the report cites
build_report.py   renders REPORT.md into a printable report
```

## The design part in one table

One topic named `meter`. The `function` attribute is the only thing routing
anything.

| Stage | Runs on | Subscription filter | Work | Republishes as |
| --- | --- | --- | --- | --- |
| producer.py | local | none | reads the CSV, blank cell becomes null | `function="filter"` |
| FilterReading | GKE x3 | `attributes.function="filter"` | drop readings holding a null | `function="convert"` |
| ConvertReading | GKE x3 | `attributes.function="convert"` | kPa / 6.895 to psi, C * 1.8 + 32 to F | `function="store"` |
| BigQuery subscription | Pub/Sub | `attributes.function="store"` | writes the row, no code | n/a |

100 readings in, 22 dropped by the filter, 78 rows in BigQuery.

Neither design service gets a Kubernetes Service object. They have no inbound
traffic and no data store, so there is nothing to give an address to.

## Running it

```bash
./scripts/setup-ms4.sh                # the full subcommand list
./scripts/setup-ms4.sh selftest       # the transforms, no cloud needed

# setup
./scripts/setup-ms4.sh apis
./scripts/setup-ms4.sh sa             # service account and its roles, no key
./scripts/setup-ms4.sh deps           # local virtualenv + check ADC
./scripts/setup-ms4.sh repo
./scripts/setup-ms4.sh cluster        # runs its nodes AS the service account

# part A
./scripts/setup-ms4.sh topic
./scripts/setup-ms4.sh logger
./scripts/setup-ms4.sh recorder
./scripts/setup-ms4.sh machine        # one per terminal, different machine IDs

# part B
./scripts/setup-ms4.sh design-topic
./scripts/setup-ms4.sh design-build
./scripts/setup-ms4.sh design-deploy
./scripts/setup-ms4.sh design-run
./scripts/setup-ms4.sh design-check

./scripts/setup-ms4.sh reset          # clear the demo data for a retake
./scripts/setup-ms4.sh teardown       # the cluster bills by the minute
```

There is no service account key anywhere. This project enforces
`constraints/iam.disableServiceAccountKeyCreation`, so the cluster runs its
nodes as the `ms4-pubsub` service account and the pods read their credentials
from the GKE metadata server. The two scripts that run on the local machine use
Application Default Credentials from `gcloud auth application-default login`.

## Report

`REPORT.md` is the source. Build it, then print the HTML from Chrome with
Ctrl+P, Background graphics on, and save as `101006689-ms4-report.pdf`.

```bash
python3 build_report.py
```

## Credit

The voting system code in `voting_logger/`, `voting_record/` and
`voting_machine/` comes from
[MohammadYasserZaki/SOFE4630U-MS4](https://github.com/MohammadYasserZaki/SOFE4630U-MS4),
a fork of GeorgeDaoud3. Four things are changed, all forced by this project's
ban on service account keys: the project ID in `voting_machine/main.py` is read
from the environment, `COPY *.json .` is gone from the Dockerfiles, and the
unguarded `glob("*.json")[0]` in the logger and recorder is guarded the way the
voting machine already guarded it. Everything in `design/` and `scripts/` is
original.
