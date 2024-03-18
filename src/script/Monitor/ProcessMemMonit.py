"""
This program usses python psutil to get information about processes and then
sends the information to opensearch

- [x] retrieve information with psutil
- [ ] send data to opensearch
"""

import psutil
import requests
from requests.auth import HTTPBasicAuth

import datetime
import time
import os
import json
from socket import gethostname
from pprint import pprint

fmt = "%Y-%m-%dT%H:%M:%S%z"
workdir = './'
logdir = './'
logfile = f'GenMonit-{datetime.datetime.now().strftime("%Y%m%d_%H%M%S")}.log'

def readpwd():
    """
    Reads password from disk
    """
    with open(f"/data/certs/monit.d/MONIT-CRAB-test.json", encoding='utf-8') as f:
        credentials = json.load(f)
    return credentials["url"], credentials["username"], credentials["password"]
MONITURL, MONITUSER, MONITPWD = readpwd()

def send(document):
    """
    sends this document to Elastic Search via MONIT
    the document may contain InfluxDB data, but those will be ignored unless the end point
    in MONIT is changed. See main code body for more
    Currently there is no need for using InfluxDB, see discussion in
    https://its.cern.ch/jira/browse/CMSMONIT-72?focusedCommentId=2920389&page=com.atlassian.jira.plugin.system.issuetabpanels%3Acomment-tabpanel#comment-2920389
    :param document:
    :return:
    """
    return requests.post(f"{MONITURL}", 
                        auth=HTTPBasicAuth(MONITUSER, MONITPWD),
                         data=json.dumps(document),
                         headers={"Content-Type": "application/json; charset=UTF-8"},
                         verify=False
                         )

def send_and_check(document, should_fail=False):
    """
    commend the `##PROD` section when developing, not to duplicate the data inside elasticsearch
    """
    ## DEV
    # print(type(document), document)
    # PROD
    response = send(document)
    msg = 'With document: {0}. Status code: {1}. Message: {2}'.format(document, response.status_code, response.text)
    assert ((response.status_code in [200]) != should_fail), \
        msg

def get_size(bytes):
    """
    Returns size of bytes in a nice format
    """
    for unit in ['', 'K', 'M', 'G', 'T', 'P']:
        if bytes < 1024:
            return f"{bytes:.2f}{unit}B"
        bytes /= 1024


def get_processes_info():
    # the list the contain all process dictionaries
    processes = []
    for process in psutil.process_iter():
        # get all process info in one shot
        with process.oneshot():
            # get the process id
            pid = process.pid
            if pid == 0:
                # System Idle Process for Windows NT, useless to see anyways
                continue
            # get the name of the file executed
            name = process.name()
            # get the time the process was spawned
            try:
                create_time = datetime.datetime.fromtimestamp(process.create_time())
            except OSError:
                # system processes, using boot time instead
                create_time = datetime.datetime.fromtimestamp(psutil.boot_time())
            try:
                # get the number of CPU cores that can execute this process
                cores = len(process.cpu_affinity())
            except psutil.AccessDenied:
                cores = 0
            # get the CPU usage percentage
            cpu_usage = process.cpu_percent()
            # get the status of the process (running, idle, etc.)
            status = process.status()
            # print(pid, status) # DM DEBUG
            try:
                # get the process priority (a lower value means a more prioritized process)
                nice = int(process.nice())
            except psutil.AccessDenied:
                nice = 0
            try:
                # get the memory usage in bytes
                memory_usage = process.memory_full_info().uss
            except psutil.AccessDenied:
                memory_usage = 0
            except psutil.ZombieProcess:
                memory_usage = 0
            try:
                # total process read and written bytes
                io_counters = process.io_counters()
                read_bytes = io_counters.read_bytes
                write_bytes = io_counters.write_bytes
            except psutil.AccessDenied:
                read_bytes = 0
                write_bytes = 0
            # get the number of total threads spawned by this process
            n_threads = process.num_threads()
            # get the username of user spawned the process
            try:
                username = process.username()
            except psutil.AccessDenied:
                username = "N/A"
            try:
                cmdline = process.cmdline()
            except psutil.AccessDenied:
                cmdline = "N/A"

        processes.append({
            'producer': MONITUSER, 'type': "scheddproc", 'hostname': gethostname(),
            'pid': pid, 'name': name, 'create_time': str(create_time),
            'cores': cores, 'cpu_usage': cpu_usage, 'status': status, 'nice': nice,
            'memory_usage': memory_usage, 'read_bytes': read_bytes, 'write_bytes': write_bytes,
            'n_threads': n_threads, 'username': username, "cmdline": cmdline,
        })

    return processes


def construct_dataframe(processes):
    df = processes
    # # convert to pandas dataframe
    # df = pd.DataFrame(processes)
    # # set the process id as index of a process
    # df.set_index('pid', inplace=True)
    # # sort rows by the column passed as argument
    # df.sort_values(sort_by, inplace=True, ascending=not descending)
    # # pretty printing bytes
    # df['memory_usage'] = df['memory_usage'].apply(get_size)
    # df['write_bytes'] = df['write_bytes'].apply(get_size)
    # df['read_bytes'] = df['read_bytes'].apply(get_size)
    # # convert to proper date format
    # df['create_time'] = df['create_time'].apply(datetime.strftime, args=("%Y-%m-%d %H:%M:%S",))
    # # reorder and define used columns
    # df = df[columns.split(",")]
    return df

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Process Viewer & Monitor")
    parser.add_argument("-c", "--columns", help="""Columns to show,
                                                available are name,create_time,cores,cpu_usage,status,nice,memory_usage,read_bytes,write_bytes,n_threads,username.
                                                Default is name,cpu_usage,memory_usage,read_bytes,write_bytes,status,create_time,nice,n_threads,cores.""",
                        default="name,cpu_usage,memory_usage,read_bytes,write_bytes,status,create_time,nice,n_threads,cores")
    parser.add_argument("-s", "--sort-by", dest="sort_by", help="Column to sort by, default is memory_usage .", default="memory_usage")
    parser.add_argument("--descending", action="store_true", help="Whether to sort in descending order.")
    parser.add_argument("-n", help="Number of processes to show, will show all if 0 is specified, default is 25 .", default=25)
    parser.add_argument("-u", "--live-update", action="store_true", help="Whether to keep the program on and updating process information each second")

    # parse arguments
    args = parser.parse_args()
    columns = args.columns
    sort_by = args.sort_by
    descending = args.descending
    n = int(args.n)
    live_update = args.live_update
    # print the processes for the first time
    processes = get_processes_info()
    # pprint(processes)
    send_and_check(processes)
    # df = construct_dataframe(processes)
    # if n == 0:
    #     print(df.to_string())
    # elif n > 0:
    #     print(df.head(n).to_string())
    # print continuously
    while live_update:
        # get all process info
        processes = get_processes_info()
        pprint(processes)
        # df = construct_dataframe(processes)
        # # clear the screen depending on your OS
        # os.system("cls") if "nt" in os.name else os.system("clear")
        # if n == 0:
        #     print(df.to_string())
        # elif n > 0:
        #     print(df.head(n).to_string())
        # time.sleep(0.7)