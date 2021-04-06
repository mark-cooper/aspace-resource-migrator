# ASpace Resource Migrator

Migrates resource records from one ArchivesSpace repository to another.

## Use cases

This was developed for:

1. Multi-repository ArchivesSpace instances that require independent public interfaces.
2. Aggregating data from multi-instance repositories to a consolidated public interface.

More use cases are welcome!

## Overview

This project provides a [serverless](#) function for migrating resources from a `source` to a
`destination` ArchivesSpace repository (typically these would be in separate deployments).

- The source and destination must already exist
- The destination deployment must be using the [aspace-jsonmodel-from-format](#) plugin
- If a record from source is not available in destination it will be imported
- If a record from source is available in destination it is deleted before being imported

The serverless function when deployed to [AWS Lambda](#) has a 15 minute execution timeout.
This is generally fine for standard use, but for initial bootstrapping or where a large
transfer of data is required the function can be run locally without the timeout restriction.

## Pre-reqs

- [Ruby](#) & [Bundler](#)
- [Serverless framework](#)

Install the pre-reqs then download this repo and run:

```bash
npm install
bundle install --standalone
sls package
```

## Running locally

Create the config file: `cp test/example.json test/dev.json` and update it:

```json
{
  "source_url": "https://some.archivesspace.example/api",
  "source_repo_id": 2,
  "source_username": "admin",
  "source_password": "password!",
  "destination_url": "http://localhost:4567",
  "destination_repo_id": 101,
  "destination_username": "admin",
  "destination_password": "admin",
  "recent_only": true,
  "id_generator": "smushed"
}
```

Change the values to match your requirements. The sample configuration pulls resource records
from a remote server to a local development instance of ArchivesSpace.

To run it:

```bash
bundle exec sls invoke local -f migrator -p test/dev.json
```

With suitable configuration this is also a practical way of running a complete repository
migration without the timeout restrictions of Lambda.

## Deployment configuration

Create the deployment file: `cp config/example.yml config/deployment.yml`:

```yml
---
```

For locally triggerring the remote function create an equivalent `test/deployment.json`
using `test/example.json` as a starting point.

## Deploying to AWS Lambda

```bash
AWS_PROFILE=archivesspace MIGRATOR_CONFIG=./config/deployment.yml sls deploy
# to trigger it from your local machine:
AWS_PROFILE=archivesspace sls invoke -f migrator -p test/deployment.json
# view the logs:
AWS_PROFILE=archivesspace sls logs -f migrator
# and to delete:
AWS_PROFILE=archivesspace sls remove
```

## ArchivesSpace permissions

It is highly recommended that the source account only be given read access to records:

- `view_repository`: view the records in this repository

## License

Open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

---
