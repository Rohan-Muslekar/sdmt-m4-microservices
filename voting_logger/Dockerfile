FROM python:3.9
RUN pip install google-cloud-pubsub redis
# No COPY of a credential file. This project enforces
# constraints/iam.disableServiceAccountKeyCreation, so there is no key to bake
# in. The code globs *.json, finds nothing, and falls back to Application
# Default Credentials, which on GKE is the node pool's service account read
# from the metadata server.
ADD main.py .
CMD ["python","-u", "./main.py"] 