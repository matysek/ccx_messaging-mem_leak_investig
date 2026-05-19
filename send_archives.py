#!/usr/bin/env python
import json
import tarfile
import click
import os
import logging
import requests
import base64
import uuid
import time
from io import BytesIO
from molodec.archive_producer import ArchiveProducer
from molodec.crc import CONTENT_TYPE
from molodec.renderer import Renderer
from molodec.rules import RuleSet
from requests.auth import HTTPBasicAuth
from iqe_jwt import OIDCAuth
from iqe_jwt import TokenSrc

"""
You need to install molodec first

export PIP_INDEX_URL=https://repository.engineering.redhat.com/nexus/repository/insights-qe/simple
pip install -U molodec

upload with: python script.py upload <optionally options>
"""

CLUSTER_ID = "18000000-c53b-4ea9-ae22-ac4415e2cf21"

_REFRESH_TOKEN = os.environ.get("REFRESH_TOKEN", "")  # Set this env var for stage/prod testing

_TOKEN_URL = os.environ.get(
    "TOKEN_URL", "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token"
)

#local variables
LOCAL_INGRESS_UPLOAD = "http://localhost:3000/api/ingress/v1/upload"

#stage variables
_STAGE_PULL_SECRET_URL = os.environ.get(
    "PULL_SECRET_URL", "https://api.stage.openshift.com/api/accounts_mgmt/v1/access_token"
)
STAGE_INGRESS_UPLOAD="https://console.stage.redhat.com/api/ingress/v1/upload"

#prod variables
_PROD_PULL_SECRET_URL = os.environ.get(
    "PULL_SECRET_URL", "https://api.openshift.com/api/accounts_mgmt/v1/access_token"
)
PROD_INGRESS_UPLOAD="https://console.redhat.com/api/ingress/v1/upload"


logger = logging.getLogger(__name__)


def get_random_cluster_id():
    """Generate a random cluster ID in UUID format"""
    return str(uuid.uuid4())


def get_local_identity_header():
    """Create minimal x-rh-identity header for local testing"""
    identity = {
        "identity": {
            "account_number": "123456",
            "org_id": "123456",
            "type": "User",
            "internal": {
                "org_id": "123456"
            }
        }
    }
    return base64.b64encode(json.dumps(identity).encode()).decode()


def setup():
    token_src = TokenSrc("rhsm-api", _TOKEN_URL)
    oidc_auth = OIDCAuth.from_refresh_token(_REFRESH_TOKEN, token_src, scope="offline_access")
    r = requests.post(_STAGE_PULL_SECRET_URL, auth=oidc_auth)
    openshift_com_token = r.json()["auths"]["cloud.openshift.com"]["auth"]

    return openshift_com_token


def upload_ocp_recommendations(with_breaks=False):
    """
    Memory leak test pattern

    Continuous mode (with_breaks=False):
    - 4 hour continuous sending at 0.1s delay
    - ~144,000 archives total
    - Mimics production steady stream

    Burst mode (with_breaks=True):
    - 15 min sending + 5 min break, repeat 3 times
    - ~27,000 archives total
    - Shows if memory releases during idle periods
    """
    DELAY_BETWEEN_ARCHIVES = 0.1  # 0.1 seconds = 10 archives/sec

    if with_breaks:
        # Burst mode with breaks
        BURST_DURATION = 10 * 60  # 15 minutes
        BREAK_DURATION = 1 * 60   # 5 minutes
        NUM_CYCLES = 6

        print(f"\n{'='*60}")
        print(f"BURST MODE: 3 cycles of (15min send + 5min break)")
        print(f"{'='*60}\n")

        for cycle in range(NUM_CYCLES):
            print(f"\n{'='*60}")
            print(f"CYCLE {cycle + 1}/{NUM_CYCLES} - SENDING BURST")
            print(f"{'='*60}\n")

            burst_start = time.time()
            archives_sent = 0

            while (time.time() - burst_start) < BURST_DURATION:
                cluster_id = get_random_cluster_id()
                producer = ArchiveProducer(Renderer(*RuleSet("io").get_default_rules()))
                tario = producer.make_tar_io(cluster_id)

                local_headers = {
                    "x-rh-identity": get_local_identity_header()
                }

                r = requests.post(
                    LOCAL_INGRESS_UPLOAD,
                    files={"file": ("archive", tario.getvalue(), CONTENT_TYPE)},
                    headers=local_headers,
                )

                archives_sent += 1
                elapsed = time.time() - burst_start

                if archives_sent % 100 == 0:
                    print(f"[Cycle {cycle+1}] Sent {archives_sent} archives in {elapsed:.1f}s (Status: {r.status_code})")

                time.sleep(DELAY_BETWEEN_ARCHIVES)

            print(f"\n[Cycle {cycle+1}] Burst complete: {archives_sent} archives sent in 15 minutes")

            if cycle < NUM_CYCLES - 1:
                print(f"\n{'='*60}")
                print(f"BREAK TIME - 5 minutes (watch for memory release!)")
                print(f"{'='*60}\n")
                time.sleep(BREAK_DURATION)

        print(f"\n{'='*60}")
        print(f"TEST COMPLETE - All {NUM_CYCLES} cycles finished")
        print(f"{'='*60}\n")

    else:
        # Continuous mode
        TEST_DURATION = 4 * 60 * 60  # 4 hours (240 minutes)

        print(f"\n{'='*60}")
        print(f"CONTINUOUS MODE: 4 hour steady stream")
        print(f"Delay: {DELAY_BETWEEN_ARCHIVES}s between archives")
        print(f"{'='*60}\n")

        test_start = time.time()
        archives_sent = 0

        while (time.time() - test_start) < TEST_DURATION:
            cluster_id = get_random_cluster_id()
            producer = ArchiveProducer(Renderer(*RuleSet("io").get_default_rules()))
            tario = producer.make_tar_io(cluster_id)

            local_headers = {
                "x-rh-identity": get_local_identity_header()
            }

            r = requests.post(
                LOCAL_INGRESS_UPLOAD,
                files={"file": ("archive", tario.getvalue(), CONTENT_TYPE)},
                headers=local_headers,
            )

            archives_sent += 1
            elapsed = time.time() - test_start
            elapsed_min = elapsed / 60

            # Print every 100 archives
            if archives_sent % 100 == 0:
                print(f"[{elapsed_min:.1f}min] Sent {archives_sent} archives (Status: {r.status_code})")

            time.sleep(DELAY_BETWEEN_ARCHIVES)

        print(f"\n{'='*60}")
        print(f"TEST COMPLETE - {archives_sent} archives sent in 4 hours")
        print(f"{'='*60}\n")


def upload_ols(content_type):
    # openshift_com_token = setup()  # Uncomment for stage/prod testing

    cluster_id = get_random_cluster_id()

    # For local testing - minimal identity header
    local_headers = {
        "x-rh-identity": get_local_identity_header()
    }

    # headers = {  # Uncomment for stage/prod testing
    #     "Authorization": f"Bearer {openshift_com_token}",
    #     "User-Agent": f"insights-operator/360ca33afd09b4aa0796a79350234c6a68d9ee9e cluster/{cluster_id}",
    # }

    tario = BytesIO()
    tar = tarfile.open(fileobj=tario, mode="w:gz")

    try:
        tar_info = tarfile.TarInfo("openshift_lightspeed.json")
        tar_info.size = 0
        tar.addfile(tar_info)

        content = bytes(cluster_id, "utf-8")
        tar_info.size = len(content)
        tar.addfile(tar_info, fileobj=BytesIO(content))

    except:
        raise
    finally:
        tar.close()

    r = requests.post(
        LOCAL_INGRESS_UPLOAD,  # Change to STAGE_INGRESS_UPLOAD for stage/prod
        files={"file": ("archive", tario.getvalue(), content_type)},
        headers=local_headers,  # Use local_headers for local testing, change to headers for stage/prod
    )

    print(f"Status Code: {r.status_code}")
    print(f"Response Content: {r.text}")
    print("cluster id:", cluster_id)
    print("sent to:", content_type)

@click.group(context_settings={"help_option_names": ["-h", "--help"]})
def cli():
    pass


@cli.command("upload")
@click.option("--ols", default=False, is_flag=True, help="Upload OLS archives")
@click.option("--olscopy", default=False, is_flag=True, help="Upload OLS copy archives")
@click.option("--breaks", default=False, is_flag=True, help="Use burst mode with 5-min breaks (default: continuous)")

def _upload(ols, olscopy, breaks):
    if ols:
        upload_ols(content_type=CONTENT_TYPE)
    elif olscopy:
        upload_ols(content_type="application/vnd.redhat.ols.periodic+tar")
    else:
        upload_ocp_recommendations(with_breaks=breaks)


if __name__ == "__main__":
    cli()
