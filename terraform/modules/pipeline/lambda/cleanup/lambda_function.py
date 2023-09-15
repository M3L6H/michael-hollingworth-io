import logging
import json
import boto3
from datetime import datetime
from botocore.exceptions import ClientError

def lambda_handler(event, context):
  # Set up logging
  logging.getLogger().setLevel(logging.INFO)
  logging.info("Logging configured")

  # List of bucket entries
  # Each bucket entry has the following structure:
  # { bucket: "my-bucket", prefixes: ["", "abc/", ...] }
  bucketEntries = event["bucketEntries"]
  logging.info(f"Received {len(bucketEntries)} bucket entries...")

  # How old an object should be before it is considered eligible for deletion
  minAge = event["minAge"]

  # How many objects should be retained as a backup
  backup_count = event["backupCount"]

  s3 = boto3.client("s3")

  for bucketEntry in bucketEntries:
    bucket = bucketEntry["bucket"]
    logging.info(f"Checking bucket: {bucket}...")

    for prefix in bucketEntry["prefixes"]:
      objects = list_bucket_objects(bucket, prefix)
      logging.info(f"Checking prefix: {prefix}...")

      if objects is not None:
        logging.info(f"Found {len(objects)} objects in {bucket}/{prefix}")

        objects.sort(key=lambda o: o["LastModified"])

        for o in filter(lambda o: (datetime.now() - o["LastModified"]).days > minAge, objects[backup_count:]):
          try:
            logging.info(f"Deleting {o['Key']}")
            s3.delete_object(Bucket=bucket, Key=o["Key"])
          except ClientError as e:
            logging.error(e)
      else:
        logging.info(f"Did not find any objects in {bucket}/{prefix}")

  return True

def list_bucket_objects(bucket_name, prefix):
  # Retrieve the list of bucket objects
  s3 = boto3.client("s3")
  try:
    response = s3.list_objects_v2(Bucket=bucket_name, Prefix=prefix)
  except ClientError as e:
    logging.error(e)
    return None
  return response["Contents"]
