"""
run from inside a pod with:

source srv/current/sw.dmapelli/slc7_amd64_gcc
630/cms/crabserver/v3.220513-9c521bb3b3f04d3c957a070b463070c6/etc/profile.d/init.sh
export CRYPTOGRAPHY_ALLOW_OPENSSL_102=True
python3 TestBotoClient.py

"""

import os
import logging
import pprint
import sys
import ast
import importlib

logging.basicConfig(stream=sys.stdout, level=logging.INFO)
logger = logging.getLogger('Logger')

# import s3 credentials

secrets_file = "/data/srv/current/auth/crabserver/CRABServerAuth.py"

secrets_spec = importlib.util.spec_from_file_location("secrets", secrets_file)
secrets_module = importlib.util.module_from_spec(secrets_spec)
sys.modules[secrets_spec.name] = secrets_module
secrets_spec.loader.exec_module(secrets_module)

print("imported credentials: key", secrets_module.s3['access_key'][:5], "...")

import time

class MeasureTime:
    def __init__(self, logger, metadata):
        self.logger = logger
        self.metadata = metadata

    def __enter__(self):
        self.perf_counter = time.perf_counter()
        self.process_time = time.process_time()
        return self

    def __exit__(self, type, value, traceback):
        self.process_time = time.process_time() - self.process_time
        self.perf_counter = time.perf_counter() - self.perf_counter
        self.readout = 'tot: {:.4f} , proc: {:.4f}'.format(self.perf_counter, self.process_time )
        self.logger.info("DM debug - catchtime (seconds) - %s. %s", self.metadata, self.readout)

# connect to s3


with MeasureTime(logger, "{}.importboto3".format(__name__)) as t:
    from botocore.client import Config
    from botocore.exceptions import ClientError
    import boto3

endpoint = 'https://s3.cern.ch'
with MeasureTime(logger, "{}.botoclient".format(__name__)) as t:
    config = Config(connect_timeout=5, retries={'max_attempts':2})
    s3_client = boto3.client('s3', endpoint_url=endpoint, aws_access_key_id=secrets_module.s3['access_key'], aws_secret_access_key=secrets_module.s3['secret_key'], config=config)

def check_s3():
    response = s3_client.get_bucket_lifecycle_configuration(Bucket='crabcache_dev')
    # pprint.pprint(response)

def findfile():
    try:
        # response = s3_client.head_object(Bucket='crabcache_dev', Key='dmapelli/testfile.1')
        response = s3_client.head_object(Bucket='crabcache_prod', Key='dmapelli/sandboxes/a3aa1a7ca560e14704168a4d8407cad66d38830209e320d327c11ab8569545f3.tar.gz')
        return True
    except ClientError as ex:
        #print(str(ex))
        #print (ex)
        #print('Not found')
        return False

#for _ in range(2):
#    with MeasureTime(logger, "{}.get_bucket_config".format(__name__)) as t:
#        check_s3()
#print("last: ", t.process_time)

for _ in range(2):
    with MeasureTime(logger, "{}.findfile".format(__name__)) as t:
        findfile()
print("last: ", t.process_time)