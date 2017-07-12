# Copyright 2016 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You may not use this file
# except in compliance with the License. A copy of the License is located at
#
#     http://aws.amazon.com/apache2.0/
#
# or in the "license" file accompanying this file. This file is distributed on an "AS IS"
# BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations under the License.
"""
Remove a node from Chef server when a termination event is received
joshcb@amazon.com
v1.2.0
"""
from __future__ import print_function
import logging
from base64 import b64decode
from botocore.exceptions import ClientError
import boto3
import chef
from chef.exceptions import ChefServerNotFoundError
import requests
from requests.packages.urllib3.exceptions import InsecureRequestWarning


import local_config

LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)
REGION= local_config.REGION
CHEF_SERVER_URL = local_config.CHEF_SERVER_URL
USERNAME = local_config.USERNAME
VERIFY_SSL = local_config.VERIFY_SSL
DEBUG = local_config.DEBUG

def log_event(event):
    """Logs event information for debugging"""
    LOGGER.info("====================================================")
    LOGGER.info(event)
    LOGGER.info("====================================================")

def get_instance_id(event):
    """Parses InstanceID from the event dict and gets the FQDN from EC2 API"""
    try:
        return event['detail']['instance-id']
    except KeyError as err:
        LOGGER.error(err)
        return False

def get_pem():
    """Decrypt the Ciphertext Blob to get USERNAME's pem file"""
    try:
        with open('encrypted_pem.txt', 'r') as encrypted_pem:
            pem_file = encrypted_pem.read()

        kms = boto3.client('kms', region_name=REGION)
        return kms.decrypt(CiphertextBlob=b64decode(pem_file))['Plaintext']
    except (IOError, ClientError, KeyError) as err:
        LOGGER.error(err)
        return False

def handle(event, _context):
    """Lambda Handler"""
    log_event(event)

    #Suppress InsecureRequestWarning: Unverified HTTPS request is being made in Python2.6
    requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

    # If you're using a self signed certificate change
    # the ssl_verify argument to False
    with chef.ChefAPI(CHEF_SERVER_URL, get_pem(), USERNAME, ssl_verify=VERIFY_SSL):
        instance_id = get_instance_id(event)
        try:
            search = chef.Search('node', 'ec2_instance_id:' + instance_id)
        except ChefServerNotFoundError as err:
            LOGGER.error(err)
            return False

        if len(search) != 0:
            for instance in search:
                node = chef.Node(instance.object.name)
                client = chef.Client(instance.object.name)
                try:
                    LOGGER.info('About to delete the node named - ' + node.name)
                    LOGGER.info('About to delete the client named - ' + client.name)
                    if not DEBUG:
                      node.delete()
                      LOGGER.info('===Node Delete: SUCCESS===')
                      client.delete()
                      LOGGER.info('===Client Delete: SUCCESS===')
                    else:
                      LOGGER.info('Would have deleted the node named - ' + node.name + ' here, but we are in DEBUG mode')
                      LOGGER.info('Would have deleted the client named - ' + client.name + ' here, but we are in DEBUG mode')
                    return True
                except ChefServerNotFoundError as err:
                    LOGGER.error(err)
                    return False
        else:
            LOGGER.info('=Instance does not appear to be Chef Server managed.=')
            return True
